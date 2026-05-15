package anthropic

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"

	sdk "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/packages/param"

	"github.com/jdpedrie/reeve/internal/providers"
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
	// translate events into Reeve's chunk vocabulary.
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
				case sdk.SignatureDelta:
					// Anthropic emits one signature_delta per thinking block,
					// at the end of the block. Reeve forwards it so the
					// conversations-side tool loop can pair it with the
					// preceding thinking text and round-trip the signed pair
					// back on the next request.
					payload, _ := json.Marshal(map[string]string{"signature": d.Signature})
					if !sendChunk(ctx, out, providers.Chunk{
						Type: providers.ChunkThinkingSignature, Payload: payload,
					}) {
						return
					}
				default:
					// citations_delta and other future deltas don't have a
					// normalized chunk type yet — stay silent rather than
					// fabricating one.
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
				// stop_reason on the message_delta is Anthropic's
				// termination signal — end_turn / max_tokens /
				// stop_sequence / tool_use / refusal. Captured here
				// (last one wins) so the Usage chunk carries it on
				// MessageStopEvent.
				if sr := string(v.Delta.StopReason); sr != "" {
					srCopy := sr
					usage.FinishReason = &srCopy
				}
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

// buildMessageParams translates Reeve's WireMessage prefix + CallSettings
// into the SDK's MessageNewParams. The system message (if any) is hoisted
// out of the messages array — Anthropic carries it on a separate field.
//
// Auto prompt-caching: a single `cache_control: {type: "ephemeral"}` marker
// is placed at the end of the *stable* prefix — i.e., the most recent
// assistant turn before the new user message (or, if no assistant turn has
// happened yet, the system block). The cache boundary moves forward by one
// turn each time, so the cache stays warm across a chat. When the prefix is
// just the new user message (no prior history), no marker is added — there
// would be nothing to cache.
func buildMessageParams(req providers.SendRequest) (sdk.MessageNewParams, error) {
	out := sdk.MessageNewParams{
		Model: sdk.Model(req.ModelID),
	}

	systemBlocks, msgs, err := translateMessages(req.Messages)
	if err != nil {
		return sdk.MessageNewParams{}, err
	}

	// Place the auto cache_control marker before assigning to `out`.
	// The mutator works in place on the slices we just built. Honors the
	// per-conversation/profile/etc. AnthropicExtras toggle + TTL pick.
	applyAutoCacheControl(systemBlocks, msgs, req.Settings.Anthropic)

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
	if req.Settings.TopP != nil {
		out.TopP = param.NewOpt(*req.Settings.TopP)
	}
	if req.Settings.TopK != nil {
		out.TopK = param.NewOpt(int64(*req.Settings.TopK))
	}
	if len(req.Settings.StopSequences) > 0 {
		out.StopSequences = append([]string(nil), req.Settings.StopSequences...)
	}
	if t := req.Settings.Thinking; t != nil && t.Enabled != nil && *t.Enabled {
		budget := int64(0)
		if t.BudgetTokens != nil {
			budget = int64(*t.BudgetTokens)
		}
		out.Thinking = sdk.ThinkingConfigParamOfEnabled(budget)
	}
	if len(req.Tools) > 0 {
		tools, err := translateTools(req.Tools)
		if err != nil {
			return sdk.MessageNewParams{}, err
		}
		out.Tools = tools
	}
	return out, nil
}

// translateTools converts plugin-provided tool defs into the Anthropic
// SDK's `ToolUnionParam` shape.
func translateTools(in []providers.ToolDef) ([]sdk.ToolUnionParam, error) {
	out := make([]sdk.ToolUnionParam, 0, len(in))
	for _, t := range in {
		var schema sdk.ToolInputSchemaParam
		if len(t.InputSchema) > 0 {
			if err := json.Unmarshal(t.InputSchema, &schema); err != nil {
				return nil, fmt.Errorf("anthropic: tool %q input schema: %w", t.Name, err)
			}
		}
		tool := sdk.ToolParam{
			Name:        t.Name,
			Description: param.NewOpt(t.Description),
			InputSchema: schema,
		}
		out = append(out, sdk.ToolUnionParam{OfTool: &tool})
	}
	return out, nil
}

