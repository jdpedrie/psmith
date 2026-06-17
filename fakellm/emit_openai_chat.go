package fakellm

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// emitOpenAIChat writes a Script as an OpenAI Chat Completions chunked SSE
// stream. Shape per chunk:
//
//	data: {"id":"chatcmpl-x","object":"chat.completion.chunk","model":"gpt-fake","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
//
// The last delta-bearing chunk has finish_reason: "stop" on its choice. If
// usage is non-nil, an additional chunk follows with empty choices and a
// populated `usage` field (the SDK requires stream_options.include_usage on
// the request — Spalt's driver always sets it). The terminator is the
// literal `data: [DONE]\n\n`.
//
// Thinking events are silently dropped: Chat Completions has no reasoning
// channel.
func emitOpenAIChat(ctx context.Context, w io.Writer, flusher http.Flusher, script Script) {
	const id = "chatcmpl-fake"
	const model = "gpt-fake"

	// In-stream errors don't have a clean Chat-Completions shape; the SDK
	// surfaces them as a stream-decode failure when the trailing `[DONE]`
	// is missing or the JSON is malformed. We approximate by writing an
	// error envelope chunk and skipping `[DONE]`.
	if script.Error != nil {
		writeChatChunk(w, flusher, map[string]any{
			"error": map[string]any{
				"message": script.Error.Message,
				"type":    "invalid_request_error",
				"code":    coalesceErrCode(script.Error.Code, "error"),
			},
		})
		return
	}

	// Filter to only events Chat understands — text deltas. Tool calls
	// would map to choices[].delta.tool_calls, deferred until the driver
	// supports tool use round-trip.
	for _, ev := range script.Events {
		if ev.Delay > 0 {
			if !sleepCtx(ctx, ev.Delay) {
				return
			}
		}
		if ev.Type != EventText {
			continue
		}
		writeChatChunk(w, flusher, map[string]any{
			"id":     id,
			"object": "chat.completion.chunk",
			"model":  model,
			"choices": []any{
				map[string]any{
					"index":         0,
					"delta":         map[string]any{"content": ev.Text},
					"finish_reason": nil,
				},
			},
		})
	}

	// finish_reason chunk — always emitted so the SDK sees a clean
	// termination of the choice (with or without preceding text deltas).
	writeChatChunk(w, flusher, map[string]any{
		"id":     id,
		"object": "chat.completion.chunk",
		"model":  model,
		"choices": []any{
			map[string]any{
				"index":         0,
				"delta":         map[string]any{},
				"finish_reason": "stop",
			},
		},
	})

	// Usage chunk (only when usage is populated). choices is empty per
	// the OpenAI spec for the trailing usage chunk.
	if script.Usage != nil {
		usage := map[string]any{
			"prompt_tokens":     script.Usage.InputTokens,
			"completion_tokens": script.Usage.OutputTokens,
			"total_tokens":      script.Usage.InputTokens + script.Usage.OutputTokens,
		}
		if script.Usage.CacheReadTokens > 0 {
			usage["prompt_tokens_details"] = map[string]any{
				"cached_tokens": script.Usage.CacheReadTokens,
			}
		}
		if script.Usage.ReasoningTokens > 0 {
			usage["completion_tokens_details"] = map[string]any{
				"reasoning_tokens": script.Usage.ReasoningTokens,
			}
		}
		writeChatChunk(w, flusher, map[string]any{
			"id":      id,
			"object":  "chat.completion.chunk",
			"model":   model,
			"choices": []any{},
			"usage":   usage,
		})
	}

	_, _ = w.Write([]byte("data: [DONE]\n\n"))
	flusher.Flush()
}

// writeChatChunk serializes one Chat-Completions chunk envelope.
func writeChatChunk(w io.Writer, flusher http.Flusher, payload any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		raw = []byte(`{}`)
	}
	if _, err := fmt.Fprintf(w, "data: %s\n\n", raw); err != nil {
		return
	}
	flusher.Flush()
}
