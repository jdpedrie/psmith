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
// written" is unambiguous to the model. The no-restart language is
// load-bearing: a live compaction restarted the whole document on its
// continuation leg (the partial ended mid-deliberation and the model
// chose to start clean), duplicating every section in the persisted
// summary. The restart probe below catches models that do it anyway.
const compressionContinuePrompt = "Your summary was cut off when it hit the output limit. Continue from the EXACT point where the text above ends — mid-sentence if that is where it broke off. Your reply is appended verbatim to that text: do NOT restart the summary, do NOT rewrite or repeat earlier sections, do NOT add a preamble or closing remarks. Output only the continuation."

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
				// Continuation legs get a restart probe: if the model
				// re-begins the document instead of resuming (observed
				// live — the whole summary duplicated), the probe
				// discards the superseded accumulation and tells
				// downstream to do the same via ChunkContentReset.
				var probe *restartProbe
				if leg > 1 {
					probe = newRestartProbe(partial.String())
				}
				switch pipeLeg(ctx, src, out, &partial, &merged, &sawUsage, probe) {
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
//
// probe (nil for the first leg) buffers the leg's opening text until a
// restart verdict is possible. On a detected restart the superseded
// accumulation is discarded (partial reset + ChunkContentReset sent
// downstream) before the buffered text flows; on a clean resume the
// buffer flushes with no side effects. A leg that ends before the
// probe has enough text flushes undecided — too short to have
// duplicated anything that matters.
func pipeLeg(ctx context.Context, src <-chan providers.Chunk, out chan<- providers.Chunk, partial *strings.Builder, merged *providers.Usage, sawUsage *bool, probe *restartProbe) legStatus {
	flushProbe := func() bool {
		if probe == nil || probe.flushed {
			return true
		}
		return probe.flush(ctx, out, partial, false)
	}
	for {
		select {
		case <-ctx.Done():
			return legAborted
		case ch, ok := <-src:
			if !ok {
				if !flushProbe() {
					return legAborted
				}
				return legClosed
			}
			switch ch.Type {
			case providers.ChunkDone:
				if !flushProbe() {
					return legAborted
				}
				return legDone
			case providers.ChunkUsage:
				var u providers.Usage
				if err := json.Unmarshal(ch.Payload, &u); err == nil {
					accumulateUsage(merged, u)
					*sawUsage = true
				}
			case providers.ChunkError:
				if !flushProbe() {
					return legAborted
				}
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
						if probe != nil && !probe.flushed {
							probe.buf.WriteString(t.Text)
							if probe.ready() {
								if !probe.flush(ctx, out, partial, true) {
									return legAborted
								}
							}
							// Buffered (or just flushed as part of the
							// buffer) — don't forward the raw chunk.
							continue
						}
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

// restartProbe holds back the head of a continuation leg long enough
// to tell "resumed where it stopped" from "started the document over".
// Comparison is whitespace-insensitive: the head of the new leg is
// searched for within the head of the accumulated document.
type restartProbe struct {
	docHead string // normalized head of the accumulated document
	buf     strings.Builder
	flushed bool
	// Restarted is recorded for tests/logging; the side effects
	// (partial reset + downstream ChunkContentReset) happen in flush.
	restarted bool
}

// probeNeed is how many normalized characters of the new leg we buffer
// before deciding. Long enough that a match against the document head
// can't be a coincidental phrase; short enough that the held-back
// window is invisible at streaming cadence.
const probeNeed = 48

// probeDocHead is how much of the accumulated document's head the
// probe searches. A restart reproduces the document's opening; a
// legitimate continuation picks up deep in the tail, far past this
// window.
const probeDocHead = 600

func newRestartProbe(accumulated string) *restartProbe {
	head := normalizeForProbe(accumulated)
	if len(head) > probeDocHead {
		head = head[:probeDocHead]
	}
	return &restartProbe{docHead: head}
}

func (p *restartProbe) ready() bool {
	return len(normalizeForProbe(p.buf.String())) >= probeNeed
}

// flush decides (when enough text is buffered), applies restart side
// effects, and forwards the buffered text as one synthesized chunk.
// decided=false callers (leg ended early) skip detection.
func (p *restartProbe) flush(ctx context.Context, out chan<- providers.Chunk, partial *strings.Builder, decide bool) bool {
	p.flushed = true
	buffered := p.buf.String()
	if decide {
		head := normalizeForProbe(buffered)
		if len(head) > probeNeed {
			head = head[:probeNeed]
		}
		if len(head) >= probeNeed && p.docHead != "" && strings.Contains(p.docHead, head) {
			p.restarted = true
			partial.Reset()
			if !sendOne(ctx, out, providers.Chunk{Type: providers.ChunkContentReset, Payload: []byte(`{}`)}) {
				return false
			}
		}
	}
	if buffered == "" {
		return true
	}
	partial.WriteString(buffered)
	payload, err := json.Marshal(struct {
		Text string `json:"text"`
	}{Text: buffered})
	if err != nil {
		return true
	}
	return sendOne(ctx, out, providers.Chunk{Type: providers.ChunkText, Payload: payload})
}

// normalizeForProbe lowercases and strips all whitespace so chunk
// boundaries and formatting jitter can't defeat the comparison.
func normalizeForProbe(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range strings.ToLower(s) {
		switch r {
		case ' ', '\t', '\n', '\r':
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
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