// applyAutoCacheControl marks the end of the stable prefix with an ephemeral
// cache_control breakpoint. The "stable prefix" is everything up to but not
// including the latest user turn (which is what the model is being asked to
// respond to right now and changes every call).
//
// Placement priority:
//  1. If the message list ends with `user` and there's a prior `assistant`
//     turn, mark the LAST text block of that assistant turn.
//  2. Otherwise, if there's any system block, mark the LAST one.
//  3. Otherwise (only the new user turn, no system), don't mark anything —
//     there's no stable prefix to cache.
//
// `extras` carries per-conversation overrides:
//   - `CacheEnabled = false` → skip placement entirely (return immediately).
//   - `CacheTTL = 1h` → emit `"ttl":"1h"` on the breakpoint via the SDK's
//     extra-fields escape hatch (the v1.4 SDK doesn't expose `ttl` on the
//     non-beta `CacheControlEphemeralParam` struct directly).
//   - default / `CacheTTL = 5m` / unspecified → SDK's default 5m TTL.
//
// The marker mutates the param structs in the slices we were handed; that's
// fine because translateMessages built them locally for this call.
func applyAutoCacheControl(systemBlocks []sdk.TextBlockParam, msgs []sdk.MessageParam, extras *providers.AnthropicExtras) {
	if extras != nil && extras.CacheEnabled != nil && !*extras.CacheEnabled {
		// Caching explicitly disabled — leave the request marker-free.
		return
	}

	cache := sdk.NewCacheControlEphemeralParam()
	if extras != nil && extras.CacheTTL == providers.CacheTTL1h {
		// SDK v1.4's non-beta CacheControlEphemeralParam doesn't expose a
		// TTL field. Fall through to its embedded paramObj's
		// SetExtraFields escape hatch — the encoder splices the entries
		// into the marshalled JSON, so the resulting wire payload reads
		// {"type":"ephemeral","ttl":"1h"} as the API requires.
		cache.SetExtraFields(map[string]any{"ttl": "1h"})
	}

	// Find the last assistant turn (scanning from the tail). If the very
	// last message is an assistant turn, that's the model's *prior*
	// response and counts as stable. If the last is a user turn, scan
	// backwards for the most recent assistant response.
	lastAsst := -1
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Role == sdk.MessageParamRoleAssistant {
			lastAsst = i
			break
		}
	}

	if lastAsst >= 0 {
		// Mark the last text content block of that assistant turn. We mark
		// text rather than thinking because thinking blocks have signature
		// constraints we don't want to entangle with caching.
		blocks := msgs[lastAsst].Content
		for i := len(blocks) - 1; i >= 0; i-- {
			if tb := blocks[i].OfText; tb != nil {
				tb.CacheControl = cache
				return
			}
		}
		// Assistant turn with no text block (only thinking?) — fall through
		// to system marking.
	}

	if len(systemBlocks) > 0 {
		systemBlocks[len(systemBlocks)-1].CacheControl = cache
		return
	}
	// No stable prefix — don't mark anything.
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
			blocks, err := userBlocks(m)
			if err != nil {
				return nil, nil, err
			}
			msgs = append(msgs, sdk.NewUserMessage(blocks...))
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

// userBlocks builds content for a user-role message. Tool results
// emit native `tool_result` blocks; image attachments emit `image`
// blocks (base64-inline in v1 — provider Files API caching is a
// phase-4 escape hatch); the message's text content (if any) follows.
//
// Attachment ordering: image blocks precede the text body so the
// model "sees" the image before the prompt that references it.
// Mirrors Anthropic's own multimodal examples and is the documented
// recommendation for image-grounded Q&A.
func userBlocks(m providers.WireMessage) ([]sdk.ContentBlockParamUnion, error) {
	var blocks []sdk.ContentBlockParamUnion
	for _, tr := range m.ToolResults {
		body := string(tr.Output)
		isError := false
		if tr.Error != "" {
			body = tr.Error
			isError = true
		}
		// Anthropic supports image content inside tool_result
		// blocks. Build the union manually so we can mix the
		// text body with one image block per inline image
		// attachment the tool produced. Non-image attachments
		// (PDF / audio / video) drop silently — Anthropic's
		// tool_result content union only accepts text + image.
		content := []sdk.ToolResultBlockParamContentUnion{
			{OfText: &sdk.TextBlockParam{Text: body}},
		}
		for _, att := range tr.Attachments {
			if att.Kind != providers.AttachmentImage || len(att.Data) == 0 {
				continue
			}
			img := sdk.ImageBlockParam{
				Source: sdk.ImageBlockParamSourceUnion{
					OfBase64: &sdk.Base64ImageSourceParam{
						MediaType: sdk.Base64ImageSourceMediaType(att.MimeType),
						Data:      base64.StdEncoding.EncodeToString(att.Data),
					},
				},
			}
			content = append(content, sdk.ToolResultBlockParamContentUnion{OfImage: &img})
		}
		blocks = append(blocks, sdk.ContentBlockParamUnion{
			OfToolResult: &sdk.ToolResultBlockParam{
				ToolUseID: tr.ToolUseID,
				Content:   content,
				IsError:   sdk.Bool(isError),
			},
		})
	}
	for _, att := range m.Attachments {
		if len(att.Data) == 0 {
			// Phase-1 driver path is inline-only. URL / ProviderFileID
			// modes are reserved for phase 4 (provider Files API
			// caching). An attachment that arrived without inline
			// bytes is a history-builder bug, not a user-facing
			// failure — drop it rather than crash the turn.
			continue
		}
		switch att.Kind {
		case providers.AttachmentImage:
			blocks = append(blocks, sdk.NewImageBlockBase64(
				att.MimeType,
				base64.StdEncoding.EncodeToString(att.Data),
			))
		case providers.AttachmentDocument:
			// Anthropic's `document` block accepts PDFs natively.
			// Other document MIME types (DOCX, plaintext, …) would
			// need a different source variant (PlainTextSourceParam,
			// for instance); reject anything that isn't application/pdf
			// for v1.
			if att.MimeType != "application/pdf" {
				continue
			}
			blocks = append(blocks, sdk.NewDocumentBlock(sdk.Base64PDFSourceParam{
				Data: base64.StdEncoding.EncodeToString(att.Data),
			}))
		default:
			// Audio + video aren't supported by Anthropic at all —
			// drop. Capability table on the client gates these out
			// before they reach the driver, so a drop here is
			// defense-in-depth rather than an expected path.
		}
	}
	if m.Content != "" {
		blocks = append(blocks, sdk.NewTextBlock(m.Content))
	}
	if len(blocks) == 0 {
		blocks = append(blocks, sdk.NewTextBlock(""))
	}
	return blocks, nil
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
	for _, tu := range m.ToolUses {
		input := tu.Input
		if len(input) == 0 {
			input = json.RawMessage(`{}`)
		}
		blocks = append(blocks, sdk.NewToolUseBlock(tu.ID, input, tu.Name))
	}
	return blocks, nil
}
