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

// CompletionEvent is the payload a Broker fires to its
// CompletionHook after every Invoke returns (success or failure).
// Used by the conversations service to persist an audit row in
// device_tool_calls without entangling persistence into the broker
// itself.
type CompletionEvent struct {
	CallID         uuid.UUID
	ConversationID uuid.UUID
	ToolName       string
	Input          json.RawMessage
	// Output is non-nil + Status == "ok" on success. Both Output
	// and ErrorMessage may be non-empty when the client returned
	// a partial output alongside a soft error — the broker
	// passes both through and lets the hook decide what to log.
	Output       json.RawMessage
	Status       string  // "ok" | "error" | "timeout"
	ErrorMessage string
	InvokedAt    time.Time
	CompletedAt  time.Time
}

// CompletionHook receives every completed tool call. nil = no
// audit logging. Errors in the hook are the caller's problem —
// the broker logs nothing itself, just hands the event over.
type CompletionHook func(CompletionEvent)

// Broker is the in-memory router. Safe for concurrent use.
type Broker struct {
	mu      sync.Mutex
	pending map[uuid.UUID]*pendingCall
	// hook fires once per completed Invoke (success or failure).
	// Plain field rather than method-args because the hook is
	// process-wide; setting it once at startup keeps the call
	// sites lean.
	hook CompletionHook
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

// SetCompletionHook installs (or replaces) the post-call hook.
// Pass nil to drop the existing hook. Safe to call at startup;
// not safe to call concurrently with Invoke (cheap to set once
// from cmd/reeved or the conversations service constructor).
func (b *Broker) SetCompletionHook(h CompletionHook) {
	b.hook = h
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
	invokedAt := req.IssuedAt
	select {
	case resp := <-ch:
		b.fireHook(CompletionEvent{
			CallID: id, ConversationID: convoID, ToolName: toolName,
			Input: input, Output: resp.Output,
			Status: statusFromResponse(resp), ErrorMessage: resp.Error,
			InvokedAt: invokedAt, CompletedAt: time.Now().UTC(),
		})
		if resp.Error != "" {
			return nil, fmt.Errorf("device tool %s: %s", toolName, resp.Error)
		}
		return resp.Output, nil
	case <-timeoutCtx.Done():
		b.fireHook(CompletionEvent{
			CallID: id, ConversationID: convoID, ToolName: toolName,
			Input: input,
			Status: "timeout", ErrorMessage: timeoutCtx.Err().Error(),
			InvokedAt: invokedAt, CompletedAt: time.Now().UTC(),
		})
		return nil, fmt.Errorf("device tool %s (call %s): %w",
			toolName, id, timeoutCtx.Err())
	}
}

// fireHook invokes the completion hook if installed. Wrapped in a
// recover so a panicking hook can't take down the dispatch path —
// audit logging is best-effort by design.
func (b *Broker) fireHook(ev CompletionEvent) {
	if b.hook == nil {
		return
	}
	defer func() { _ = recover() }()
	b.hook(ev)
}

func statusFromResponse(r Response) string {
	if r.Error != "" {
		return "error"
	}
	return "ok"
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
