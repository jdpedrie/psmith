package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
)

// gameStoreFixture stands up a user + conversation and returns the
// context row so tests can hang messages off it directly. Going through
// the queries layer rather than SendMessage keeps these focused on the
// branch semantics rather than the whole send path.
type gameStoreFixture struct {
	svc    *Service
	q      *store.Queries
	user   store.User
	conv   store.Conversation
	ctxRow store.Context
	root   uuid.UUID
}

func newGameStoreFixture(t *testing.T) gameStoreFixture {
	t.Helper()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "gs_"+uuid.NewString()[:8])
	prof := makeProfile(t, q, user.ID, nil, nil, nil)

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&psmithv1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	convID := uuid.MustParse(resp.Msg.Conversation.Id)
	conv, err := q.GetConversationByID(context.Background(), convID)
	if err != nil {
		t.Fatalf("GetConversationByID: %v", err)
	}
	ctxRow, err := q.GetActiveContextByConversation(context.Background(), convID)
	if err != nil {
		t.Fatalf("GetActiveContextByConversation: %v", err)
	}

	f := gameStoreFixture{svc: svc, q: q, user: user, conv: conv, ctxRow: ctxRow}
	f.root = f.addMessage(t, nil, "user", "turn 0")
	return f
}

func (f gameStoreFixture) addMessage(t *testing.T, parent *uuid.UUID, role, content string) uuid.UUID {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	if _, err := f.q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID:        id,
		ContextID: f.ctxRow.ID,
		ParentID:  parent,
		Role:      role,
		Content:   content,
	}); err != nil {
		t.Fatalf("CreateMessage: %v", err)
	}
	return id
}

// jsonEq compares two JSON blobs semantically. Required because JSONB
// round-trips through Postgres normalized — `{"a":1}` comes back as
// `{"a": 1}` — so byte comparison would fail on correct behavior.
func jsonEq(t *testing.T, got json.RawMessage, want string) {
	t.Helper()
	var g, w any
	if err := json.Unmarshal(got, &g); err != nil {
		t.Fatalf("unmarshal got %s: %v", got, err)
	}
	if err := json.Unmarshal([]byte(want), &w); err != nil {
		t.Fatalf("unmarshal want %s: %v", want, err)
	}
	if !reflect.DeepEqual(g, w) {
		t.Errorf("state: got %s want %s", got, want)
	}
}

func (f gameStoreFixture) storeAt(leaf uuid.UUID) plugins.GameStore {
	return f.svc.newGameStore("strategy_game", f.user.ID, f.conv.ID, leaf)
}

// TestGameStore_NoStateIsNotAnError verifies the "new campaign" signal is
// a sentinel rather than a failure, since every first turn hits it.
func TestGameStore_NoStateIsNotAnError(t *testing.T) {
	t.Parallel()
	f := newGameStoreFixture(t)

	_, _, _, err := f.storeAt(f.root).LoadNearest(context.Background())
	if !errors.Is(err, plugins.ErrNoGameState) {
		t.Fatalf("want ErrNoGameState on a fresh branch; got %v", err)
	}
}

// TestGameStore_WalksToNearestAncestor is the core read-path contract: a
// snapshot several messages up the chain is still found, so turns that
// wrote no state (or messages deleted out from under one) don't strand
// the campaign.
func TestGameStore_WalksToNearestAncestor(t *testing.T) {
	t.Parallel()
	f := newGameStoreFixture(t)
	ctx := context.Background()

	a := f.addMessage(t, &f.root, "assistant", "turn 1")
	if err := f.storeAt(f.root).Save(ctx, a, json.RawMessage(`{"turn":1}`), 1); err != nil {
		t.Fatalf("save: %v", err)
	}
	// Two further messages that write no state of their own.
	u2 := f.addMessage(t, &a, "user", "chit chat")
	a2 := f.addMessage(t, &u2, "assistant", "no game move")

	state, version, foundAt, err := f.storeAt(a2).LoadNearest(ctx)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if foundAt != a {
		t.Errorf("expected to find the snapshot on %s; got %s", a, foundAt)
	}
	if version != 1 {
		t.Errorf("version: got %d want 1", version)
	}
	jsonEq(t, state, `{"turn":1}`)
}

