package openai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	openai "github.com/openai/openai-go"
	"github.com/openai/openai-go/packages/param"
	"github.com/openai/openai-go/responses"
	"github.com/openai/openai-go/shared"

	"github.com/jdpedrie/clark/internal/providers"
)

// Send dispatches a turn through the Responses API and translates the
// upstream SSE event stream into the normalized chunk vocabulary defined
// by providers.Chunk.
//
// Event mapping:
//
//	response.output_text.delta              → ChunkText
//	response.reasoning_summary_text.delta   → ChunkThinking
//	response.reasoning_summary.delta        → ChunkThinking (newer event name)
//	response.output_item.added (function_call)
//	  + response.function_call_arguments.delta
//	  + response.output_item.done (function_call) → ChunkToolUseStart/Delta/End
//	error / response.failed                 → ChunkError
//	response.completed                      → ChunkDone
//
// Tool-use translation is implemented but minimal: we emit start/delta/end
// chunks with the call_id, name, and accumulated argument-JSON delta.
// Clark's history-builder doesn't yet round-trip tool calls, so this path
// is best-effort — see the architecture doc's "Open threads".
//
// The returned channel is closed when the upstream stream terminates (any
// reason). Cancellation of ctx propagates to the SDK and closes the
// channel after a final ChunkError.
func (d *Driver) Send(ctx context.Context, req providers.SendRequest) (<-chan providers.Chunk, error) {
	if d.cfg.UseChatCompletions {
		params, err := buildChatCompletionParams(req)
		if err != nil {
			return nil, fmt.Errorf("openai-compatible: build chat params: %w", err)
		}
		stream := d.client.Chat.Completions.NewStreaming(ctx, params)
		out := make(chan providers.Chunk, 16)
		go d.pumpChatStream(ctx, stream, out)
		return out, nil
	}

	params, err := buildResponseParams(req)
	if err != nil {
		return nil, fmt.Errorf("openai-compatible: build params: %w", err)
	}

	stream := d.client.Responses.NewStreaming(ctx, params)

	out := make(chan providers.Chunk, 16)
	go d.pumpStream(ctx, stream, out)
	return out, nil
}

// chatStreamLike is the subset of the SDK's chat-completions stream we use.
type chatStreamLike interface {
	Next() bool
	Current() openai.ChatCompletionChunk
	Err() error
	Close() error
}

// pumpChatStream translates ChatCompletionChunk events into the normalized
// chunk vocabulary. Chat Completions has a much smaller surface than the
// Responses API: just `delta.content` text, an optional `tool_calls` field
// (deferred), and a `finish_reason` on the last chunk.
//
// When IncludeUsage is set on stream options (we always set it), the SDK
// emits one extra terminal chunk after `finish_reason` carrying the final
// usage tally. We hold the Done emit until either we see usage or the
// stream ends so we can emit ChunkUsage before ChunkDone.
func (d *Driver) pumpChatStream(ctx context.Context, stream chatStreamLike, out chan<- providers.Chunk) {
	defer close(out)
	defer stream.Close()

	finishSeen := false
	for stream.Next() {
		chunk := stream.Current()

		select {
		case <-ctx.Done():
			emit(out, providers.ChunkError, map[string]string{"message": ctx.Err().Error()})
			return
		default:
		}

		// Usage chunk arrives after the finish-reason chunk when
		// stream_options.include_usage is true; choices is empty on it.
		if chunk.Usage.TotalTokens > 0 || chunk.Usage.PromptTokens > 0 || chunk.Usage.CompletionTokens > 0 {
			emitChatUsage(out, chunk.Usage)
		}

		for _, ch := range chunk.Choices {
			if ch.Delta.Content != "" {
				emit(out, providers.ChunkText, map[string]string{"text": ch.Delta.Content})
			}
			if ch.FinishReason != "" {
				finishSeen = true
				// Don't emit Done yet — wait for the usage chunk that follows.
			}
		}
	}
	if err := stream.Err(); err != nil {
		emit(out, providers.ChunkError, map[string]string{"message": err.Error()})
		return
	}
	if !finishSeen {
		// Stream ended without finish_reason — synthesize Done.
		emit(out, providers.ChunkDone, map[string]any{})
		return
	}
	emit(out, providers.ChunkDone, map[string]any{})
}

