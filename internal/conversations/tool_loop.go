package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/plugins"
)

// maxToolRounds caps how many tool-use → tool-result → continued-stream
// iterations the wrapper performs inside a single SendMessage.
const maxToolRounds = 8

// makeToolLoopSendFunc wraps a base SendRequest into a SendFunc that
// transparently runs tool-use rounds before returning the final stream
// to the supervisor. From the supervisor's point of view it sees a
// single linear chunk stream — text, thinking, tool_use_*, tool_result,
// text, … — and materialises one assistant message at the end.
//
// Per round:
//  1. Drain the upstream stream into a single output channel.
//  2. Track every tool_use the model emitted: id, name, accumulated
//     input JSON, ProviderOpaque (Gemini thoughtSignature).
//  3. Capture signed thinking blocks (Anthropic) — text + signature
//     pairs collected during the round.
//  4. When the round ends with tool_use blocks pending, dispatch each
//     to its owning plugin's ExecuteTool, emit a synthetic
//     ChunkToolResult per result for live UI + persistence.
//  5. Build a follow-up SendRequest that appends two synthetic
//     WireMessages — assistant carrying text+tool_use (+ signed
//     thinking), user carrying the tool_results — and re-issue the
//     stream. The model continues from there.
//  6. Loop until a round ends with no pending tool_use, or the round
//     cap is reached. The loop swallows the upstream's intermediate
//     ChunkDone events so the supervisor only sees one ChunkDone at
//     the very end.
func makeToolLoopSendFunc(
	drv providers.StatelessProvider,
	initial providers.SendRequest,
	pipeline plugins.Pipeline,
	logger *slog.Logger,
) func(ctx context.Context) (<-chan providers.Chunk, error) {
	dispatch := buildToolDispatch(pipeline)

	return func(ctx context.Context) (<-chan providers.Chunk, error) {
		out := make(chan providers.Chunk, 32)

		go func() {
			defer close(out)

			req := initial
			for round := 0; round < maxToolRounds; round++ {
				upstream, err := drv.Send(ctx, req)
				if err != nil {
					emitError(ctx, out, fmt.Errorf("tool round %d: %w", round, err))
					return
				}

				captured, fatal := drainRound(ctx, upstream, out)
				if fatal != nil {
					return
				}
				if len(captured.calls) == 0 {
					_ = forward(ctx, out, providers.Chunk{
						Type: providers.ChunkDone, Payload: []byte(`{}`),
					})
					return
				}

				results := make([]providers.ToolResultBlock, 0, len(captured.calls))
				for _, c := range captured.calls {
					if err := ctx.Err(); err != nil {
						return
					}
					started := time.Now()
					var output json.RawMessage
					var execErr error
					if dispatch == nil {
						execErr = errors.New("no ToolProvider in pipeline")
					} else {
						output, execErr = dispatch(ctx, c.Name, c.Input)
					}
					elapsed := time.Since(started)

					if errors.Is(execErr, context.Canceled) || errors.Is(execErr, context.DeadlineExceeded) {
						return
					}

					rb := providers.ToolResultBlock{ToolUseID: c.ID}
					if execErr != nil {
						rb.Error = execErr.Error()
						if logger != nil {
							logger.Warn("tool execute failed",
								"tool", c.Name,
								"id", c.ID,
								"err", execErr)
						}
					} else {
						rb.Output = output
					}
					results = append(results, rb)

					payload, _ := json.Marshal(map[string]any{
						"tool_use_id": c.ID,
						"output":      json.RawMessage(rb.Output),
						"error":       rb.Error,
						"elapsed_ms":  elapsed.Milliseconds(),
					})
					if !forward(ctx, out, providers.Chunk{
						Type: providers.ChunkToolResult, Payload: payload,
					}) {
						return
					}
				}

				// Build the follow-up assistant + user messages.
				asstWire := providers.WireMessage{
					Role:     "assistant",
					ToolUses: captured.calls,
				}
				if len(captured.thinking) > 0 {
					if blob, mErr := json.Marshal(captured.thinking); mErr == nil {
						asstWire.Thinking = blob
					}
				}
				userWire := providers.WireMessage{
					Role:        "user",
					ToolResults: results,
				}
				req.Messages = append(append([]providers.WireMessage(nil), req.Messages...), asstWire, userWire)
			}

			emitError(ctx, out, fmt.Errorf("tool loop exceeded %d rounds", maxToolRounds))
		}()

		return out, nil
	}
}

// collectPipelineTools walks the active plugin pipeline and gathers
// every plugin-declared tool into the providers.ToolDef shape used on
// SendRequest.
func collectPipelineTools(pipeline plugins.Pipeline) []providers.ToolDef {
	if len(pipeline) == 0 {
		return nil
	}
	var out []providers.ToolDef
	for _, pl := range pipeline {
		tp, ok := pl.(plugins.ToolProvider)
		if !ok {
			continue
		}
		for _, t := range tp.Tools() {
			out = append(out, providers.ToolDef{
				Name:        t.Name,
				Description: t.Description,
				InputSchema: append([]byte(nil), t.InputSchema...),
			})
		}
	}
	return out
}

