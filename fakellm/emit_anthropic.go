package fakellm

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// emitAnthropic writes a Script as an Anthropic Messages API SSE stream:
//
//	event: message_start
//	data: {"type":"message_start","message":{"id":"msg_...","usage":{...}}}
//
//	event: content_block_start
//	data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
//
//	event: content_block_delta
//	data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
//
//	event: content_block_stop
//	data: {"type":"content_block_stop","index":0}
//
//	event: message_delta
//	data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}
//
//	event: message_stop
//	data: {"type":"message_stop"}
//
// Each event opens a new content block and closes it; consecutive same-typed
// events still get their own block (the SDK handles either shape, and this
// keeps the emitter simple).
func emitAnthropic(ctx context.Context, w io.Writer, flusher http.Flusher, script Script) {
	// message_start with input usage (so the driver's MessageStartEvent path
	// captures input_tokens). Output counts come on message_delta.
	startUsage := map[string]any{
		"input_tokens":               0,
		"output_tokens":              1,
		"cache_read_input_tokens":    0,
		"cache_creation_input_tokens": 0,
	}
	if script.Usage != nil {
		startUsage["input_tokens"] = script.Usage.InputTokens
		startUsage["cache_read_input_tokens"] = script.Usage.CacheReadTokens
		startUsage["cache_creation_input_tokens"] = script.Usage.CacheWriteTokens
	}
	if !writeAnthropicEvent(w, flusher, "message_start", map[string]any{
		"type": "message_start",
		"message": map[string]any{
			"id":            "msg_fake",
			"type":          "message",
			"role":          "assistant",
			"model":         "claude-fake",
			"content":       []any{},
			"stop_reason":   nil,
			"stop_sequence": nil,
			"usage":         startUsage,
		},
	}) {
		return
	}

	// In-stream error: emit an error event and stop. (The Anthropic SDK
	// surfaces this via stream.Err() after the loop exits.)
	if script.Error != nil {
		writeAnthropicEvent(w, flusher, "error", map[string]any{
			"type": "error",
			"error": map[string]any{
				"type":    coalesceErrCode(script.Error.Code, "api_error"),
				"message": script.Error.Message,
			},
		})
		return
	}

	// One content block per event. blockIndex monotonically increments so
	// the SDK keeps blocks distinct.
	blockIndex := 0
	for _, ev := range script.Events {
		if ev.Delay > 0 {
			if !sleepCtx(ctx, ev.Delay) {
				return
			}
		}
		if !emitAnthropicEvent(w, flusher, &blockIndex, ev) {
			return
		}
	}

	// message_delta carries final output_tokens (and reasoning/cache reads
	// in newer API versions). The Reeve driver reads this for terminal usage.
	deltaUsage := map[string]any{"output_tokens": 0}
	if script.Usage != nil {
		deltaUsage["output_tokens"] = script.Usage.OutputTokens
		// Anthropic re-emits these on message_delta in current API.
		deltaUsage["input_tokens"] = script.Usage.InputTokens
		deltaUsage["cache_read_input_tokens"] = script.Usage.CacheReadTokens
		deltaUsage["cache_creation_input_tokens"] = script.Usage.CacheWriteTokens
	}
	if !writeAnthropicEvent(w, flusher, "message_delta", map[string]any{
		"type":  "message_delta",
		"delta": map[string]any{"stop_reason": "end_turn", "stop_sequence": nil},
		"usage": deltaUsage,
	}) {
		return
	}
	writeAnthropicEvent(w, flusher, "message_stop", map[string]any{
		"type": "message_stop",
	})
}

// emitAnthropicEvent writes one Event as the appropriate
// content_block_start + content_block_delta + content_block_stop sequence,
// advancing *blockIndex.
func emitAnthropicEvent(w io.Writer, flusher http.Flusher, blockIndex *int, ev Event) bool {
	idx := *blockIndex

	switch ev.Type {
	case EventText:
		if !writeAnthropicEvent(w, flusher, "content_block_start", map[string]any{
			"type":          "content_block_start",
			"index":         idx,
			"content_block": map[string]any{"type": "text", "text": ""},
		}) {
			return false
		}
		if !writeAnthropicEvent(w, flusher, "content_block_delta", map[string]any{
			"type":  "content_block_delta",
			"index": idx,
			"delta": map[string]any{"type": "text_delta", "text": ev.Text},
		}) {
			return false
		}
		if !writeAnthropicEvent(w, flusher, "content_block_stop", map[string]any{
			"type":  "content_block_stop",
			"index": idx,
		}) {
			return false
		}

	case EventThinking:
		if !writeAnthropicEvent(w, flusher, "content_block_start", map[string]any{
			"type":          "content_block_start",
			"index":         idx,
			"content_block": map[string]any{"type": "thinking", "thinking": ""},
		}) {
			return false
		}
		if !writeAnthropicEvent(w, flusher, "content_block_delta", map[string]any{
			"type":  "content_block_delta",
			"index": idx,
			"delta": map[string]any{"type": "thinking_delta", "thinking": ev.Text},
		}) {
			return false
		}
		if !writeAnthropicEvent(w, flusher, "content_block_stop", map[string]any{
			"type":  "content_block_stop",
			"index": idx,
		}) {
			return false
		}

	case EventToolUseStart:
		if !writeAnthropicEvent(w, flusher, "content_block_start", map[string]any{
			"type":  "content_block_start",
			"index": idx,
			"content_block": map[string]any{
				"type":  "tool_use",
				"id":    ev.ToolID,
				"name":  ev.ToolName,
				"input": map[string]any{},
			},
		}) {
			return false
		}
		// Don't advance blockIndex — subsequent ToolUseDelta / ToolUseEnd
		// events refer to the same open block. Caller responsibility.
		return true

	case EventToolUseDelta:
		// Index points at the most-recently-opened block (idx-1, since
		// we only advance after End). For simplicity tests should keep
		// one tool call open at a time.
		openIdx := idx
		if openIdx > 0 {
			openIdx = idx
		}
		if !writeAnthropicEvent(w, flusher, "content_block_delta", map[string]any{
			"type":  "content_block_delta",
			"index": openIdx,
			"delta": map[string]any{
				"type":         "input_json_delta",
				"partial_json": string(ev.ToolInput),
			},
		}) {
			return false
		}
		return true

	case EventToolUseEnd:
		if !writeAnthropicEvent(w, flusher, "content_block_stop", map[string]any{
			"type":  "content_block_stop",
			"index": idx,
		}) {
			return false
		}

	default:
		// Unknown event type — no-op.
		return true
	}

	*blockIndex++
	return true
}

// writeAnthropicEvent serializes one SSE event with the given event name and
// JSON data. Returns false if the writer fails (client gone, network error).
func writeAnthropicEvent(w io.Writer, flusher http.Flusher, event string, data any) bool {
	payload, err := json.Marshal(data)
	if err != nil {
		// Static maps marshalled here don't fail in practice; if they do,
		// fall back to a parseable empty object so the SDK doesn't choke.
		payload = []byte(`{}`)
	}
	if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, payload); err != nil {
		return false
	}
	flusher.Flush()
	return true
}

// sleepCtx sleeps for d, returning false if ctx cancels first.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-time.After(d):
		return true
	case <-ctx.Done():
		return false
	}
}