// emitChatUsage normalizes a CompletionUsage into ChunkUsage.
func emitChatUsage(out chan<- providers.Chunk, u openai.CompletionUsage) {
	prompt, completion := int(u.PromptTokens), int(u.CompletionTokens)
	usage := providers.Usage{
		InputTokens:  &prompt,
		OutputTokens: &completion,
	}
	if u.PromptTokensDetails.CachedTokens > 0 {
		v := int(u.PromptTokensDetails.CachedTokens)
		usage.CacheReadTokens = &v
	}
	if u.CompletionTokensDetails.ReasoningTokens > 0 {
		v := int(u.CompletionTokensDetails.ReasoningTokens)
		usage.ReasoningTokens = &v
	}
	if raw, err := json.Marshal(u); err == nil {
		usage.ProviderRaw = raw
	}
	payload, err := json.Marshal(usage)
	if err != nil {
		return
	}
	out <- providers.Chunk{Type: providers.ChunkUsage, Payload: payload}
}

// buildChatCompletionParams translates Clark's wire shape into the SDK's
// ChatCompletionNewParams. Tool use, refusals, and audio are not yet wired.
func buildChatCompletionParams(req providers.SendRequest) (openai.ChatCompletionNewParams, error) {
	if req.ModelID == "" {
		return openai.ChatCompletionNewParams{}, errors.New("model_id is required")
	}
	params := openai.ChatCompletionNewParams{
		Model: shared.ChatModel(req.ModelID),
	}
	for _, m := range req.Messages {
		switch m.Role {
		case "system":
			params.Messages = append(params.Messages, openai.ChatCompletionMessageParamUnion{
				OfSystem: &openai.ChatCompletionSystemMessageParam{
					Content: openai.ChatCompletionSystemMessageParamContentUnion{
						OfString: param.NewOpt(m.Content),
					},
				},
			})
		case "user":
			params.Messages = append(params.Messages, openai.ChatCompletionMessageParamUnion{
				OfUser: &openai.ChatCompletionUserMessageParam{
					Content: openai.ChatCompletionUserMessageParamContentUnion{
						OfString: param.NewOpt(m.Content),
					},
				},
			})
		case "assistant":
			params.Messages = append(params.Messages, openai.ChatCompletionMessageParamUnion{
				OfAssistant: &openai.ChatCompletionAssistantMessageParam{
					Content: openai.ChatCompletionAssistantMessageParamContentUnion{
						OfString: param.NewOpt(m.Content),
					},
				},
			})
		default:
			return openai.ChatCompletionNewParams{}, fmt.Errorf("unsupported wire role %q", m.Role)
		}
	}
	if req.Settings.Temperature != nil {
		params.Temperature = param.NewOpt(*req.Settings.Temperature)
	}
	if req.Settings.MaxOutputTokens != nil {
		params.MaxCompletionTokens = param.NewOpt(int64(*req.Settings.MaxOutputTokens))
	}
	// Always opt into the trailing usage chunk so the supervisor can record
	// per-message token counts and cost.
	params.StreamOptions = openai.ChatCompletionStreamOptionsParam{
		IncludeUsage: param.NewOpt(true),
	}
	return params, nil
}

// streamLike is the subset of *ssestream.Stream[T] we actually use; lets
// pumpStream stay testable without spinning up a real HTTP server.
type streamLike interface {
	Next() bool
	Current() responses.ResponseStreamEventUnion
	Err() error
	Close() error
}

