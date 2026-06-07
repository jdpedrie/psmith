// Package devicetools brokers tool calls between server-side plugin
// dispatch and the connected client that actually runs them
// (calendar / contacts / Obsidian vault access on iOS or Mac).
//
// Mirrors internal/conversations/elicit_broker.go almost exactly —
// same emit-chunk + wait-for-HTTP-response pattern, different
// payload shape and timeout. The duplication is intentional: each
// broker is small enough that factoring out a shared "request-
// response broker" abstraction would obscure the call sites more
// than it would save code.
//
// Lifecycle: one Broker per Service instance, lives for the daemon
// lifetime. Each device-tool invocation registers a pending entry
// keyed by a fresh UUID, emits a DEVICE_TOOL_USE chunk, blocks until
// either the matching POST /respond arrives or the per-tool timeout
// fires.
package devicetools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Default timeout for a single device-tool dispatch. Bigger than
// the elicit broker's because some tools (full-vault search) can
// take a while; tools that need more should be opted out at the
// catalog level. The model sees a context-deadline-exceeded as an
// ordinary tool error.
const DefaultTimeout = 60 * time.Second

// Request is the model-visible side of a device-tool call. The
// Broker emits this as JSON into a CHUNK_TYPE_DEVICE_TOOL_USE
// payload; the client decodes, dispatches to its handler, posts a
// Response back.
type Request struct {
	CallID    uuid.UUID       `json:"call_id"`
	ToolName  string          `json:"tool_name"`
	Input     json.RawMessage `json:"input"`
	IssuedAt  time.Time       `json:"issued_at"`
}

// Response is what the client POSTs back. `Output` is the JSON the
// model will see on the next round (the structured tool answer).
// `Error` is non-empty when the client failed to run the tool —
// permission denied, OS API error, malformed input. The broker
// converts a non-empty Error into a Go error returned to the
// waiting tool dispatch.
type Response struct {
	Output json.RawMessage `json:"output"`
	Error  string          `json:"error,omitempty"`
}

// Broker is the in-memory router. Safe for concurrent use.
type Broker struct {
	mu      sync.Mutex
	pending map[uuid.UUID]*pendingCall
}

type pendingCall struct {
	conversationID uuid.UUID
	toolName       string
	respond        chan Response
	createdAt      time.Time
}

// NewBroker constructs an empty broker.
func NewBroker() *Broker {
	return &Broker{pending: map[uuid.UUID]*pendingCall{}}
}

// EmitFunc is the hook the conversations layer passes in to
// surface a Request into the live assistant chunk stream. Bound
// per-invocation because the chunk channel belongs to a specific
// run.
type EmitFunc func(req Request)

// Invoke is the server-side entrypoint — called from the
// `app_tools` plugin's ExecuteTool. Emits a chunk via `emit`,
// blocks until the client responds or `timeout` elapses, returns
// the structured output (or a tool error).
//
// Wrapping a tool error vs returning a real Go error: client-
// reported failures (Response.Error) come back as a Go error with
// the wrapped message — the tool loop treats this as a normal
// tool failure and the model sees the error text on the next
// round. Transport-level failures (timeout, ctx cancel) come back
// as the underlying ctx error, which the tool loop also surfaces.
func (b *Broker) Invoke(
	ctx context.Context,
	convoID uuid.UUID,
	toolName string,
	input json.RawMessage,
	timeout time.Duration,
	emit EmitFunc,
) (json.RawMessage, error) {
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	id, ch, err := b.register(convoID, toolName)
	if err != nil {
		return nil, fmt.Errorf("register device-tool call: %w", err)
	}
	defer b.drop(id)

	req := Request{
		CallID:   id,
		ToolName: toolName,
		Input:    input,
		IssuedAt: time.Now().UTC(),
	}
	if emit != nil {
		emit(req)
	}

	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	select {
	case resp := <-ch:
		if resp.Error != "" {
			return nil, fmt.Errorf("device tool %s: %s", toolName, resp.Error)
		}
		return resp.Output, nil
	case <-timeoutCtx.Done():
		return nil, fmt.Errorf("device tool %s (call %s): %w",
			toolName, id, timeoutCtx.Err())
	}
}

// Respond delivers a client's response to a waiting Invoke. Returns
// ErrCallNotFound when the id is unknown (already responded,
// timed out, or never existed) and ErrCallCrossConversation when
// convoID doesn't match what the call was registered under
// (defense-in-depth — the HTTP handler's auth gate is the
// primary check).
func (b *Broker) Respond(convoID uuid.UUID, callID uuid.UUID, resp Response) error {
	b.mu.Lock()
	p, ok := b.pending[callID]
	if !ok {
		b.mu.Unlock()
		return ErrCallNotFound
	}
	if p.conversationID != convoID {
		b.mu.Unlock()
		return ErrCallCrossConversation
	}
	// Pull it out so a second Respond hits ErrCallNotFound rather
	// than blocking on a full channel.
	delete(b.pending, callID)
	ch := p.respond
	b.mu.Unlock()
	// Non-blocking send — buffer is 1, slot is fresh. If the
	// receiver gave up between lookup and send (ctx cancel race),
	// the send drops silently; HTTP-side still gets OK.
	select {
	case ch <- resp:
	default:
	}
	return nil
}

// register allocates an id, stores a pending entry, returns id +
// response channel. Caller must `defer drop(id)`.
func (b *Broker) register(convoID uuid.UUID, toolName string) (uuid.UUID, chan Response, error) {
	id, err := uuid.NewV7()
	if err != nil {
		return uuid.Nil, nil, err
	}
	ch := make(chan Response, 1)
	b.mu.Lock()
	defer b.mu.Unlock()
	b.pending[id] = &pendingCall{
		conversationID: convoID,
		toolName:       toolName,
		respond:        ch,
		createdAt:      time.Now(),
	}
	return id, ch, nil
}

func (b *Broker) drop(id uuid.UUID) {
	b.mu.Lock()
	delete(b.pending, id)
	b.mu.Unlock()
}

// PendingSnapshot is the read-only metadata projection for a single
// in-flight call. Used by the GET endpoint that lets a reconnecting
// client re-fetch the request it missed.
type PendingSnapshot struct {
	CallID         uuid.UUID
	ConversationID uuid.UUID
	ToolName       string
	CreatedAt      time.Time
}

// Snapshot returns the metadata for a pending call, or false if not
// present (already responded / timed out / unknown id).
func (b *Broker) Snapshot(id uuid.UUID) (PendingSnapshot, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	p, ok := b.pending[id]
	if !ok {
		return PendingSnapshot{}, false
	}
	return PendingSnapshot{
		CallID:         id,
		ConversationID: p.conversationID,
		ToolName:       p.toolName,
		CreatedAt:      p.createdAt,
	}, true
}

// Errors returned by Respond.
var (
	// ErrCallNotFound — the call id is unknown (already
	// responded, timed out, never existed).
	ErrCallNotFound = errors.New("device tool: call not found")
	// ErrCallCrossConversation — defensive check; HTTP-handler
	// auth gate is the primary defense.
	ErrCallCrossConversation = errors.New("device tool: conversation mismatch")
)
