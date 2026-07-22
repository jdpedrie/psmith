package openai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"

	openai "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
	"github.com/openai/openai-go/packages/param"
	"github.com/openai/openai-go/responses"
	"github.com/openai/openai-go/shared"

	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/providers"
)

// locksSampling reports whether the target model rejects explicit
// sampling parameters (temperature and top_p). OpenAI's reasoning
// models — the o-series and the gpt-5 family — lock temperature at its
// default and return 400 "unsupported parameter: temperature" (and the
// same for top_p) on any explicit value. modelmeta encodes that as a
// LockedAt temperature constraint, so we reuse it as the single source
// of truth rather than re-listing model prefixes here.
func locksSampling(modelID string) bool {
	c := modelmeta.ConstraintsFor("openai-compatible", modelID)
	return c.Temperature != nil && c.Temperature.LockedAt != nil
}

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
// Psmith's history-builder doesn't yet round-trip tool calls, so this path
// is best-effort — see the architecture doc's "Open threads".
//
// The returned channel is closed when the upstream stream terminates (any
// reason). Cancellation of ctx propagates to the SDK and closes the
// channel after a final ChunkError.
func (d *Driver) Send(ctx context.Context, req providers.SendRequest) (<-chan providers.Chunk, error) {
	reqOpts := d.perRequestOptions(req)

	if d.chatCompletions {
		params, err := buildChatCompletionParams(req)
		if err != nil {
			return nil, fmt.Errorf("openai-compatible: build chat params: %w", err)
		}
		stream := d.client.Chat.Completions.NewStreaming(ctx, params, reqOpts...)
		out := make(chan providers.Chunk, 16)
		go d.pumpChatStream(ctx, stream, out)
		return out, nil
	}

	params, err := buildResponseParams(req)
	if err != nil {
		return nil, fmt.Errorf("openai-compatible: build params: %w", err)
	}

	stream := d.client.Responses.NewStreaming(ctx, params, reqOpts...)

	out := make(chan providers.Chunk, 16)
	go d.pumpStream(ctx, stream, out)
	return out, nil
}

// perRequestOptions assembles per-call SDK options driven by the active
// quirks overlay: HeaderInjector contributes WithHeader entries,
// RequestBodyFields contributes WithJSONSet entries (the "extra_body"
// pattern several providers need for non-standard fields).
func (d *Driver) perRequestOptions(req providers.SendRequest) []option.RequestOption {
	var opts []option.RequestOption

	if d.quirks.HeaderInjector != nil {
		h := http.Header{}
		d.quirks.HeaderInjector(h, req)
		for k, vs := range h {
			for _, v := range vs {
				opts = append(opts, option.WithHeader(k, v))
			}
		}
	}

	if d.quirks.RequestBodyFields != nil {
		fields := d.quirks.RequestBodyFields(req)
		// Iterate sorted keys so the resulting opts list is deterministic
		// — helps when comparing request bodies in tests.
		keys := make([]string, 0, len(fields))
		for k := range fields {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			opts = append(opts, option.WithJSONSet(k, fields[k]))
		}
	}

	return opts
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

	// Tool call accumulator keyed by the per-choice index OpenAI assigns.
	// The first delta for an index carries the call id + function name;
	// subsequent deltas append argument JSON fragments. We emit a Start
	// the moment we have an id, a Delta per arguments fragment, and an
	// End when finish_reason fires (or at stream close).
	type pendingCall struct {
		id      string
		started bool
	}
	pending := map[int64]*pendingCall{}
	emitEnds := func() {
		for _, p := range pending {
			if p.started {
				emit(out, providers.ChunkToolUseEnd, map[string]any{})
			}
		}
		pending = map[int64]*pendingCall{}
	}

	finishSeen := false
	var finishReason string
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
			emitChatUsage(out, chunk.Usage, finishReason)
		}

		for _, ch := range chunk.Choices {
			// Reasoning content arrives via non-standard delta fields the
			// official OpenAI API doesn't ship: `delta.reasoning` (used by
			// OpenRouter, Z.AI, and most "thinking" gateways) and
			// `delta.reasoning_content` (DeepSeek's variant). The SDK
			// captures unknown JSON keys in `Delta.JSON.ExtraFields` so we
			// can read both regardless of the upstream's exact field name.
			// We try the modern OpenRouter spelling first and fall back to
			// DeepSeek's; if both are populated we concat (rare in practice).
			if text := extractReasoningDelta(ch.Delta); text != "" {
				emit(out, providers.ChunkThinking, map[string]string{"text": text})
			}
			if ch.Delta.Content != "" {
				emit(out, providers.ChunkText, map[string]string{"text": ch.Delta.Content})
			}
			for _, tc := range ch.Delta.ToolCalls {
				p, ok := pending[tc.Index]
				if !ok {
					p = &pendingCall{}
					pending[tc.Index] = p
				}
				if !p.started && (tc.ID != "" || tc.Function.Name != "") {
					if tc.ID != "" {
						p.id = tc.ID
					}
					emit(out, providers.ChunkToolUseStart, map[string]string{
						"id":   p.id,
						"name": tc.Function.Name,
					})
					p.started = true
				}
				if tc.Function.Arguments != "" {
					emit(out, providers.ChunkToolUseDelta, map[string]string{
						"partial_json": tc.Function.Arguments,
					})
				}
			}
			if ch.FinishReason != "" {
				finishSeen = true
				finishReason = string(ch.FinishReason)
				emitEnds()
				// Don't emit Done yet — wait for the usage chunk that follows.
			}
		}
	}
	emitEnds()
	if err := stream.Err(); err != nil {
		emit(out, providers.ChunkError, map[string]string{"message": err.Error()})
		return
	}
	_ = finishSeen
	emit(out, providers.ChunkDone, map[string]any{})
}

