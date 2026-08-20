package codex

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jdpedrie/psmith/codexsdk"
	"github.com/jdpedrie/psmith/server/providers"
)

// SendInSession runs one turn against the handle and streams normalized
// chunks.
//
// The handle decides the shape of the turn, and this is where the contract's
// immutable-snapshot promise is honored:
//
//   - Provisional handle: no thread exists yet, so start one.
//   - Durable handle: FORK the thread at that handle's turn. Never resume.
//
// Always forking is the point. Resuming would append in place and mutate the
// state that other handles name, so a user editing message five would silently
// corrupt the branch they forked from. Forking costs nothing upstream and
// makes every handle a snapshot, which is what lets Psmith's message tree and
// Codex's thread graph stay in agreement.
//
// Only plain user text travels. The harness has no wire for tool results or
// attachments from the caller's side, and those fields are dropped per the
// driver rules.
func (d *Driver) SendInSession(
	ctx context.Context,
	sessionID string,
	msg providers.WireMessage,
	_ providers.CallSettings,
) (<-chan providers.Chunk, error) {
	if msg.Role != "user" {
		return nil, fmt.Errorf("codex: only user messages can be sent in-session (got role %q)", msg.Role)
	}
	if msg.Content == "" {
		return nil, fmt.Errorf("codex: empty message")
	}
	setup, err := d.resolveHandle(sessionID)
	if err != nil {
		return nil, err
	}
	client, err := d.clientFor(ctx)
	if err != nil {
		return nil, fmt.Errorf("codex: start app-server: %w", err)
	}

	// A chat harness must never stall on an approval prompt: nobody is
	// sitting behind it to answer one. Read-only with approvals off means
	// Codex has nothing to ask about. The SDK declines any request that
	// arrives anyway, so a config change upstream cannot reintroduce a hang.
	opts := codexsdk.ThreadOptions{
		Model:            setup.model,
		BaseInstructions: setup.baseInstructions,
		Sandbox:          "read-only",
		ApprovalPolicy:   "never",
	}

	var thread *codexsdk.Thread
	if setup.threadID == "" {
		thread, err = client.StartThread(ctx, opts)
		if err != nil {
			return nil, fmt.Errorf("codex: start thread: %w", err)
		}
	} else {
		// Fork rather than resume, always. See the doc comment above.
		//
		// baseInstructions is deliberately NOT passed on a fork: Codex would
		// accept it, but the system prompt is fixed for a conversation's
		// lifetime in Psmith, and passing it here would let a profile edit
		// silently change history's framing on the next branch.
		thread, err = client.ForkThread(ctx, setup.threadID, setup.turnID, codexsdk.ThreadOptions{
			Model:          setup.model,
			Sandbox:        "read-only",
			ApprovalPolicy: "never",
		})
		if err != nil {
			return nil, fmt.Errorf("codex: fork thread %s at turn %q: %w", setup.threadID, setup.turnID, err)
		}
	}

	events, err := thread.Send(ctx, msg.Content, codexsdk.ThreadOptions{Model: setup.model})
	if err != nil {
		return nil, fmt.Errorf("codex: start turn: %w", err)
	}

	out := make(chan providers.Chunk, 16)
	go func() {
		defer close(out)
		d.pump(ctx, out, events, setup, thread.ID())
	}()
	return out, nil
}

// pump translates Codex events into normalized chunks.
func (d *Driver) pump(
	ctx context.Context,
	out chan<- providers.Chunk,
	events <-chan codexsdk.Event,
	setup turnSetup,
	threadID string,
) {
	emit := func(t providers.ChunkType, v any) bool {
		payload, err := json.Marshal(v)
		if err != nil {
			return true
		}
		return sendChunk(ctx, out, providers.Chunk{Type: t, Payload: payload})
	}

	var (
		lastTurnID string
		usage      *codexsdk.Usage
		sawError   bool
	)

	for ev := range events {
		if ev.TurnID != "" {
			lastTurnID = ev.TurnID
		}
		switch ev.Kind {
		case codexsdk.EventText:
			if !emit(providers.ChunkText, map[string]string{"text": ev.Text}) {
				return
			}
		case codexsdk.EventThinking:
			if !emit(providers.ChunkThinking, map[string]string{"text": ev.Text}) {
				return
			}
		case codexsdk.EventUsage:
			u := ev.Usage
			usage = &u
		case codexsdk.EventError:
			// A retryable error never reaches here as terminal; the SDK keeps
			// the turn open. So anything arriving is worth surfacing.
			sawError = true
			if !emit(providers.ChunkError, map[string]string{"message": ev.Err}) {
				return
			}
		case codexsdk.EventDone:
			// nothing to emit; the terminal work happens below
		}
	}

	if sawError {
		// The stream already carried the failure. Emitting a handle for a
		// turn that failed would let the next message fork from a broken
		// point, so stop here and let the supervisor materialize the error.
		return
	}

	// The handle for THIS turn: the thread we just wrote to, at the turn we
	// just produced. Persisting it is what gives the next message its fork
	// point, and what makes editing this message branch exactly here.
	handle := encodeHandle(setup.model, threadID, lastTurnID)
	if !emit(providers.ChunkSessionHandle, map[string]string{"session_id": handle}) {
		return
	}
	if setup.fromHandle != "" {
		// The provisional handle served its purpose.
		d.mu.Lock()
		delete(d.pending, setup.fromHandle)
		d.mu.Unlock()
	}

	if usage != nil {
		if payload := usagePayload(*usage); payload != nil {
			if !sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkUsage, Payload: payload}) {
				return
			}
		}
	}
	sendChunk(ctx, out, providers.Chunk{Type: providers.ChunkDone, Payload: []byte(`{}`)})
}

// usagePayload maps Codex's counts onto the normalized Usage shape.
//
// Codex reports cached input separately from input, and its input count
// INCLUDES the cached portion. Psmith's CacheReadTokens is the same idea, so
// the two line up without adjustment; subtracting would double-count the
// saving the cost engine already computes.
func usagePayload(u codexsdk.Usage) json.RawMessage {
	in := int(u.InputTokens)
	outTok := int(u.OutputTokens)
	cacheRead := int(u.CachedInputTokens)
	reasoning := int(u.ReasoningTokens)

	pu := providers.Usage{
		InputTokens:     &in,
		OutputTokens:    &outTok,
		CacheReadTokens: &cacheRead,
	}
	if reasoning > 0 {
		pu.ReasoningTokens = &reasoning
	}
	raw, _ := json.Marshal(u)
	pu.ProviderRaw = raw
	fr := "end_turn"
	pu.FinishReason = &fr

	payload, err := json.Marshal(pu)
	if err != nil {
		return nil
	}
	return payload
}

// sendChunk delivers a chunk unless the caller has gone away. Returns false
// when the context is done, so the pump stops rather than blocking forever.
func sendChunk(ctx context.Context, out chan<- providers.Chunk, c providers.Chunk) bool {
	select {
	case out <- c:
		return true
	case <-ctx.Done():
		return false
	}
}
