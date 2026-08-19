package claudecode

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/jdpedrie/psmith/claudesdk"
	"github.com/jdpedrie/psmith/server/providers"
)

// SendInSession runs one CLI turn against the session handle and streams
// normalized chunks. Only plain user text is supported: the harness has no
// wire for tool results or attachments from the caller's side, and those
// fields are silently dropped per the driver rules. Sampling knobs in
// CallSettings have no CLI equivalent and are likewise dropped.
func (d *Driver) SendInSession(ctx context.Context, sessionID string, msg providers.WireMessage, settings providers.CallSettings) (<-chan providers.Chunk, error) {
	if msg.Role != "user" {
		return nil, fmt.Errorf("claudecode: only user messages can be sent in-session (got role %q)", msg.Role)
	}
	if msg.Content == "" {
		return nil, fmt.Errorf("claudecode: empty message")
	}
	setup, err := d.resolveHandle(sessionID)
	if err != nil {
		return nil, err
	}

	iter, err := claudesdk.Query(ctx, msg.Content, d.queryOptions(setup)...)
	if err != nil {
		return nil, fmt.Errorf("claudecode: start query: %w", err)
	}

	out := make(chan providers.Chunk, 16)
	go func() {
		defer close(out)
		defer iter.Close()
		d.pump(ctx, out, iter, setup)
	}()
	return out, nil
}

// pump drains the CLI message stream into normalized chunks. Assistant text
// streams as it arrives; the terminal ResultMessage yields the session
// handle, usage, and done marker.
func (d *Driver) pump(ctx context.Context, out chan<- providers.Chunk, iter claudesdk.MessageIterator, setup turnSetup) {
	emitErr := func(msg string) {
		payload, _ := json.Marshal(map[string]string{"message": msg})
		sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkError, Payload: payload})
	}

	textEmitted := false
	for {
		m, err := iter.Next(ctx)
		if err != nil {
			if err == io.EOF {
				emitErr("claudecode: stream ended without a result message")
				return
			}
			emitErr(err.Error())
			return
		}

		switch v := m.(type) {
		case *claudesdk.AssistantMessage:
			var text string
			for _, block := range v.Content {
				if tb, ok := block.(*claudesdk.TextBlock); ok {
					text += tb.Text
				}
			}
			if text != "" {
				payload, _ := json.Marshal(map[string]string{"text": text})
				if !sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkText, Payload: payload}) {
					return
				}
				textEmitted = true
			}
		case *claudesdk.ResultMessage:
			if v.IsError {
				msg := "claudecode: harness reported an error"
				if v.Result != nil && *v.Result != "" {
					msg = *v.Result
				}
				emitErr(msg)
				return
			}
			// The result text duplicates the assistant messages already
			// streamed; emit it only when nothing streamed (defensive —
			// some CLI versions omit assistant messages in --print mode).
			if !textEmitted && v.Result != nil && *v.Result != "" {
				payload, _ := json.Marshal(map[string]string{"text": *v.Result})
				if !sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkText, Payload: payload}) {
					return
				}
			}

			if v.SessionID != "" {
				handle := encodeHandle(setup.model, v.SessionID)
				payload, _ := json.Marshal(map[string]string{"session_id": handle})
				if !sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkSessionHandle, Payload: payload}) {
					return
				}
				if setup.fromHandle != "" {
					// The provisional handle served its purpose; the
					// durable handle just emitted supersedes it.
					d.mu.Lock()
					delete(d.pending, setup.fromHandle)
					d.mu.Unlock()
				}
			}

			if payload := usagePayload(v); payload != nil {
				if !sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkUsage, Payload: payload}) {
					return
				}
			}
			sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkDone, Payload: []byte(`{}`)})
			return
		}
		// System and user echo messages carry no chat content; skip.
	}
}

// usagePayload maps the CLI's loosely-typed usage blob onto the normalized
// Usage shape. Returns nil when the result carried no usage.
func usagePayload(v *claudesdk.ResultMessage) json.RawMessage {
	if v.Usage == nil {
		return nil
	}
	raw, err := json.Marshal(*v.Usage)
	if err != nil {
		return nil
	}
	var u providers.Usage
	if n, ok := intField(*v.Usage, "input_tokens"); ok {
		u.InputTokens = &n
	}
	if n, ok := intField(*v.Usage, "output_tokens"); ok {
		u.OutputTokens = &n
	}
	if n, ok := intField(*v.Usage, "cache_read_input_tokens"); ok {
		u.CacheReadTokens = &n
	}
	if n, ok := intField(*v.Usage, "cache_creation_input_tokens"); ok {
		u.CacheWriteTokens = &n
	}
	u.ProviderRaw = raw
	fr := "end_turn"
	u.FinishReason = &fr
	payload, err := json.Marshal(u)
	if err != nil {
		return nil
	}
	return payload
}

func intField(m map[string]any, key string) (int, bool) {
	f, ok := m[key].(float64) // JSON numbers decode as float64
	if !ok {
		return 0, false
	}
	return int(f), true
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