func (d *Driver) pumpStream(ctx context.Context, stream streamLike, out chan<- providers.Chunk) {
	defer close(out)
	defer stream.Close()

	// Track the active function call (one at a time is the common case;
	// extending to a map keyed by output_index would be straightforward
	// when parallel tool calls become a concern).
	type activeCall struct {
		itemID string
		callID string
		name   string
	}
	var active *activeCall

	for stream.Next() {
		evt := stream.Current()

		select {
		case <-ctx.Done():
			emit(out, providers.ChunkError, map[string]string{"message": ctx.Err().Error()})
			return
		default:
		}

		switch evt.Type {
		case "response.output_text.delta":
			emit(out, providers.ChunkText, map[string]string{"text": evt.Delta.OfString})

		case "response.reasoning_summary_text.delta",
			"response.reasoning_summary.delta":
			// Two event names cover the same conceptual slot across SDK
			// versions / model variants. Both carry the delta in the
			// shared union's Delta field (or Text on older variants).
			text := evt.Delta.OfString
			if text == "" {
				text = evt.Text
			}
			emit(out, providers.ChunkThinking, map[string]string{"text": text})

		case "response.output_item.added":
			// We only care about function calls for the tool-use path.
			if evt.Item.Type == "function_call" {
				active = &activeCall{
					itemID: evt.Item.ID,
					callID: evt.Item.CallID,
					name:   evt.Item.Name,
				}
				emit(out, providers.ChunkToolUseStart, map[string]string{
					"id":   evt.Item.CallID,
					"name": evt.Item.Name,
				})
			}

		case "response.function_call_arguments.delta":
			if active != nil && active.itemID == evt.ItemID {
				emit(out, providers.ChunkToolUseDelta, map[string]string{
					"id":             active.callID,
					"arguments_json": evt.Delta.OfString,
				})
			}

		case "response.output_item.done":
			if evt.Item.Type == "function_call" && active != nil && active.itemID == evt.Item.ID {
				emit(out, providers.ChunkToolUseEnd, map[string]string{
					"id":             active.callID,
					"name":           active.name,
					"arguments_json": evt.Item.Arguments,
				})
				active = nil
			}

		case "error":
			emit(out, providers.ChunkError, map[string]string{
				"message": evt.Message,
				"code":    evt.Code,
			})

		case "response.failed":
			msg := "response failed"
			if evt.Response.Error.Message != "" {
				msg = evt.Response.Error.Message
			}
			emit(out, providers.ChunkError, map[string]string{"message": msg})

		case "response.completed":
			emitResponsesUsage(out, evt.Response.Usage)
			emit(out, providers.ChunkDone, map[string]any{})
			return

		default:
			// Quietly ignore everything else (created, in_progress,
			// output_item.added for messages, content_part.added, etc.)
			// — they're informational and the chunk vocabulary doesn't
			// have slots for them.
		}
	}

	if err := stream.Err(); err != nil {
		emit(out, providers.ChunkError, map[string]string{"message": err.Error()})
		return
	}
	// Stream ended without a `response.completed` event — emit a synthetic
	// done so subscribers see a clean terminator. (Should be rare in
	// practice; the API always sends completed on success.)
	emit(out, providers.ChunkDone, map[string]any{})
}

// emitResponsesUsage normalizes a Responses API ResponseUsage into ChunkUsage
// and pushes it to out. No-op if the input is all-zero (e.g., upstream didn't
// report usage).
func emitResponsesUsage(out chan<- providers.Chunk, u responses.ResponseUsage) {
	if u.InputTokens == 0 && u.OutputTokens == 0 && u.TotalTokens == 0 {
		return
	}
	in, outTok := int(u.InputTokens), int(u.OutputTokens)
	usage := providers.Usage{
		InputTokens:  &in,
		OutputTokens: &outTok,
	}
	if u.InputTokensDetails.CachedTokens > 0 {
		v := int(u.InputTokensDetails.CachedTokens)
		usage.CacheReadTokens = &v
	}
	if u.OutputTokensDetails.ReasoningTokens > 0 {
		v := int(u.OutputTokensDetails.ReasoningTokens)
		usage.ReasoningTokens = &v
	}
	if raw, err := json.Marshal(u); err == nil {
		usage.ProviderRaw = raw
	}
	payload, err := json.Marshal(usage)
	if err != nil {
		return
	}
	out <- providers.Chunk{Type: providers.ChunkUsage, Payload: payload}
}

