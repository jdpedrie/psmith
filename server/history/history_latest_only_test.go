package history

import (
	"context"
	"testing"

	"time"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/store"
)

// A harness holds the transcript, so the prefix is one message: the newest
// one. The system row goes with it, because a harness pins its system prompt
// when the session opens rather than accepting one per turn.
func TestBuild_LatestOnly_SendsOnlyTheLeaf(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "you are helpful")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "user", "first")
	a1 := insertMessage(t, f.q, f.ctxRow.ID, &u1.ID, "assistant", "first reply")
	u2 := insertMessage(t, f.q, f.ctxRow.ID, &a1.ID, "user", "second")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &u2.ID,
		DestProviderType: "claude-code",
		LatestOnly:       true,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 1 {
		t.Fatalf("len = %d want 1; the harness already has everything above the leaf", len(wire))
	}
	if wire[0].Role != "user" || wire[0].Content != "second" {
		t.Errorf("wire[0] = %s/%q, want user/%q", wire[0].Role, wire[0].Content, "second")
	}
}

// The walk is not skipped just because the result is discarded: it is what
// proves the leaf is reachable and inside the active context. A leaf from
// another context must still be refused.
func TestBuild_LatestOnly_StillValidatesTheLeaf(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	other, err := f.q.CreateContext(context.Background(), store.CreateContextParams{
		ID:             mustUUID(t),
		ConversationID: f.conv.ID,
		// Activated earlier so the fixture's context stays the active one:
		// the point is a leaf the walk can reach but must refuse.
		ContextActivationTime: time.Now().Add(-time.Hour),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}
	stray := insertMessage(t, f.q, other.ID, nil, "user", "not in the active context")

	_, err = Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &stray.ID,
		DestProviderType: "claude-code",
		LatestOnly:       true,
	})
	if err == nil {
		t.Fatal("Build accepted a leaf outside the active context")
	}
}

// SystemPrompter contributions are dropped: they would arrive as a per-turn
// system message the harness has no slot for. TurnContextInjector blocks still
// land on the outgoing message, which is the one thing that does travel.
func TestBuild_LatestOnly_DropsSystemKeepsTurnContext(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "you are helpful")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "user", "hello")

	pipeline := pluginapi.Pipeline{
		&prependSysPlugin{pre: "PREPENDED", post: "APPENDED"},
		&turnContextPlugin{block: "TURNCTX"},
	}
	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &u1.ID,
		DestProviderType: "claude-code",
		LatestOnly:       true,
		Plugins:          pipeline,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 1 {
		t.Fatalf("len = %d want 1", len(wire))
	}
	if wire[0].Role == "system" {
		t.Fatal("a system message reached the wire; the harness pins its own at session start")
	}
	if got := wire[0].Content; got != "TURNCTX\n\nhello" {
		t.Errorf("content = %q, want the turn-context block ahead of the message", got)
	}
}

type turnContextPlugin struct{ block string }

func (p *turnContextPlugin) Name() string        { return "test-turnctx" }
func (p *turnContextPlugin) DisplayName() string { return "Test TurnCtx" }
func (p *turnContextPlugin) Description() string { return "test" }
func (p *turnContextPlugin) BuildTurnContext(_ context.Context, _ pluginapi.TurnInfo) (string, error) {
	return p.block, nil
}
