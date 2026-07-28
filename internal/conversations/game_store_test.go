package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"reflect"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
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

// TestGameStore_CampaignSurvivesTheTurnBoundary is the seam the unit
// tests cannot reach on their own. Plugin instances are rebuilt on every
// send, so turn two runs against a brand-new object with nothing in
// memory: everything it knows has to come back out of Postgres. This
// drives the real plugin against the real store across that boundary.
func TestGameStore_CampaignSurvivesTheTurnBoundary(t *testing.T) {
	t.Parallel()
	f := newGameStoreFixture(t)
	ctx := context.Background()

	// --- turn 1: a fresh plugin instance starts a campaign ---
	turn1Plugin, err := plugins.Build(plugins.StrategyGameName, nil)
	if err != nil {
		t.Fatalf("build plugin: %v", err)
	}
	tp, ok := turn1Plugin.(plugins.ToolProvider)
	if !ok {
		t.Fatal("strategy_game must provide tools")
	}

	assistant1 := f.addMessage(t, &f.root, "assistant", "The granary stands empty.")
	toolCtx := plugins.WithGameStore(ctx, f.storeAt(f.root))
	toolCtx = plugins.WithCallerInfo(toolCtx, plugins.CallerInfo{
		UserID: f.user.ID, ConversationID: f.conv.ID, ActiveContextID: f.ctxRow.ID,
	})
	if _, err := tp.ExecuteTool(toolCtx, "game_commit_turn", json.RawMessage(openingScenario)); err != nil {
		t.Fatalf("initialize: %v", err)
	}

	// Materialization binds whatever the turn computed to the assistant
	// message — the same loop postMaterialize runs.
	for _, ps := range (plugins.Pipeline{turn1Plugin}).PendingPluginStates() {
		gs := f.svc.newGameStore(ps.PluginName, f.user.ID, f.conv.ID, assistant1)
		if err := gs.Save(ctx, assistant1, ps.State, ps.Version); err != nil {
			t.Fatalf("bind: %v", err)
		}
	}

	// --- turn 2: a NEW instance, no memory of turn 1 ---
	choice := f.addMessage(t, &assistant1, "user", "A")
	turn2Plugin, err := plugins.Build(plugins.StrategyGameName, nil)
	if err != nil {
		t.Fatalf("build plugin: %v", err)
	}
	tp2 := turn2Plugin.(plugins.ToolProvider)
	turn2Ctx := plugins.WithGameStore(ctx, f.storeAt(choice))
	turn2Ctx = plugins.WithCallerInfo(turn2Ctx, plugins.CallerInfo{
		UserID: f.user.ID, ConversationID: f.conv.ID, ActiveContextID: f.ctxRow.ID,
	})

	res, err := tp2.ExecuteTool(turn2Ctx, "game_commit_turn", json.RawMessage(resolveTurn))
	if err != nil {
		t.Fatalf("resolve on a fresh instance: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(res.Output, &out); err != nil {
		t.Fatalf("output: %v", err)
	}
	if out["turn"] != float64(2) {
		t.Errorf("turn 2 should have read turn 1 from the database; got turn %v", out["turn"])
	}
	if out["outcome"] == nil {
		t.Error("resolve should report an outcome band")
	}
}

const openingScenario = `{
  "kind":"initialize",
  "scenario":{
    "title":"The Lean Winter","role":"Margrave","premise":"A border march.",
    "resources":[{"id":"treasury","label":"Treasury","start":60,"min":0,"max":200}],
    "ratings":[{"id":"guile","label":"Guile","start":4,"min":0,"max":10}],
    "loss_when":[{"stat":"treasury","op":"<=","value":0,"label":"Bankrupt"}],
    "turn_limit":12,
    "opening_situation":{"id":"granary","title":"The Empty Granary","body":"Stores were overstated.",
      "choices":[
        {"id":"A","label":"Buy grain","rating":"guile","difficulty":"moderate","stakes":"standard","advances":"guile","costs":"treasury"},
        {"id":"B","label":"Seize it","rating":"guile","difficulty":"hard","stakes":"major","advances":"treasury","costs":"guile"}
      ]}
  }
}`

const resolveTurn = `{
  "kind":"resolve","choice_id":"A",
  "next_situation":{"id":"tithe","title":"The Books","body":"The rolls do not add up.",
    "choices":[
      {"id":"A","label":"Audit quietly","rating":"guile","difficulty":"easy","stakes":"minor","advances":"treasury","costs":"guile"},
      {"id":"B","label":"Make an example","rating":"guile","difficulty":"moderate","stakes":"major","advances":"guile","costs":"treasury"}
    ]}
}`

// TestGameStore_SurvivesCompaction is the gap that made a campaign
// unplayable past its first compaction: the new context is seeded with a
// fresh root, so the message parent chain does not cross the boundary
// and the plugin's ancestor walk comes up empty on the other side. The
// story survived and the numbers vanished.
func TestGameStore_SurvivesCompaction(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	svc := NewService(q, pool, nil, nil, crypto.Nop{}, nil, slog.Default())
	ctx := context.Background()

	user := mustCreateUser(t, q, "compact_"+uuid.NewString()[:8])
	prof := makeProfile(t, q, user.ID, nil, nil, nil)
	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&psmithv1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	convID := uuid.MustParse(resp.Msg.Conversation.Id)
	conv, _ := q.GetConversationByID(ctx, convID)
	srcCtx, _ := q.GetActiveContextByConversation(ctx, convID)

	add := func(parent *uuid.UUID, role, content string) uuid.UUID {
		t.Helper()
		id, _ := uuid.NewV7()
		if _, err := q.CreateMessage(ctx, store.CreateMessageParams{
			ID: id, ContextID: srcCtx.ID, ParentID: parent, Role: role, Content: content,
		}); err != nil {
			t.Fatalf("CreateMessage: %v", err)
		}
		return id
	}

	// A campaign several turns deep on the branch that will be compacted.
	u1 := add(nil, "user", "start")
	a1 := add(&u1, "assistant", "turn 1")
	gs := svc.newGameStore("strategy_game", user.ID, conv.ID, u1)
	if err := gs.Save(ctx, a1, json.RawMessage(`{"treasury":73,"turn":9}`), 9); err != nil {
		t.Fatalf("save: %v", err)
	}

	// A sibling branch the player abandoned, carrying different numbers.
	// The copy must NOT pick this one up just because it is newer.
	abandoned := add(&u1, "assistant", "abandoned branch")
	if err := svc.newGameStore("strategy_game", user.ID, conv.ID, u1).
		Save(ctx, abandoned, json.RawMessage(`{"treasury":5,"turn":99}`), 99); err != nil {
		t.Fatalf("save abandoned: %v", err)
	}

	// Compaction writes its summary parented to the played branch's tip.
	summary := add(&a1, "compression_summary", "The march weathered a hard winter.")

	promoted, err := svc.PromoteCompactionToNewContext(ctxAs(user),
		connect.NewRequest(&psmithv1.PromoteCompactionToNewContextRequest{MessageId: summary.String()}))
	if err != nil {
		t.Fatalf("promote: %v", err)
	}
	newCtxID := uuid.MustParse(promoted.Msg.Context.Id)

	// The new context's seed message must carry the campaign forward.
	rows, err := q.ListPluginStateInContext(ctx, store.ListPluginStateInContextParams{
		PluginName: "strategy_game", ContextID: newCtxID,
	})
	if err != nil {
		t.Fatalf("list new context state: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly one carried snapshot; got %d", len(rows))
	}
	if rows[0].StateVersion != 9 {
		t.Errorf("carried the wrong branch: version %d (99 means it took the abandoned sibling)", rows[0].StateVersion)
	}
	jsonEq(t, json.RawMessage(rows[0].StateJson), `{"treasury":73,"turn":9}`)

	// And a plugin walking up from a new message in the new context finds it.
	firstNewMsg := uuid.UUID{}
	newMsgs, err := q.ListMessagesByContext(ctx, newCtxID)
	if err != nil {
		t.Fatalf("list new messages: %v", err)
	}
	for _, m := range newMsgs {
		if m.Role == roleContext {
			firstNewMsg = m.ID
		}
	}
	if firstNewMsg == (uuid.UUID{}) {
		t.Fatal("new context has no framing message")
	}
	state, version, _, err := svc.newGameStore("strategy_game", user.ID, conv.ID, firstNewMsg).LoadNearest(ctx)
	if err != nil {
		t.Fatalf("load after compaction: %v", err)
	}
	if version != 9 {
		t.Errorf("post-compaction version: got %d want 9", version)
	}
	jsonEq(t, state, `{"treasury":73,"turn":9}`)
}

// TestGameStore_PlaysAFullCampaign drives several turns end to end
// through the real plugin and the real store, crossing a fresh plugin
// instance at every turn boundary the way production does. Unit tests
// cover each link; this is the only thing that proves the chain holds.
func TestGameStore_PlaysAFullCampaign(t *testing.T) {
	t.Parallel()
	f := newGameStoreFixture(t)
	ctx := context.Background()

	// Turn 1: compile the scenario and open a clock.
	leaf := f.root
	assistant := f.addMessage(t, &leaf, "assistant", "turn 1")
	play(t, f, ctx, leaf, assistant, `{
	  "kind":"initialize",
	  "start_clocks":[{"id":"debt","label":"Creditors","length":"medium","weight":"standard","drains":"treasury","strikes":"guile","ominous":true}],
	  "scenario":{
	    "title":"C","role":"Margrave","premise":"p",
	    "resources":[{"id":"treasury","label":"Treasury","start":90,"min":0,"max":200}],
	    "ratings":[{"id":"guile","label":"Guile","start":5,"min":0,"max":10}],
	    "loss_when":[{"stat":"treasury","op":"<=","value":0,"label":"Bankrupt"}],
	    "turn_limit":30,
	    "opening_situation":{"id":"s1","title":"S1","body":"b","choices":[
	      {"id":"A","label":"a","rating":"guile","difficulty":"easy","stakes":"minor","advances":"guile","costs":"treasury"},
	      {"id":"B","label":"b","rating":"guile","difficulty":"hard","stakes":"major","advances":"treasury","costs":"guile"}]}}}`)

	// Turns 2-5: resolve, each on a brand-new plugin instance. Four
	// resolves so the medium clock (4 turns) runs all the way out and the
	// expiry path is exercised, not just the drain.
	for turn := 2; turn <= 5; turn++ {
		leaf = f.addMessage(t, &assistant, "user", "A")
		assistant = f.addMessage(t, &leaf, "assistant", "narration")
		play(t, f, ctx, leaf, assistant, `{
		  "kind":"resolve","choice_id":"A",
		  "next_situation":{"id":"s","title":"S","body":"b","choices":[
		    {"id":"A","label":"a","rating":"guile","difficulty":"easy","stakes":"minor","advances":"guile","costs":"treasury"},
		    {"id":"B","label":"b","rating":"guile","difficulty":"hard","stakes":"major","advances":"treasury","costs":"guile"}]}}`)
	}

	// The campaign advanced, the clock ran down and expired, and the
	// treasury took both the choice costs and the clock's drain.
	state, version, _, err := f.storeAt(assistant).LoadNearest(ctx)
	if err != nil {
		t.Fatalf("final load: %v", err)
	}
	var final struct {
		Meta struct {
			Turn         int   `json:"turn"`
			StateVersion int64 `json:"state_version"`
		} `json:"meta"`
		Public struct {
			Resources map[string]int `json:"resources"`
			History   []struct{}     `json:"history"`
			Clocks    []struct{}     `json:"clocks"`
		} `json:"public"`
	}
	if err := json.Unmarshal(state, &final); err != nil {
		t.Fatalf("decode final state: %v", err)
	}
	// One initialize (turn 1) plus four resolves.
	if final.Meta.Turn != 5 {
		t.Errorf("campaign should be on turn 5; got %d", final.Meta.Turn)
	}
	if version != 5 {
		t.Errorf("state version should track every commit; got %d", version)
	}
	if len(final.Public.History) != 4 {
		t.Errorf("expected four resolved turns in the ledger; got %d", len(final.Public.History))
	}
	if final.Public.Resources["treasury"] >= 90 {
		t.Errorf("four turns of costs and clock drain should have moved the treasury; got %d",
			final.Public.Resources["treasury"])
	}
	if len(final.Public.Clocks) != 0 {
		t.Errorf("a medium clock ticks once per resolve, so four resolves should retire it; %d still running",
			len(final.Public.Clocks))
	}
}

// play runs one turn the way the runtime does: a fresh plugin instance,
// a branch-scoped store, then binding whatever it computed to the
// assistant message.
func play(t *testing.T, f gameStoreFixture, ctx context.Context, leaf, assistant uuid.UUID, input string) {
	t.Helper()
	pl, err := plugins.Build(plugins.StrategyGameName, nil)
	if err != nil {
		t.Fatalf("build plugin: %v", err)
	}
	toolCtx := plugins.WithGameStore(ctx, f.storeAt(leaf))
	toolCtx = plugins.WithCallerInfo(toolCtx, plugins.CallerInfo{
		UserID: f.user.ID, ConversationID: f.conv.ID, ActiveContextID: f.ctxRow.ID,
	})
	if _, err := pl.(plugins.ToolProvider).ExecuteTool(toolCtx, "game_commit_turn", json.RawMessage(input)); err != nil {
		t.Fatalf("commit turn: %v", err)
	}
	for _, ps := range (plugins.Pipeline{pl}).PendingPluginStates() {
		if err := f.svc.newGameStore(ps.PluginName, f.user.ID, f.conv.ID, assistant).
			Save(ctx, assistant, ps.State, ps.Version); err != nil {
			t.Fatalf("bind: %v", err)
		}
	}
}