// emit marshals the payload and pushes a chunk. JSON-marshal failures are
// silently swallowed — the payload shapes here are static maps of strings
// and never trigger marshal errors in practice.
func emit(out chan<- providers.Chunk, typ providers.ChunkType, payload any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		raw = []byte(`{}`)
	}
	out <- providers.Chunk{Type: typ, Payload: raw}
}

// buildResponseParams translates the Clark wire shape into the openai-go
// ResponseNewParams.
func buildResponseParams(req providers.SendRequest) (responses.ResponseNewParams, error) {
	if req.ModelID == "" {
		return responses.ResponseNewParams{}, errors.New("model_id is required")
	}

	params := responses.ResponseNewParams{
		Model: shared.ResponsesModel(req.ModelID),
	}

	// Walk the wire messages. `system` collapses into the Instructions
	// field if there's exactly one and it's first (the typical Clark
	// shape — see history-builder). Any further system messages are
	// passed inline as developer-role inputs to keep their semantics.
	var inputs responses.ResponseInputParam
	systemConsumed := false
	for i, m := range req.Messages {
		switch m.Role {
		case "system":
			if i == 0 && !systemConsumed {
				params.Instructions = param.NewOpt(m.Content)
				systemConsumed = true
				continue
			}
			inputs = append(inputs,
				responses.ResponseInputItemParamOfMessage(
					m.Content,
					responses.EasyInputMessageRoleSystem,
				),
			)
		case "user":
			inputs = append(inputs,
				responses.ResponseInputItemParamOfMessage(
					m.Content,
					responses.EasyInputMessageRoleUser,
				),
			)
		case "assistant":
			// If the producing-side stored a Responses-shape thinking
			// blob and the history-builder is sending it back to us
			// (same-provider-type send), pass it back as a reasoning
			// item so the model sees its prior chain-of-thought.
			if reasoningParam, ok := decodeReasoningItem(m.Thinking); ok {
				inputs = append(inputs,
					responses.ResponseInputItemUnionParam{OfReasoning: reasoningParam},
				)
			}
			inputs = append(inputs,
				responses.ResponseInputItemParamOfMessage(
					m.Content,
					responses.EasyInputMessageRoleAssistant,
				),
			)
		default:
			return responses.ResponseNewParams{},
				fmt.Errorf("unsupported wire role %q", m.Role)
		}
	}
	params.Input = responses.ResponseNewParamsInputUnion{
		OfInputItemList: inputs,
	}

	// CallSettings.
	if req.Settings.Temperature != nil {
		params.Temperature = param.NewOpt(*req.Settings.Temperature)
	}
	if req.Settings.MaxOutputTokens != nil {
		params.MaxOutputTokens = param.NewOpt(int64(*req.Settings.MaxOutputTokens))
	}
	if req.Settings.ThinkingEnabled != nil && *req.Settings.ThinkingEnabled {
		// Best-effort: enable medium reasoning effort. Reasoning models
		// (o1, o3, gpt-5) honour this; non-reasoning models will return
		// 400 — that's surfaced via the error chunk.
		params.Reasoning = shared.ReasoningParam{
			Effort: shared.ReasoningEffortMedium,
		}
	}

	return params, nil
}

// decodeReasoningItem attempts to interpret a stored thinking blob as the
// Responses-API reasoning item we produced when the originating turn ran.
// Returns ok=false when the blob is missing or the wrong shape (e.g.
// thinking from a different provider type that the history-builder failed
// to filter).
func decodeReasoningItem(raw json.RawMessage) (*responses.ResponseReasoningItemParam, bool) {
	if len(raw) == 0 {
		return nil, false
	}
	// Stored shape (see RenderThinkingToText): a ResponseReasoningItem.
	// We reuse the SDK's own Param type for round-tripping.
	var item responses.ResponseReasoningItemParam
	if err := json.Unmarshal(raw, &item); err != nil {
		return nil, false
	}
	if item.ID == "" || len(item.Summary) == 0 {
		return nil, false
	}
	return &item, true
}
