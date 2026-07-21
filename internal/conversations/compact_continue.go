package conversations

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"

	"github.com/jdpedrie/psmith/internal/providers"
)

// maxCompressionLegs bounds the total upstream requests one compaction
// may issue: the first attempt plus continuations. At the 32k output
// budget that allows ~128k tokens of summary, far beyond any sane
// compression; the cap exists so a model that reports a length stop on
// every leg can't loop spend forever. When the cap is hit the summary
// stays truncated and its persisted finish_reason says so.
const maxCompressionLegs = 4

// compressionContinuePrompt asks for a seamless resume. The partial
// summary rides along as the preceding assistant turn, so "already
// written" is unambiguous to the model.
const compressionContinuePrompt = "Your summary was cut off when it hit the output limit. Continue the summary from the exact point where it stopped, mid-sentence if that is where it broke off. Do not repeat anything already written, and do not add a preamble or closing remarks."

// lengthCapped reports whether a finish reason means "stopped at the
// output-token cap" in any driver's vocabulary: Anthropic max_tokens,
// OpenAI chat length / Responses max_output_tokens, Google MAX_TOKENS.
func lengthCapped(reason string) bool {
	switch strings.ToLower(reason) {
	case "max_tokens", "length", "max_output_tokens":
		return true
	}
	return false
}

// continuationSendFunc wraps a stateless Send in a transparent
// continue-on-length loop. The supervisor sees ONE stream: when a leg
// ends with a length-capped finish reason, the wrapper re-sends the
// base request with the accumulated partial appended as an assistant
// turn plus a continue instruction, and keeps piping the new leg's
// chunks into the same channel. Usage is summed across legs (each leg
// bills its own input pass) and emitted cumulatively at leg
// boundaries — which also resets the consume loop's idle timer before
// the next leg's first-token wait — with the final merged usage
// carrying the last leg's finish reason.
//
// Continuation is best-effort: a failed continuation open keeps the
// partial summary and terminates cleanly (no worse than no wrapper),
// and an error chunk mid-leg is forwarded as-is so the run errors the
// normal way.
func continuationSendFunc(p providers.StatelessProvider, base providers.SendRequest, logger *slog.Logger) func(ctx context.Context) (<-chan providers.Chunk, error) {
	return func(ctx context.Context) (<-chan providers.Chunk, error) {
		src, err := p.Send(ctx, base)
		if err != nil {
			return nil, err
		}
		out := make(chan providers.Chunk, 16)
		go func() {
			defer close(out)
			var partial strings.Builder
			var merged providers.Usage
			sawUsage := false
			for leg := 1; ; leg++ {
				switch pipeLeg(ctx, src, out, &partial, &merged, &sawUsage) {
				case legErrored, legAborted:
					go drainChunks(src)
					return
				case legClosed:
					// Upstream closed without a done event; mirror the
					// shape downstream (usage if any, no fabricated done).
					emitMergedUsage(ctx, out, merged, sawUsage)
					return
				}
				finish := ""
				if merged.FinishReason != nil {
					finish = *merged.FinishReason
				}
				if !lengthCapped(finish) || partial.Len() == 0 || leg >= maxCompressionLegs {
					if lengthCapped(finish) && leg >= maxCompressionLegs && logger != nil {
						logger.Warn("compression continuation cap reached; summary remains truncated",
							"legs", leg, "finish_reason", finish)
					}
					emitMergedUsage(ctx, out, merged, sawUsage)
					sendOne(ctx, out, providers.Chunk{Type: providers.ChunkDone, Payload: []byte(`{}`)})
					return
				}
				emitMergedUsage(ctx, out, merged, sawUsage)
				if logger != nil {
					logger.Info("compression hit the output cap; continuing",
						"next_leg", leg+1, "chars_so_far", partial.Len())
				}
				next := base
				next.Messages = append(append([]providers.WireMessage(nil), base.Messages...),
					providers.WireMessage{Role: "assistant", Content: partial.String()},
					providers.WireMessage{Role: "user", Content: compressionContinuePrompt},
				)
				nsrc, err := p.Send(ctx, next)
				if err != nil {
					if logger != nil {
						logger.Warn("compression continuation send failed; keeping partial summary", "err", err)
					}
					sendOne(ctx, out, providers.Chunk{Type: providers.ChunkDone, Payload: []byte(`{}`)})
					return
				}
				src = nsrc
			}
		}()
		return out, nil
	}
}

type legStatus int

const (
	legDone legStatus = iota
	legClosed
	legErrored
	legAborted
)

// pipeLeg forwards one upstream leg into out. Text chunks are forwarded
// AND accumulated into partial (the next leg's assistant turn). Usage
// chunks are captured into merged instead of forwarded — the wrapper
// owns usage emission so cross-leg totals stay correct. Done chunks are
// captured (the wrapper emits exactly one, at the end). Error chunks
// are forwarded and end the whole stream.
func pipeLeg(ctx context.Context, src <-chan providers.Chunk, out chan<- providers.Chunk, partial *strings.Builder, merged *providers.Usage, sawUsage *bool) legStatus {
	for {
		select {
		case <-ctx.Done():
			return legAborted
		case ch, ok := <-src:
			if !ok {
				return legClosed
			}
			switch ch.Type {
			case providers.ChunkDone:
				return legDone
			case providers.ChunkUsage:
				var u providers.Usage
				if err := json.Unmarshal(ch.Payload, &u); err == nil {
					accumulateUsage(merged, u)
					*sawUsage = true
				}
			case providers.ChunkError:
				if !sendOne(ctx, out, ch) {
					return legAborted
				}
				return legErrored
			default:
				if ch.Type == providers.ChunkText {
					var t struct {
						Text string `json:"text"`
					}
					if err := json.Unmarshal(ch.Payload, &t); err == nil {
						partial.WriteString(t.Text)
					}
				}
				if !sendOne(ctx, out, ch) {
					return legAborted
				}
			}
		}
	}
}

// accumulateUsage sums token counters (a continuation leg re-bills its
// own input pass, so totals are the honest cost of the whole
// compaction); FinishReason and ProviderRaw take the latest leg's
// value.
func accumulateUsage(dst *providers.Usage, u providers.Usage) {
	add := func(d **int, s *int) {
		if s == nil {
			return
		}
		if *d == nil {
			v := *s
			*d = &v
			return
		}
		**d += *s
	}
	add(&dst.InputTokens, u.InputTokens)
	add(&dst.OutputTokens, u.OutputTokens)
	add(&dst.CacheReadTokens, u.CacheReadTokens)
	add(&dst.CacheWriteTokens, u.CacheWriteTokens)
	add(&dst.ReasoningTokens, u.ReasoningTokens)
	if u.FinishReason != nil {
		dst.FinishReason = u.FinishReason
	}
	if len(u.ProviderRaw) > 0 {
		dst.ProviderRaw = u.ProviderRaw
	}
}

func emitMergedUsage(ctx context.Context, out chan<- providers.Chunk, merged providers.Usage, sawUsage bool) {
	if !sawUsage {
		return
	}
	payload, err := json.Marshal(merged)
	if err != nil {
		return
	}
	sendOne(ctx, out, providers.Chunk{Type: providers.ChunkUsage, Payload: payload})
}

func sendOne(ctx context.Context, out chan<- providers.Chunk, ch providers.Chunk) bool {
	select {
	case out <- ch:
		return true
	case <-ctx.Done():
		return false
	}
}

// drainChunks unblocks an abandoned upstream leg so the driver
// goroutine can finish and close its channel.
func drainChunks(src <-chan providers.Chunk) {
	for range src {
	}
}
