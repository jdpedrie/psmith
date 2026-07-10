package history

import (
	"context"
	"testing"

	"github.com/jdpedrie/psmith/internal/store"
)

// TestBuild_ComposesMessageEnvelope pins the header/trailer contract:
// plugin contributions persisted in message_headers / message_trailers
// join the user's content ONLY at wire-build time, blank-line
// separated, in header → content → trailer order. Content itself
// stays untouched (display, edit, TTS, and embeddings read it bare).
func TestBuild_ComposesMessageEnvelope(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	header := "<grounding>\nCurrent time: 2026-05-02T14:45:00Z\n</grounding>"
	trailer := "[reminder: answer in haiku]"
	m, err := f.q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID:              mustUUID(t),
		ContextID:       f.ctxRow.ID,
		Role:            roleUser,
		Content:         "what's the weather like?",
		MessageHeaders:  &header,
		MessageTrailers: &trailer,
	})
	if err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}
	_ = m

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 1 {
		t.Fatalf("len(wire) = %d, want 1", len(wire))
	}
	want := header + "\n\nwhat's the weather like?\n\n" + trailer
	if wire[0].Content != want {
		t.Errorf("composed wire content:\n  got:  %q\n  want: %q", wire[0].Content, want)
	}
}

// TestBuild_NoEnvelopePassthrough: rows without envelope columns (all
// pre-00041 history plus plain sends) hit the fast path — wire content
// IS the stored content, byte for byte.
func TestBuild_NoEnvelopePassthrough(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	insertMessage(t, f.q, f.ctxRow.ID, nil, roleUser, "plain")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 1 || wire[0].Content != "plain" {
		t.Fatalf("wire = %+v, want single 'plain' message", wire)
	}
}
