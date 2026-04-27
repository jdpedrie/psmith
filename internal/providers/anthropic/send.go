package anthropic

import (
	"context"
	"encoding/json"
	"fmt"

	sdk "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/packages/param"

	"github.com/jdpedrie/clark/internal/providers"
)

// Send opens a streaming Anthropic Messages call and returns a channel
// of normalized Chunks. The caller drains the channel; the channel is
// closed when the upstream stream completes (cleanly or with error).
//
// Tool-use lifecycle is emitted (start/delta/end) but tool_result handling
// on the input side is deferred — see RenderThinkingToText comments.
func (d *Driver) Send(ctx context.Context, req providers.SendRequest) (<-chan providers.Chunk, error) {
	params, err := buildMessageParams(req)
	if err != nil {
		return nil, err
	}

	// NewStreaming returns a *Stream that lazily decodes; errors surface via
	// stream.Err() during iteration. We hand the iteration to a goroutine and
	// translate events into Clark's chunk vocabulary.
	stream := d.client.Messages.NewStreaming(ctx, params)

	out := make(chan providers.Chunk, 16)
	go func() {
		defer close(out)
		// toolBlocks indexes content blocks that opened as tool_use so the
		// later input_json_delta / content_block_stop events can be translated
		// correctly. Index is the SDK's per-block sequence number.
		toolBlocks := map[int64]bool{}

		// Accumulate usage across MessageStart + MessageDelta. Both carry the
		// same four token counters; deltas are cumulative so the last delta
		// wins. We emit a single ChunkUsage right before ChunkDone.
		var usage providers.Usage
		var usageRaw json.RawMessage
		captureUsage := func(input, output, cacheRead, cacheCreate int64, raw any) {
			i, o, r, c := int(input), int(output), int(cacheRead), int(cacheCreate)
			usage.InputTokens = &i
			usage.OutputTokens = &o
			usage.CacheReadTokens = &r
			usage.CacheWriteTokens = &c
			if b, err := json.Marshal(raw); err == nil {
				usageRaw = b
			}
		}

		for stream.Next() {
			ev := stream.Current()
			switch v := ev.AsAny().(type) {
			case sdk.MessageStartEvent:
				u := v.Message.Usage
				captureUsage(u.InputTokens, u.OutputTokens, u.CacheReadInputTokens, u.CacheCreationInputTokens, u)
			case sdk.ContentBlockStartEvent:
				if cb := v.ContentBlock; cb.Type == "tool_use" {
					toolBlocks[v.Index] = true
					payload, _ := json.Marshal(map[string]string{
						"id":   cb.ID,
						"name": cb.Name,
					})
					if !sendChunk(ctx, out, providers.Chunk{
						Type: providers.ChunkToolUseStart, Payload: payload,
					}) {
						return
					}
				}
				// text/thinking block opens emit no chunk; their deltas follow.
			case sdk.ContentBlockDeltaEvent:
				switch d := v.Delta.AsAny().(type) {
				case sdk.TextDelta:
					payload, _ := json.Marshal(map[string]string{"text": d.Text})
					if !sendChunk(ctx, out, providers.Chunk{
						Type: providers.ChunkText, Payload: payload,
					}) {
						return
					}
				case sdk.ThinkingDelta:
					payload, _ := json.Marshal(map[string]string{"text": d.Thinking})
					if !sendChunk(ctx, out, providers.Chunk{
						Type: providers.ChunkThinking, Payload: payload,
					}) {
						return
					}
				case sdk.InputJSONDelta:
					payload, _ := json.Marshal(map[string]string{
						"partial_json": d.PartialJSON,
					})
					if !sendChunk(ctx, out, providers.Chunk{
						Type: providers.ChunkToolUseDelta, Payload: payload,
					}) {
						return
					}
				default:
					// signature_delta / citations_delta don't have a normalized
					// chunk type yet — stay silent rather than fabricating one.
				}
			case sdk.ContentBlockStopEvent:
				if toolBlocks[v.Index] {
					delete(toolBlocks, v.Index)
					if !sendChunk(ctx, out, providers.Chunk{
						Type: providers.ChunkToolUseEnd, Payload: []byte(`{}`),
					}) {
						return
					}
				}
			case sdk.MessageDeltaEvent:
				u := v.Usage
				captureUsage(u.InputTokens, u.OutputTokens, u.CacheReadInputTokens, u.CacheCreationInputTokens, u)
			case sdk.MessageStopEvent:
				if usage.InputTokens != nil || usage.OutputTokens != nil {
					usage.ProviderRaw = usageRaw
					payload, _ := json.Marshal(usage)
					_ = sendChunk(ctx, out, providers.Chunk{
						Type: providers.ChunkUsage, Payload: payload,
					})
				}
				_ = sendChunk(ctx, out, providers.Chunk{
					Type: providers.ChunkDone, Payload: []byte(`{}`),
				})
				return
			}
		}

		if err := stream.Err(); err != nil {
			payload, _ := json.Marshal(map[string]string{"message": err.Error()})
			_ = sendChunk(ctx, out, providers.Chunk{
				Type: providers.ChunkError, Payload: payload,
			})
		}
	}()

	return out, nil
}