// extractReasoningDelta pulls a non-standard reasoning string off a
// chat-completions stream delta. Official OpenAI doesn't ship this field;
// every gateway that proxies a thinking model invents its own spelling:
//
//   - OpenRouter, Z.AI, Together-via-OR: `delta.reasoning`
//   - DeepSeek (and a handful of forks): `delta.reasoning_content`
//
// Both fields are strings carrying the running thought stream. The SDK
// captures unknown JSON keys in `Delta.JSON.ExtraFields`; we unwrap the
// `respjson.Field.Raw()` (which gives a JSON-encoded value) into a Go
// string. Returns "" when neither field is present.
func extractReasoningDelta(d openai.ChatCompletionChunkChoiceDelta) string {
	var out string
	for _, key := range []string{"reasoning", "reasoning_content"} {
		f, ok := d.JSON.ExtraFields[key]
		if !ok || !f.Valid() {
			continue
		}
		raw := f.Raw()
		if raw == "" || raw == "null" {
			continue
		}
		var s string
		if err := json.Unmarshal([]byte(raw), &s); err == nil && s != "" {
			out += s
		}
	}
	return out
}

// emitChatUsage normalizes a CompletionUsage into ChunkUsage. finishReason
// (if non-empty) is the verbatim finish_reason captured from the
// last-seen choice chunk before the usage frame — the UI uses it to
// surface unexpected terminations like "length" or "content_filter".
func emitChatUsage(out chan<- providers.Chunk, u openai.CompletionUsage, finishReason string) {
	// OpenAI reports `prompt_tokens` as the GROSS prompt count (includes
	// the cached portion) and `prompt_tokens_details.cached_tokens` as
	// the cached subset. The supervisor's cost calc charges
	// `InputTokens × input_price + CacheReadTokens × cache_read_price`
	// — so if we forwarded the gross prompt count as `InputTokens`, the
	// cached portion would be billed at BOTH the full input rate AND
	// the cache-read rate. Subtract here so `InputTokens` is the
	// "fresh" (non-cached) portion and the math works out.
	cached := int(u.PromptTokensDetails.CachedTokens)
	prompt := int(u.PromptTokens) - cached
	if prompt < 0 {
		prompt = 0
	} // defensive — upstream invariant says cached <= prompt
	completion := int(u.CompletionTokens)
	usage := providers.Usage{
		InputTokens:  &prompt,
		OutputTokens: &completion,
	}
	if cached > 0 {
		usage.CacheReadTokens = &cached
	}
	if u.CompletionTokensDetails.ReasoningTokens > 0 {
		v := int(u.CompletionTokensDetails.ReasoningTokens)
		usage.ReasoningTokens = &v
	}
	if raw, err := json.Marshal(u); err == nil {
		usage.ProviderRaw = raw
	}
	if finishReason != "" {
		fr := finishReason
		usage.FinishReason = &fr
	}
	payload, err := json.Marshal(usage)
	if err != nil {
		return
	}
	out <- providers.Chunk{Type: providers.ChunkUsage, Payload: payload}
}

