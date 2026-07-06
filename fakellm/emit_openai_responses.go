package fakellm

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// emitOpenAIResponses writes a Script as an OpenAI Responses API SSE event
// stream. Minimum sequence to satisfy the SDK parser + Psmith driver:
//
//	event: response.created
//	data: {"response":{"id":"resp_x","status":"in_progress"}}
//
//	event: response.output_text.delta
//	data: {"item_id":"msg_x","output_index":0,"delta":"Hello"}
//
//	event: response.completed
//	data: {"response":{"id":"resp_x","status":"completed","usage":{...}}}
//
// Reasoning deltas use response.reasoning_summary_text.delta. Tool calls use
// response.output_item.added (function_call) + response.function_call_arguments.delta
// + response.output_item.done.
func emitOpenAIResponses(ctx context.Context, w io.Writer, flusher http.Flusher, script Script) {
	const respID = "resp_fake"
	const itemID = "msg_fake"

	// In-stream errors: emit a top-level `error` event. The driver maps
	// this to ChunkError.
	if script.Error != nil {
		writeOAResponsesEvent(w, flusher, "error", map[string]any{
			"type":    "error",
			"message": script.Error.Message,
			"code":    coalesceErrCode(script.Error.Code, "error"),
		})
		return
	}

	if !writeOAResponsesEvent(w, flusher, "response.created", map[string]any{
		"type": "response.created",
		"response": map[string]any{
			"id":     respID,
			"status": "in_progress",
		},
	}) {
		return
	}

	for _, ev := range script.Events {
		if ev.Delay > 0 {
			if !sleepCtx(ctx, ev.Delay) {
				return
			}
		}
		if !emitOAResponsesEvent(w, flusher, itemID, ev) {
			return
		}
	}

	// Build the terminal response object with usage.
	resp := map[string]any{
		"id":     respID,
		"status": "completed",
	}
	if script.Usage != nil {
		usage := map[string]any{
			"input_tokens":  script.Usage.InputTokens,
			"output_tokens": script.Usage.OutputTokens,
			"total_tokens":  script.Usage.InputTokens + script.Usage.OutputTokens,
		}
		if script.Usage.CacheReadTokens > 0 {
			usage["input_tokens_details"] = map[string]any{
				"cached_tokens": script.Usage.CacheReadTokens,
			}
		}
		if script.Usage.ReasoningTokens > 0 {
			usage["output_tokens_details"] = map[string]any{
				"reasoning_tokens": script.Usage.ReasoningTokens,
			}
		}
		resp["usage"] = usage
	}
	writeOAResponsesEvent(w, flusher, "response.completed", map[string]any{
		"type":     "response.completed",
		"response": resp,
	})
}

// emitOAResponsesEvent emits one Event in Responses-API shape.
func emitOAResponsesEvent(w io.Writer, flusher http.Flusher, itemID string, ev Event) bool {
	switch ev.Type {
	case EventText:
		return writeOAResponsesEvent(w, flusher, "response.output_text.delta", map[string]any{
			"type":         "response.output_text.delta",
			"item_id":      itemID,
			"output_index": 0,
			"delta":        ev.Text,
		})

	case EventThinking:
		return writeOAResponsesEvent(w, flusher, "response.reasoning_summary_text.delta", map[string]any{
			"type":         "response.reasoning_summary_text.delta",
			"item_id":      itemID,
			"output_index": 0,
			"delta":        ev.Text,
		})

	case EventToolUseStart:
		return writeOAResponsesEvent(w, flusher, "response.output_item.added", map[string]any{
			"type": "response.output_item.added",
			"item": map[string]any{
				"type":    "function_call",
				"id":      ev.ToolID,
				"call_id": ev.ToolID,
				"name":    ev.ToolName,
			},
		})

	case EventToolUseDelta:
		return writeOAResponsesEvent(w, flusher, "response.function_call_arguments.delta", map[string]any{
			"type":    "response.function_call_arguments.delta",
			"item_id": ev.ToolID,
			"delta":   string(ev.ToolInput),
		})

	case EventToolUseEnd:
		args := string(ev.ToolInput)
		if args == "" {
			args = "{}"
		}
		return writeOAResponsesEvent(w, flusher, "response.output_item.done", map[string]any{
			"type": "response.output_item.done",
			"item": map[string]any{
				"type":      "function_call",
				"id":        ev.ToolID,
				"call_id":   ev.ToolID,
				"name":      ev.ToolName,
				"arguments": args,
			},
		})

	default:
		return true
	}
}

// writeOAResponsesEvent serializes one SSE event in the Responses API shape.
func writeOAResponsesEvent(w io.Writer, flusher http.Flusher, event string, data any) bool {
	payload, err := json.Marshal(data)
	if err != nil {
		payload = []byte(`{}`)
	}
	if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, payload); err != nil {
		return false
	}
	flusher.Flush()
	return true
}