// sendChunk pushes one chunk to out, honouring ctx cancellation. Returns
// false if the consumer is gone, signalling the producer to bail out.
func sendChunk(ctx context.Context, out chan<- providers.Chunk, c providers.Chunk) bool {
	select {
	case out <- c:
		return true
	case <-ctx.Done():
		return false
	}
}

// buildMessageParams translates Clark's WireMessage prefix + CallSettings
// into the SDK's MessageNewParams. The system message (if any) is hoisted
// out of the messages array — Anthropic carries it on a separate field.
func buildMessageParams(req providers.SendRequest) (sdk.MessageNewParams, error) {
	out := sdk.MessageNewParams{
		Model: sdk.Model(req.ModelID),
	}

	systemBlocks, msgs, err := translateMessages(req.Messages)
	if err != nil {
		return sdk.MessageNewParams{}, err
	}
	out.Messages = msgs
	if len(systemBlocks) > 0 {
		out.System = systemBlocks
	}

	if req.Settings.MaxOutputTokens != nil {
		out.MaxTokens = int64(*req.Settings.MaxOutputTokens)
	} else {
		out.MaxTokens = defaultMaxOutputTokens
	}
	if req.Settings.Temperature != nil {
		out.Temperature = param.NewOpt(*req.Settings.Temperature)
	}
	if req.Settings.ThinkingEnabled != nil && *req.Settings.ThinkingEnabled {
		budget := int64(0)
		if req.Settings.ThinkingBudgetTokens != nil {
			budget = int64(*req.Settings.ThinkingBudgetTokens)
		}
		out.Thinking = sdk.ThinkingConfigParamOfEnabled(budget)
	}
	return out, nil
}

// translateMessages splits the prefix into the system-prompt blocks and the
// alternating user/assistant message list that Anthropic wants. Assistant
// thinking, if attached, is reattached as native content blocks.
func translateMessages(in []providers.WireMessage) ([]sdk.TextBlockParam, []sdk.MessageParam, error) {
	var sys []sdk.TextBlockParam
	var msgs []sdk.MessageParam

	for _, m := range in {
		switch m.Role {
		case "system":
			sys = append(sys, sdk.TextBlockParam{Text: m.Content})
		case "user":
			msgs = append(msgs, sdk.NewUserMessage(sdk.NewTextBlock(m.Content)))
		case "assistant":
			blocks, err := assistantBlocks(m)
			if err != nil {
				return nil, nil, err
			}
			msgs = append(msgs, sdk.NewAssistantMessage(blocks...))
		default:
			return nil, nil, fmt.Errorf("anthropic: unsupported role %q", m.Role)
		}
	}
	return sys, msgs, nil
}

// thinkingPersisted is the on-disk shape of an assistant turn's thinking
// blocks (mirrors the Anthropic block payload — see Message thinking field
// in architecture.md). We accept the same shape we emit on RenderThinkingToText.
type thinkingPersisted struct {
	Type      string `json:"type"`
	Thinking  string `json:"thinking,omitempty"`
	Signature string `json:"signature,omitempty"`
	Data      string `json:"data,omitempty"` // for redacted_thinking
}

func assistantBlocks(m providers.WireMessage) ([]sdk.ContentBlockParamUnion, error) {
	var blocks []sdk.ContentBlockParamUnion

	// Thinking blocks come first — Anthropic requires signed thinking blocks
	// to precede the assistant text they were produced alongside.
	if len(m.Thinking) > 0 {
		var parsed []thinkingPersisted
		if err := json.Unmarshal(m.Thinking, &parsed); err != nil {
			return nil, fmt.Errorf("anthropic: parse stored thinking: %w", err)
		}
		for _, t := range parsed {
			switch t.Type {
			case "thinking":
				blocks = append(blocks, sdk.NewThinkingBlock(t.Signature, t.Thinking))
			case "redacted_thinking":
				blocks = append(blocks, sdk.NewRedactedThinkingBlock(t.Data))
			}
		}
	}
	if m.Content != "" {
		blocks = append(blocks, sdk.NewTextBlock(m.Content))
	}
	return blocks, nil
}