// buildChatCompletionParams translates Psmith's wire shape into the SDK's
// ChatCompletionNewParams. Refusals and audio are not yet wired.
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
			// A user wire message with tool_results is the synthetic
			// turn the conversations-side tool loop emits after running
			// every tool. Translate each result into its own
			// `role=tool` message — Chat Completions models them
			// individually, NOT as a wrapped user turn.
			if len(m.ToolResults) > 0 {
				for _, tr := range m.ToolResults {
					content := chatToolResultContent(tr)
					params.Messages = append(params.Messages, openai.ChatCompletionMessageParamUnion{
						OfTool: &openai.ChatCompletionToolMessageParam{
							ToolCallID: tr.ToolUseID,
							Content: openai.ChatCompletionToolMessageParamContentUnion{
								OfString: param.NewOpt(content),
							},
						},
					})
				}
				continue
			}
			// Image attachments → multi-part content. The `image_url`
			// part accepts either a URL or a base64 data URL; we use
			// the latter since v1 inlines bytes (the provider Files
			// API caching is phase 4). Other attachment kinds drop
			// silently — the capability table on the client gates
			// them out before they reach the driver.
			if hasInlineImageAttachment(m.Attachments) {
				parts := make([]openai.ChatCompletionContentPartUnionParam, 0, len(m.Attachments)+1)
				for _, att := range m.Attachments {
					if att.Kind != providers.AttachmentImage || len(att.Data) == 0 {
						continue
					}
					parts = append(parts, openai.ImageContentPart(
						openai.ChatCompletionContentPartImageImageURLParam{
							URL: dataURL(att.MimeType, att.Data),
						},
					))
				}
				if m.Content != "" {
					parts = append(parts, openai.TextContentPart(m.Content))
				}
				params.Messages = append(params.Messages, openai.ChatCompletionMessageParamUnion{
					OfUser: &openai.ChatCompletionUserMessageParam{
						Content: openai.ChatCompletionUserMessageParamContentUnion{
							OfArrayOfContentParts: parts,
						},
					},
				})
				continue
			}
			params.Messages = append(params.Messages, openai.ChatCompletionMessageParamUnion{
				OfUser: &openai.ChatCompletionUserMessageParam{
					Content: openai.ChatCompletionUserMessageParamContentUnion{
						OfString: param.NewOpt(m.Content),
					},
				},
			})
		case "assistant":
			asst := &openai.ChatCompletionAssistantMessageParam{
				Content: openai.ChatCompletionAssistantMessageParamContentUnion{
					OfString: param.NewOpt(m.Content),
				},
			}
			if len(m.ToolUses) > 0 {
				asst.ToolCalls = make([]openai.ChatCompletionMessageToolCallParam, 0, len(m.ToolUses))
				for _, tu := range m.ToolUses {
					args := string(tu.Input)
					if args == "" {
						args = "{}"
					}
					asst.ToolCalls = append(asst.ToolCalls, openai.ChatCompletionMessageToolCallParam{
						ID: tu.ID,
						Function: openai.ChatCompletionMessageToolCallFunctionParam{
							Name:      tu.Name,
							Arguments: args,
						},
					})
				}
			}
			params.Messages = append(params.Messages, openai.ChatCompletionMessageParamUnion{
				OfAssistant: asst,
			})
		default:
			return openai.ChatCompletionNewParams{}, fmt.Errorf("unsupported wire role %q", m.Role)
		}
	}

	// Translate the tool catalog from the conversations-side pipeline.
	if len(req.Tools) > 0 {
		params.Tools = make([]openai.ChatCompletionToolParam, 0, len(req.Tools))
		for _, t := range req.Tools {
			fn := shared.FunctionDefinitionParam{Name: t.Name}
			if t.Description != "" {
				fn.Description = param.NewOpt(t.Description)
			}
			if len(t.InputSchema) > 0 {
				var schema map[string]any
				if err := json.Unmarshal(t.InputSchema, &schema); err == nil {
					fn.Parameters = shared.FunctionParameters(schema)
				}
			}
			params.Tools = append(params.Tools, openai.ChatCompletionToolParam{Function: fn})
		}
	}
	// Reasoning models (o-series, gpt-5 family) reject explicit
	// temperature / top_p — omit them rather than 400. The user's
	// stored override still resolves; it just can't be sent here.
	if !locksSampling(req.ModelID) {
		if req.Settings.Temperature != nil {
			params.Temperature = param.NewOpt(*req.Settings.Temperature)
		}
		if req.Settings.TopP != nil {
			params.TopP = param.NewOpt(*req.Settings.TopP)
		}
	}
	if req.Settings.MaxOutputTokens != nil {
		params.MaxCompletionTokens = param.NewOpt(int64(*req.Settings.MaxOutputTokens))
	}
	if len(req.Settings.StopSequences) > 0 {
		params.Stop = openai.ChatCompletionNewParamsStopUnion{
			OfStringArray: append([]string(nil), req.Settings.StopSequences...),
		}
	}
	// OpenAI Chat Completions doesn't expose a top_k knob — drop. Same for
	// the universal `thinking` field; reasoning effort is a Responses-API
	// concept and Chat Completions has no equivalent on this surface.

	// Always set the prompt cache key to the conversation_id so successive
	// turns route to the same cache shard. Empty conv id (compression turns,
	// etc.) is fine — OpenAI ignores empty values.
	if req.ConversationID != "" {
		params.PromptCacheKey = param.NewOpt(req.ConversationID)
	}

	if oe := req.Settings.OpenAI; oe != nil {
		if oe.Seed != nil {
			params.Seed = param.NewOpt(int64(*oe.Seed))
		}
		if oe.FrequencyPenalty != nil {
			params.FrequencyPenalty = param.NewOpt(*oe.FrequencyPenalty)
		}
		if oe.PresencePenalty != nil {
			params.PresencePenalty = param.NewOpt(*oe.PresencePenalty)
		}
		if oe.TopLogprobs != nil {
			// TopLogprobs requires Logprobs=true to be honoured.
			params.Logprobs = param.NewOpt(true)
			params.TopLogprobs = param.NewOpt(int64(*oe.TopLogprobs))
		}
		if oe.ParallelToolCalls != nil {
			params.ParallelToolCalls = param.NewOpt(*oe.ParallelToolCalls)
		}
		if oe.ServiceTier != nil {
			params.ServiceTier = chatServiceTier(*oe.ServiceTier)
		}
		if oe.ResponseFormat != nil {
			if rf, ok := chatResponseFormat(oe.ResponseFormat); ok {
				params.ResponseFormat = rf
			}
		}
		if len(oe.LogitBias) > 0 {
			lb := make(map[string]int64, len(oe.LogitBias))
			for tok, bias := range oe.LogitBias {
				lb[fmt.Sprintf("%d", tok)] = int64(bias)
			}
			params.LogitBias = lb
		}
	}

	// Always opt into the trailing usage chunk so the supervisor can record
	// per-message token counts and cost.
	params.StreamOptions = openai.ChatCompletionStreamOptionsParam{
		IncludeUsage: param.NewOpt(true),
	}
	return params, nil
}