// TestGameStore_ForksAreIndependent is the property the whole
// message-keyed design exists for. Two branches off one parent each keep
// their own lineage, and neither sees the other's — this is what makes
// regenerating a turn safe and "what if I'd chosen differently" coherent.
func TestGameStore_ForksAreIndependent(t *testing.T) {
	t.Parallel()
	f := newGameStoreFixture(t)
	ctx := context.Background()

	// Shared history: one committed turn.
	base := f.addMessage(t, &f.root, "assistant", "turn 1")
	if err := f.storeAt(f.root).Save(ctx, base, json.RawMessage(`{"treasury":100}`), 1); err != nil {
		t.Fatalf("save base: %v", err)
	}

	// The player's choice, then two sibling assistant turns off it —
	// the regenerate / alternate-choice shape.
	choice := f.addMessage(t, &base, "user", "I choose B")
	branchA := f.addMessage(t, &choice, "assistant", "outcome A")
	branchB := f.addMessage(t, &choice, "assistant", "outcome B")

	if err := f.storeAt(choice).Save(ctx, branchA, json.RawMessage(`{"treasury":80}`), 2); err != nil {
		t.Fatalf("save A: %v", err)
	}
	if err := f.storeAt(choice).Save(ctx, branchB, json.RawMessage(`{"treasury":140}`), 2); err != nil {
		t.Fatalf("save B: %v", err)
	}

	gotA, _, _, err := f.storeAt(branchA).LoadNearest(ctx)
	if err != nil {
		t.Fatalf("load A: %v", err)
	}
	gotB, _, _, err := f.storeAt(branchB).LoadNearest(ctx)
	if err != nil {
		t.Fatalf("load B: %v", err)
	}
	jsonEq(t, gotA, `{"treasury":80}`)
	jsonEq(t, gotB, `{"treasury":140}`)

	// And the shared ancestor is untouched by either branch.
	gotBase, v, _, err := f.storeAt(base).LoadNearest(ctx)
	if err != nil {
		t.Fatalf("load base: %v", err)
	}
	jsonEq(t, gotBase, `{"treasury":100}`)
	if v != 1 {
		t.Errorf("ancestor version mutated: got %d want 1", v)
	}
}

// TestGameStore_SaveIsIdempotent covers the retried-bind case: the
// assistant row is materialized before the binding hook runs, so a
// re-fired bind must overwrite rather than blow up on the primary key.
func TestGameStore_SaveIsIdempotent(t *testing.T) {
	t.Parallel()
	f := newGameStoreFixture(t)
	ctx := context.Background()

	a := f.addMessage(t, &f.root, "assistant", "turn 1")
	gs := f.storeAt(f.root)
	if err := gs.Save(ctx, a, json.RawMessage(`{"v":1}`), 1); err != nil {
		t.Fatalf("first save: %v", err)
	}
	if err := gs.Save(ctx, a, json.RawMessage(`{"v":2}`), 2); err != nil {
		t.Fatalf("second save: %v", err)
	}
	state, version, _, err := f.storeAt(a).LoadNearest(ctx)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	jsonEq(t, state, `{"v":2}`)
	if version != 2 {
		t.Errorf("re-save should overwrite version; got %d want 2", version)
	}
}

// TestGameStore_RefusesForeignConversation verifies the ownership gate:
// a message in someone else's conversation reads as absent rather than
// as a permission error, so existence doesn't leak.
func TestGameStore_RefusesForeignConversation(t *testing.T) {
	t.Parallel()
	mine := newGameStoreFixture(t)
	ctx := context.Background()

	// A second conversation owned by a different user, sharing nothing.
	theirs := newGameStoreFixture(t)
	foreign := theirs.addMessage(t, &theirs.root, "assistant", "not yours")

	// Writing onto a foreign message must fail.
	if err := mine.storeAt(mine.root).Save(ctx, foreign, json.RawMessage(`{"x":1}`), 1); err == nil {
		t.Error("expected save onto a foreign message to fail")
	}

	// And reading a foreign lineage reads as absent.
	if err := theirs.storeAt(theirs.root).Save(ctx, foreign, json.RawMessage(`{"x":1}`), 1); err != nil {
		t.Fatalf("owner save: %v", err)
	}
	crossReader := mine.svc.newGameStore("strategy_game", mine.user.ID, mine.conv.ID, foreign)
	if _, _, _, err := crossReader.LoadNearest(ctx); !errors.Is(err, plugins.ErrNoGameState) {
		t.Errorf("cross-conversation read should look absent; got %v", err)
	}
}

// TestGameStore_ScopedPerPlugin verifies two stateful plugins in one
// pipeline cannot see each other's rows.
func TestGameStore_ScopedPerPlugin(t *testing.T) {
	t.Parallel()
	f := newGameStoreFixture(t)
	ctx := context.Background()

	a := f.addMessage(t, &f.root, "assistant", "turn 1")
	if err := f.svc.newGameStore("strategy_game", f.user.ID, f.conv.ID, f.root).
		Save(ctx, a, json.RawMessage(`{"game":true}`), 1); err != nil {
		t.Fatalf("save: %v", err)
	}

	other := f.svc.newGameStore("some_other_plugin", f.user.ID, f.conv.ID, a)
	if _, _, _, err := other.LoadNearest(ctx); !errors.Is(err, plugins.ErrNoGameState) {
		t.Errorf("a different plugin must not see the game's rows; got %v", err)
	}
}
