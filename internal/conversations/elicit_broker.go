package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/elicit"
)

// elicitTimeout is how long a tool's Elicit call waits for the user's
// response before giving up. Generous on purpose: typing an API key
// from a password manager or another window can take a minute or two.
// Tools see the resulting context.DeadlineExceeded as "user didn't
// respond" and can surface that to the model.
const elicitTimeout = 5 * time.Minute

// elicitBroker matches pending elicitations to user responses. One
// instance per Service — the conversation tool loop creates an
// ElicitClient bound to this broker for every assistant turn that
// dispatches tools.
//
// The broker exposes two surfaces:
//
//   - the tool-call side (via NewClient / clientImpl.Elicit): the
//     tool blocks until a response arrives or the timeout fires.
//   - the HTTP side (Respond): the user-facing endpoint writes the
//     submitted form back into the matching pending slot.
//
// State is purely in-memory: each pending request lives only as long
// as the goroutine waiting on it. A server restart abandons every
// in-flight elicitation (the user's submit would 404), but that's no
// worse than the request already being lost — the assistant's tool
// call also dies on restart.
type elicitBroker struct {
	mu       sync.Mutex
	pending  map[uuid.UUID]*pendingElicit
}

type pendingElicit struct {
	conversationID uuid.UUID
	request        elicit.Request
	respond        chan elicit.Response
	createdAt      time.Time
}

// PendingElicitSnapshot is the read-only projection clients consult
// when they need to render the elicitation form (e.g. on a reload
// that lands after the chunk that announced the elicitation). Not
// used by the live-stream path — that pushes the request via the
// stream chunk directly.
type PendingElicitSnapshot struct {
	ID             uuid.UUID
	ConversationID uuid.UUID
	Message        string
	RequestedSchema json.RawMessage
	CreatedAt      time.Time
}

func newElicitBroker() *elicitBroker {
	return &elicitBroker{pending: map[uuid.UUID]*pendingElicit{}}
}

// register allocates an id, stores a pending entry, and returns both
// the id and the response channel. Callers must `defer drop(id)` to
// clean up the entry whether the wait succeeds, times out, or the
// caller's context is canceled.
func (b *elicitBroker) register(convoID uuid.UUID, req elicit.Request) (uuid.UUID, chan elicit.Response, error) {
	id, err := uuid.NewV7()
	if err != nil {
		return uuid.Nil, nil, err
	}
	ch := make(chan elicit.Response, 1)
	b.mu.Lock()
	defer b.mu.Unlock()
	b.pending[id] = &pendingElicit{
		conversationID: convoID,
		request:        req,
		respond:        ch,
		createdAt:      time.Now(),
	}
	return id, ch, nil
}

// drop removes a pending entry. Idempotent: dropping an unknown id is
// a no-op. Called from the waiting goroutine's defer.
func (b *elicitBroker) drop(id uuid.UUID) {
	b.mu.Lock()
	delete(b.pending, id)
	b.mu.Unlock()
}

// Respond delivers a user response to a waiting tool call. Returns
// ErrElicitationNotFound when the id is unknown (already responded,
// timed out, or never existed) and ErrElicitationCrossConversation
// when convoID doesn't match the one the elicitation was registered
// under (defense-in-depth — the HTTP handler also checks ownership
// via the convo-owner auth gate).
func (b *elicitBroker) Respond(convoID uuid.UUID, id uuid.UUID, resp elicit.Response) error {
	b.mu.Lock()
	p, ok := b.pending[id]
	if !ok {
		b.mu.Unlock()
		return ErrElicitationNotFound
	}
	if p.conversationID != convoID {
		b.mu.Unlock()
		return ErrElicitationCrossConversation
	}
	// Pull it out so a second Respond hits ErrElicitationNotFound
	// rather than blocking on a full channel.
	delete(b.pending, id)
	ch := p.respond
	b.mu.Unlock()
	// Non-blocking send — buffer is 1, the slot is fresh, the
	// receiver may have already given up (e.g. ctx cancel between
	// the lookup and the send). In that case the send silently
	// drops; the caller still gets an OK on the HTTP side, which is
	// fine because the user did their part.
	select {
	case ch <- resp:
	default:
	}
	return nil
}

// snapshot returns the read-only metadata for a pending elicitation,
// or false if not present. Used by GET endpoints that want to render
// a form on demand (e.g. when the client reconnects after the chunk
// announcing the elicitation has already been consumed).
func (b *elicitBroker) snapshot(id uuid.UUID) (PendingElicitSnapshot, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	p, ok := b.pending[id]
	if !ok {
		return PendingElicitSnapshot{}, false
	}
	return PendingElicitSnapshot{
		ID:              id,
		ConversationID:  p.conversationID,
		Message:         p.request.Message,
		RequestedSchema: p.request.RequestedSchema,
		CreatedAt:       p.createdAt,
	}, true
}

// ErrElicitationNotFound is returned by Respond when the id is
// unknown — already responded, timed out, never existed.
var ErrElicitationNotFound = errors.New("elicitation not found")

// ErrElicitationCrossConversation is returned when a respond attempt
// targets the wrong conversation id. Defense-in-depth — should not
// occur if the HTTP handler's auth gate is correct.
var ErrElicitationCrossConversation = errors.New("elicitation: conversation mismatch")

// elicitClientImpl is the per-tool-call ElicitClient. Bound to the
// broker (for response routing) and the assistant's chunk-out channel
// (for surfacing the request to the client mid-stream). Each tool
// dispatch gets a fresh instance via newElicitClient so the chunk
// channel matches the right run.
type elicitClientImpl struct {
	broker        *elicitBroker
	convoID       uuid.UUID
	emitChunk     func(elicitID uuid.UUID, req elicit.Request)
}

// newElicitClient binds a client to one run. `emitChunk` is the hook
// the conversations side passes in so Elicit can deliver an "ask the
// user" chunk into the assistant message stream the same goroutine is
// already writing to.
func newElicitClient(broker *elicitBroker, convoID uuid.UUID, emitChunk func(uuid.UUID, elicit.Request)) elicit.Client {
	return &elicitClientImpl{broker: broker, convoID: convoID, emitChunk: emitChunk}
}

func (c *elicitClientImpl) Elicit(ctx context.Context, req elicit.Request) (elicit.Response, error) {
	id, ch, err := c.broker.register(c.convoID, req)
	if err != nil {
		return elicit.Response{}, fmt.Errorf("register elicitation: %w", err)
	}
	defer c.broker.drop(id)

	// Emit the chunk after registration so the channel is ready by
	// the time the client could conceivably respond. (The 1-slot
	// buffer means we'd still catch a near-instant response if the
	// order flipped, but ordering this way avoids a tiny race
	// window in tests.)
	if c.emitChunk != nil {
		c.emitChunk(id, req)
	}

	timeoutCtx, cancel := context.WithTimeout(ctx, elicitTimeout)
	defer cancel()
	select {
	case resp := <-ch:
		return resp, nil
	case <-timeoutCtx.Done():
		// Distinguish "user took too long" from "context canceled
		// upstream" only by the underlying cause — tools usually
		// don't need to care, but the difference shows up in
		// logs.
		return elicit.Response{}, fmt.Errorf("elicitation %s: %w", id, timeoutCtx.Err())
	}
}