// chatToolResultContent renders a ToolResultBlock as the string the
// `tool` message expects. OpenAI's content slot is a string; objects
// must be JSON-stringified. On error we send the human-readable error
// text — the model can react.
func chatToolResultContent(tr providers.ToolResultBlock) string {
	if tr.Error != "" {
		return tr.Error
	}
	if len(tr.Output) == 0 {
		return ""
	}
	return string(tr.Output)
}

// chatServiceTier maps the Psmith enum to the SDK's ChatCompletionNewParamsServiceTier.
// Returns the zero value for Unspecified — leaves the field empty on the wire.
func chatServiceTier(in providers.ServiceTier) openai.ChatCompletionNewParamsServiceTier {
	switch in {
	case providers.ServiceTierAuto:
		return openai.ChatCompletionNewParamsServiceTierAuto
	case providers.ServiceTierStandard:
		// "Standard" maps to OpenAI's "default" tier — the term they use
		// for the standard pricing/perf bucket.
		return openai.ChatCompletionNewParamsServiceTierDefault
	case providers.ServiceTierPriority:
		return openai.ChatCompletionNewParamsServiceTierPriority
	}
	return ""
}

// chatResponseFormat translates the driver-side ResponseFormat into the
// Chat Completions union. Returns ok=false when the input is the "text"
// variant — that's the API's default and we just leave the field empty.
func chatResponseFormat(rf *providers.ResponseFormat) (openai.ChatCompletionNewParamsResponseFormatUnion, bool) {
	if rf == nil {
		return openai.ChatCompletionNewParamsResponseFormatUnion{}, false
	}
	if rf.Text != nil {
		// Text is the default; setting it explicitly is harmless but noisy.
		return openai.ChatCompletionNewParamsResponseFormatUnion{}, false
	}
	if rf.JSONObject != nil {
		obj := shared.NewResponseFormatJSONObjectParam()
		return openai.ChatCompletionNewParamsResponseFormatUnion{OfJSONObject: &obj}, true
	}
	if rf.JSONSchema != nil {
		schema := shared.ResponseFormatJSONSchemaParam{
			JSONSchema: shared.ResponseFormatJSONSchemaJSONSchemaParam{
				Name: rf.JSONSchema.Name,
			},
		}
		if rf.JSONSchema.Description != nil {
			schema.JSONSchema.Description = param.NewOpt(*rf.JSONSchema.Description)
		}
		if rf.JSONSchema.Strict != nil {
			schema.JSONSchema.Strict = param.NewOpt(*rf.JSONSchema.Strict)
		}
		if len(rf.JSONSchema.Schema) > 0 {
			// `Schema` is `any` on the SDK side — unmarshal once so the
			// bytes don't get JSON-string-quoted on the way out.
			var decoded any
			if err := json.Unmarshal(rf.JSONSchema.Schema, &decoded); err == nil {
				schema.JSONSchema.Schema = decoded
			} else {
				// Fall back to raw bytes; Unmarshal failure is rare and the
				// API will reject the malformed JSON itself.
				schema.JSONSchema.Schema = json.RawMessage(rf.JSONSchema.Schema)
			}
		}
		return openai.ChatCompletionNewParamsResponseFormatUnion{OfJSONSchema: &schema}, true
	}
	return openai.ChatCompletionNewParamsResponseFormatUnion{}, false
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

	// Track in-flight function calls keyed by item id. Models emit one
	// at a time today, but the Responses API allows parallel
	// function_call items interleaving their argument deltas — a
	// single slot would cross-wire them.
	type activeCall struct {
		callID string
		name   string
	}
	active := make(map[string]*activeCall)

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
				active[evt.Item.ID] = &activeCall{
					callID: evt.Item.CallID,
					name:   evt.Item.Name,
				}
				emit(out, providers.ChunkToolUseStart, map[string]string{
					"id":   evt.Item.CallID,
					"name": evt.Item.Name,
				})
			}

		case "response.function_call_arguments.delta":
			if call, ok := active[evt.ItemID]; ok {
				emit(out, providers.ChunkToolUseDelta, map[string]string{
					"id":             call.callID,
					"arguments_json": evt.Delta.OfString,
				})
			}

		case "response.output_item.done":
			if evt.Item.Type == "function_call" {
				if call, ok := active[evt.Item.ID]; ok {
					emit(out, providers.ChunkToolUseEnd, map[string]string{
						"id":             call.callID,
						"name":           call.name,
						"arguments_json": evt.Item.Arguments,
					})
					delete(active, evt.Item.ID)
				}
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

		case "response.completed", "response.incomplete":
			// A generation that hits max_output_tokens terminates with
			// response.incomplete, NOT response.completed — without this
			// case the stream fell through to the synthetic done below
			// with no usage chunk and no finish reason, so a capped
			// output was indistinguishable from a clean stop.
			// IncompleteDetails.Reason (e.g. "max_output_tokens",
			// "content_filter") becomes FinishReason; a clean completion
			// has an empty reason and leaves FinishReason nil.
			emitResponsesUsage(out, evt.Response.Usage, evt.Response.IncompleteDetails.Reason)
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
// report usage). incompleteReason — when non-empty — surfaces an unexpected
// termination cause from the response.completed event's IncompleteDetails
// (e.g. "max_output_tokens", "content_filter"). A clean completion leaves
// it empty so the UI knows the run ended normally.
func emitResponsesUsage(out chan<- providers.Chunk, u responses.ResponseUsage, incompleteReason string) {
	if u.InputTokens == 0 && u.OutputTokens == 0 && u.TotalTokens == 0 {
		return
	}
	// Same gross-vs-cached separation as emitChatUsage — Responses API
	// reports `input_tokens` as the total (including cached) and
	// `input_tokens_details.cached_tokens` as the subset. Subtract so
	// the cost calc doesn't double-charge the cached portion.
	cached := int(u.InputTokensDetails.CachedTokens)
	in := int(u.InputTokens) - cached
	if in < 0 {
		in = 0
	}
	outTok := int(u.OutputTokens)
	usage := providers.Usage{
		InputTokens:  &in,
		OutputTokens: &outTok,
	}
	if cached > 0 {
		usage.CacheReadTokens = &cached
	}
	if u.OutputTokensDetails.ReasoningTokens > 0 {
		v := int(u.OutputTokensDetails.ReasoningTokens)
		usage.ReasoningTokens = &v
	}
	if raw, err := json.Marshal(u); err == nil {
		usage.ProviderRaw = raw
	}
	if incompleteReason != "" {
		fr := incompleteReason
		usage.FinishReason = &fr
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

// buildResponseParams translates the Psmith wire shape into the openai-go
// ResponseNewParams.
func buildResponseParams(req providers.SendRequest) (responses.ResponseNewParams, error) {
	if req.ModelID == "" {
		return responses.ResponseNewParams{}, errors.New("model_id is required")
	}

	params := responses.ResponseNewParams{
		Model: shared.ResponsesModel(req.ModelID),
	}

	// Walk the wire messages. `system` collapses into the Instructions
	// field if there's exactly one and it's first (the typical Psmith
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
			// Tool results arrive as a synthetic user wire message
			// (history builder splits the assistant's tool_calls into
			// assistant.ToolUses + a following user.ToolResults). Emit
			// them as function_call_output items so the Responses-API
			// model sees the tool outputs — previously dropped, which
			// is why reasoning models lost all tool history. The
			// callID matches the function_call's (tu.ID == tr.ToolUseID).
			if len(m.ToolResults) > 0 {
				for _, tr := range m.ToolResults {
					inputs = append(inputs,
						responses.ResponseInputItemParamOfFunctionCallOutput(
							tr.ToolUseID, chatToolResultContent(tr),
						),
					)
				}
				// The synthetic tool-result message carries no prose;
				// nothing else to emit for it.
				if m.Content == "" {
					continue
				}
			}
			// Image attachments → multi-part Content array. The
			// `input_image` part carries either a URL or a base64
			// data URL — we use the latter (v1 inlines bytes;
			// provider Files API caching is phase 4). Other
			// attachment kinds drop silently — capability table
			// gates them out before they reach the driver.
			if hasInlineImageAttachment(m.Attachments) {
				content := make(responses.ResponseInputMessageContentListParam, 0, len(m.Attachments)+1)
				for _, att := range m.Attachments {
					if att.Kind != providers.AttachmentImage || len(att.Data) == 0 {
						continue
					}
					content = append(content, responses.ResponseInputContentUnionParam{
						OfInputImage: &responses.ResponseInputImageParam{
							Detail:   "auto",
							ImageURL: param.NewOpt(dataURL(att.MimeType, att.Data)),
						},
					})
				}
				if m.Content != "" {
					content = append(content,
						responses.ResponseInputContentParamOfInputText(m.Content),
					)
				}
				inputs = append(inputs,
					responses.ResponseInputItemParamOfInputMessage(content, "user"),
				)
				continue
			}
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
			// Only emit a text item when there's actual prose — an
			// assistant turn that ONLY called tools has empty content,
			// and an empty Responses message item is wasteful/odd.
			if m.Content != "" {
				inputs = append(inputs,
					responses.ResponseInputItemParamOfMessage(
						m.Content,
						responses.EasyInputMessageRoleAssistant,
					),
				)
			}
			// Tool calls the assistant made. Without these, a model on
			// the Responses API (every reasoning model) never sees the
			// tool-calling history — the chat-completions path handled
			// it but this one silently dropped it, so e.g. a gpt-5 turn
			// that followed Anthropic tool use saw none of it.
			for _, tu := range m.ToolUses {
				args := string(tu.Input)
				if args == "" {
					args = "{}"
				}
				inputs = append(inputs,
					responses.ResponseInputItemParamOfFunctionCall(args, tu.ID, tu.Name),
				)
			}
		default:
			return responses.ResponseNewParams{},
				fmt.Errorf("unsupported wire role %q", m.Role)
		}
	}
	params.Input = responses.ResponseNewParamsInputUnion{
		OfInputItemList: inputs,
	}

	// CallSettings. Reasoning models reject explicit temperature /
	// top_p (see locksSampling) — omit them on those models.
	if !locksSampling(req.ModelID) {
		if req.Settings.Temperature != nil {
			params.Temperature = param.NewOpt(*req.Settings.Temperature)
		}
		if req.Settings.TopP != nil {
			params.TopP = param.NewOpt(*req.Settings.TopP)
		}
	}
	if req.Settings.MaxOutputTokens != nil {
		params.MaxOutputTokens = param.NewOpt(int64(*req.Settings.MaxOutputTokens))
	}
	// Thinking: derive Reasoning.Effort from budget_tokens.
	//   <2k → low; 2k-8k → medium; >8k → high. Falls back to medium when
	//   thinking is enabled but no budget is specified.
	//
	// An EXPLICIT disable can't switch reasoning off on the o-series /
	// gpt-5 family — the API has no off position — but omitting the
	// param means the model's default (medium) effort, whose hidden
	// tokens spend from the same MaxOutputTokens budget as the visible
	// text. Low effort is the closest honest translation of "don't
	// think" (the compression path depends on it). Gated on
	// locksSampling because non-reasoning models reject the reasoning
	// param outright.
	if t := req.Settings.Thinking; t != nil && t.Enabled != nil {
		switch {
		case *t.Enabled:
			params.Reasoning = shared.ReasoningParam{
				Effort: derivedReasoningEffort(t.BudgetTokens),
			}
		case locksSampling(req.ModelID):
			params.Reasoning = shared.ReasoningParam{
				Effort: shared.ReasoningEffortLow,
			}
		}
	}
	// Always set the prompt cache key to the conversation_id so successive
	// turns route to the same cache shard.
	if req.ConversationID != "" {
		params.PromptCacheKey = param.NewOpt(req.ConversationID)
	}

	if oe := req.Settings.OpenAI; oe != nil {
		if oe.ServiceTier != nil {
			params.ServiceTier = responsesServiceTier(*oe.ServiceTier)
		}
		// Responses API on openai-go v1.12 surfaces ServiceTier but not
		// Seed, frequency_penalty, presence_penalty, top_logprobs,
		// parallel_tool_calls, logit_bias, or the chat-style
		// response_format union — drop those fields silently. (Seed
		// ships on Chat Completions only at this SDK version; the
		// per-driver translation table allows for a future SDK rev.)
	}

	return params, nil
}

// derivedReasoningEffort maps a budget-tokens hint to the OpenAI reasoning
// effort enum. The thresholds mirror the plan's budget→effort mapping
// (<2k → low, 2-8k → medium, >8k → high). When the budget is unset we
// default to medium — matches the prior "thinking enabled, effort medium"
// behavior.
func derivedReasoningEffort(budget *int) shared.ReasoningEffort {
	if budget == nil {
		return shared.ReasoningEffortMedium
	}
	switch {
	case *budget < 2000:
		return shared.ReasoningEffortLow
	case *budget <= 8000:
		return shared.ReasoningEffortMedium
	default:
		return shared.ReasoningEffortHigh
	}
}

// responsesServiceTier maps the Psmith enum to the Responses API tier enum.
func responsesServiceTier(in providers.ServiceTier) responses.ResponseNewParamsServiceTier {
	switch in {
	case providers.ServiceTierAuto:
		return responses.ResponseNewParamsServiceTierAuto
	case providers.ServiceTierStandard:
		return responses.ResponseNewParamsServiceTierDefault
	case providers.ServiceTierPriority:
		return responses.ResponseNewParamsServiceTierPriority
	}
	return ""
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