// buildToolDispatch constructs a (toolName → owning plugin) lookup.
func buildToolDispatch(pipeline plugins.Pipeline) func(ctx context.Context, name string, input json.RawMessage) (json.RawMessage, error) {
	owners := map[string]plugins.ToolProvider{}
	for _, pl := range pipeline {
		tp, ok := pl.(plugins.ToolProvider)
		if !ok {
			continue
		}
		for _, t := range tp.Tools() {
			if _, dup := owners[t.Name]; dup {
				continue
			}
			owners[t.Name] = tp
		}
	}
	if len(owners) == 0 {
		return nil
	}
	return func(ctx context.Context, name string, input json.RawMessage) (json.RawMessage, error) {
		owner, ok := owners[name]
		if !ok {
			return nil, fmt.Errorf("no plugin owns tool %q", name)
		}
		return owner.ExecuteTool(ctx, name, input)
	}
}

// pendingToolUse is one in-flight tool call captured during a round.
type pendingToolUse struct {
	ID             string
	Name           string
	ProviderOpaque string
	input          strings.Builder
}

// roundCapture is the state drainRound accumulates for one round.
type roundCapture struct {
	calls    []providers.ToolUseBlock
	thinking []anthropicThinkingBlock
}

// anthropicThinkingBlock mirrors the JSONB shape Reeve stores on
// messages.thinking for signed-thinking turns.
type anthropicThinkingBlock struct {
	Type      string `json:"type"`
	Thinking  string `json:"thinking,omitempty"`
	Signature string `json:"signature,omitempty"`
}

// drainRound forwards every chunk from upstream to out (except
// intermediate ChunkDone), tracking tool_use blocks and signed
// thinking as it goes.
func drainRound(
	ctx context.Context,
	upstream <-chan providers.Chunk,
	out chan<- providers.Chunk,
) (roundCapture, error) {
	var pending []*pendingToolUse
	currentByIndex := -1

	var thinkingText strings.Builder
	var thinkingBlocks []anthropicThinkingBlock

	for ch := range upstream {
		switch ch.Type {
		case providers.ChunkToolUseStart:
			var info struct {
				ID             string `json:"id"`
				Name           string `json:"name"`
				ProviderOpaque string `json:"provider_opaque"`
			}
			_ = json.Unmarshal(ch.Payload, &info)
			pending = append(pending, &pendingToolUse{
				ID:             info.ID,
				Name:           info.Name,
				ProviderOpaque: info.ProviderOpaque,
			})
			currentByIndex = len(pending) - 1
		case providers.ChunkToolUseDelta:
			var d struct {
				PartialJSON string `json:"partial_json"`
			}
			_ = json.Unmarshal(ch.Payload, &d)
			if currentByIndex >= 0 && currentByIndex < len(pending) {
				pending[currentByIndex].input.WriteString(d.PartialJSON)
			}
		case providers.ChunkToolUseEnd:
			currentByIndex = -1
		case providers.ChunkThinking:
			var d struct {
				Text string `json:"text"`
			}
			_ = json.Unmarshal(ch.Payload, &d)
			thinkingText.WriteString(d.Text)
		case providers.ChunkThinkingSignature:
			var d struct {
				Signature string `json:"signature"`
			}
			_ = json.Unmarshal(ch.Payload, &d)
			thinkingBlocks = append(thinkingBlocks, anthropicThinkingBlock{
				Type:      "thinking",
				Thinking:  thinkingText.String(),
				Signature: d.Signature,
			})
			thinkingText.Reset()
		case providers.ChunkDone:
			continue
		case providers.ChunkError:
			_ = forward(ctx, out, ch)
			return roundCapture{}, errors.New("upstream error")
		}
		if ch.Type != providers.ChunkDone {
			if !forward(ctx, out, ch) {
				return roundCapture{}, errors.New("output channel closed")
			}
		}
	}

	calls := make([]providers.ToolUseBlock, 0, len(pending))
	for _, p := range pending {
		raw := p.input.String()
		if raw == "" {
			raw = "{}"
		}
		calls = append(calls, providers.ToolUseBlock{
			ID:             p.ID,
			Name:           p.Name,
			Input:          json.RawMessage(raw),
			ProviderOpaque: p.ProviderOpaque,
		})
	}
	return roundCapture{calls: calls, thinking: thinkingBlocks}, nil
}

func forward(ctx context.Context, out chan<- providers.Chunk, ch providers.Chunk) bool {
	select {
	case out <- ch:
		return true
	case <-ctx.Done():
		return false
	}
}

func emitError(ctx context.Context, out chan<- providers.Chunk, err error) {
	payload, _ := json.Marshal(map[string]string{"message": err.Error()})
	_ = forward(ctx, out, providers.Chunk{Type: providers.ChunkError, Payload: payload})
}
