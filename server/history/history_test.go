package history

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"
)

// --- Fixture helpers -------------------------------------------------------

// fixture is a freshly seeded conversation with one active context. Returns
// the conversation, the active context, and the *store.Queries bound to a
// per-test pgtestdb pool.
type fixture struct {
	q       *store.Queries
	user    store.User
	profile store.Profile
	conv    store.Conversation
	ctxRow  store.Context
}

// seedConversation creates the user/profile/conversation/context skeleton
// that every test starts from. It does NOT seed any messages — the caller
// adds those via insertMessage to shape the test tree.
func seedConversation(t *testing.T) *fixture {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()

	user, err := q.CreateUser(ctx, store.CreateUserParams{
		ID:           mustUUID(t),
		Username:     "tester-" + uuid.NewString(),
		PasswordHash: "irrelevant",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	profile, err := q.CreateProfile(ctx, store.CreateProfileParams{
		ID:     mustUUID(t),
		UserID: user.ID,
		Name:   "default",
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	conv, err := q.CreateConversation(ctx, store.CreateConversationParams{
		ID:        mustUUID(t),
		UserID:    user.ID,
		ProfileID: profile.ID,
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}

	ctxRow, err := q.CreateContext(ctx, store.CreateContextParams{
		ID:                    mustUUID(t),
		ConversationID:        conv.ID,
		ContextActivationTime: time.Now(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	return &fixture{q: q, user: user, profile: profile, conv: conv, ctxRow: ctxRow}
}

// insertMessage writes a single message row into the supplied context with
// the given role/content/parent. Returns the created Message for chaining.
func insertMessage(
	t *testing.T,
	q *store.Queries,
	contextID uuid.UUID,
	parentID *uuid.UUID,
	role, content string,
) store.Message {
	t.Helper()
	m, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID:        mustUUID(t),
		ContextID: contextID,
		ParentID:  parentID,
		Role:      role,
		Content:   content,
	})
	if err != nil {
		t.Fatalf("CreateMessage(%s): %v", role, err)
	}
	// Sleep a microsecond between inserts so created_at ordering is stable
	// across rapid sequences in tests that depend on it.
	time.Sleep(time.Microsecond)
	return m
}

// insertAssistantWithThinking writes an assistant message carrying a non-nil
// thinking blob produced by `producer`.
func insertAssistantWithThinking(
	t *testing.T,
	q *store.Queries,
	contextID uuid.UUID,
	parentID *uuid.UUID,
	content string,
	thinking json.RawMessage,
	producer string,
) store.Message {
	t.Helper()
	m, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID:                   mustUUID(t),
		ContextID:            contextID,
		ParentID:             parentID,
		Role:                 roleAssistant,
		Content:              content,
		Thinking:             thinking,
		ThinkingProviderType: &producer,
	})
	if err != nil {
		t.Fatalf("CreateMessage(assistant w/ thinking): %v", err)
	}
	time.Sleep(time.Microsecond)
	return m
}

func mustUUID(t *testing.T) uuid.UUID {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	return id
}

func ptr[T any](v T) *T { return &v }

// --- Tests -----------------------------------------------------------------

func TestBuild_SystemAndUser(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "you are helpful")
	insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, roleUser, "hello")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if got, want := len(wire), 2; got != want {
		t.Fatalf("len(wire) = %d, want %d", got, want)
	}
	if wire[0].Role != "system" || wire[0].Content != "you are helpful" {
		t.Errorf("wire[0] = %+v, want system/you are helpful", wire[0])
	}
	if wire[1].Role != "user" || wire[1].Content != "hello" {
		t.Errorf("wire[1] = %+v, want user/hello", wire[1])
	}
}

func TestBuild_ContextRoleRewrittenToUser(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "sys-msg")
	def := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, roleContext, "default-user-msg")
	insertMessage(t, f.q, f.ctxRow.ID, &def.ID, roleUser, "actual user")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if got, want := len(wire), 3; got != want {
		t.Fatalf("len(wire) = %d, want %d", got, want)
	}

	expectRoles := []string{"system", "user", "user"}
	expectContent := []string{"sys-msg", "default-user-msg", "actual user"}
	for i, w := range wire {
		if w.Role != expectRoles[i] || w.Content != expectContent[i] {
			t.Errorf("wire[%d] = %+v, want role=%s content=%q", i, w, expectRoles[i], expectContent[i])
		}
	}
}

func TestBuild_LinearChain(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "s")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, roleUser, "u1")
	a1 := insertMessage(t, f.q, f.ctxRow.ID, &u1.ID, roleAssistant, "a1")
	u2 := insertMessage(t, f.q, f.ctxRow.ID, &a1.ID, roleUser, "u2")
	insertMessage(t, f.q, f.ctxRow.ID, &u2.ID, roleAssistant, "a2")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	wantRoles := []string{"system", "user", "assistant", "user", "assistant"}
	wantContent := []string{"s", "u1", "a1", "u2", "a2"}
	if got := len(wire); got != len(wantRoles) {
		t.Fatalf("len(wire) = %d, want %d", got, len(wantRoles))
	}
	for i, w := range wire {
		if w.Role != wantRoles[i] || w.Content != wantContent[i] {
			t.Errorf("wire[%d] = %+v, want role=%s content=%q",
				i, w, wantRoles[i], wantContent[i])
		}
	}
}

func TestBuild_ForkingPicksRequestedLeaf(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	root := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "root")
	a := insertMessage(t, f.q, f.ctxRow.ID, &root.ID, roleUser, "a")
	a1 := insertMessage(t, f.q, f.ctxRow.ID, &a.ID, roleAssistant, "a1")
	a2 := insertMessage(t, f.q, f.ctxRow.ID, &a.ID, roleAssistant, "a2")

	t.Run("leaf=A1", func(t *testing.T) {
		t.Parallel()
		wire, err := Build(context.Background(), f.q, Params{
			Conversation:     f.conv,
			LeafMessageID:    &a1.ID,
			DestProviderType: "anthropic",
		})
		if err != nil {
			t.Fatalf("Build: %v", err)
		}
		want := []string{"root", "a", "a1"}
		if len(wire) != len(want) {
			t.Fatalf("len(wire) = %d, want %d", len(wire), len(want))
		}
		for i, w := range wire {
			if w.Content != want[i] {
				t.Errorf("wire[%d].Content = %q, want %q", i, w.Content, want[i])
			}
		}
	})

	t.Run("leaf=A2", func(t *testing.T) {
		t.Parallel()
		wire, err := Build(context.Background(), f.q, Params{
			Conversation:     f.conv,
			LeafMessageID:    &a2.ID,
			DestProviderType: "anthropic",
		})
		if err != nil {
			t.Fatalf("Build: %v", err)
		}
		want := []string{"root", "a", "a2"}
		if len(wire) != len(want) {
			t.Fatalf("len(wire) = %d, want %d", len(wire), len(want))
		}
		for i, w := range wire {
			if w.Content != want[i] {
				t.Errorf("wire[%d].Content = %q, want %q", i, w.Content, want[i])
			}
		}
	})
}

func TestBuild_MultipleLeavesWithoutPinErrors(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	root := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "root")
	a := insertMessage(t, f.q, f.ctxRow.ID, &root.ID, roleUser, "a")
	insertMessage(t, f.q, f.ctxRow.ID, &a.ID, roleAssistant, "a1")
	insertMessage(t, f.q, f.ctxRow.ID, &a.ID, roleAssistant, "a2")

	_, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
	})
	if !errors.Is(err, ErrAmbiguousLeaf) {
		t.Fatalf("err = %v, want ErrAmbiguousLeaf", err)
	}
}

func TestBuild_ThinkingSameProviderIncluded(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	thinking := json.RawMessage(`{"signed_blocks":[{"text":"reasoning"}]}`)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "s")
	u := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, roleUser, "q")
	insertAssistantWithThinking(t, f.q, f.ctxRow.ID, &u.ID, "answer", thinking, "anthropic")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
		IncludeThinking:  true,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	last := wire[len(wire)-1]
	if last.Role != "assistant" {
		t.Fatalf("last role = %q, want assistant", last.Role)
	}
	if last.Thinking == nil {
		t.Fatal("Thinking unexpectedly nil for same-provider send")
	}
	// Postgres JSONB normalises whitespace; compare semantically.
	var got, want any
	if err := json.Unmarshal(last.Thinking, &got); err != nil {
		t.Fatalf("unmarshal got: %v", err)
	}
	if err := json.Unmarshal(thinking, &want); err != nil {
		t.Fatalf("unmarshal want: %v", err)
	}
	gotJSON, _ := json.Marshal(got)
	wantJSON, _ := json.Marshal(want)
	if string(gotJSON) != string(wantJSON) {
		t.Errorf("Thinking = %s, want %s", gotJSON, wantJSON)
	}
}

func TestBuild_ThinkingCrossProviderOmitted(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	thinking := json.RawMessage(`{"signed":"opaque"}`)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "s")
	u := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, roleUser, "q")
	insertAssistantWithThinking(t, f.q, f.ctxRow.ID, &u.ID, "answer", thinking, "anthropic")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "openai-compatible",
		IncludeThinking:  true,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	last := wire[len(wire)-1]
	if last.Thinking != nil {
		t.Errorf("Thinking = %q, want nil for cross-provider send", last.Thinking)
	}
}

func TestBuild_ThinkingDisabledOmittedAlways(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	thinking := json.RawMessage(`{"x":1}`)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "s")
	u := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, roleUser, "q")
	insertAssistantWithThinking(t, f.q, f.ctxRow.ID, &u.ID, "answer", thinking, "anthropic")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
		IncludeThinking:  false,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if wire[len(wire)-1].Thinking != nil {
		t.Errorf("Thinking unexpectedly present when IncludeThinking=false")
	}
}

func TestBuild_EmptyContextReturnsEmptySlice(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		DestProviderType: "anthropic",
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if wire == nil {
		t.Fatal("expected non-nil empty slice")
	}
	if len(wire) != 0 {
		t.Fatalf("len(wire) = %d, want 0", len(wire))
	}
}

func TestBuild_LeafFromDifferentContextErrors(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	// Active context message — this is the one we'd normally pin to.
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, roleSystem, "s")

	// Create a second context that is *older* than the active one, then
	// stuff a message into it. We want the active-context lookup to still
	// resolve to f.ctxRow but the leaf to live in the foreign context.
	older, err := f.q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    mustUUID(t),
		ConversationID:        f.conv.ID,
		ContextActivationTime: f.ctxRow.ContextActivationTime.Add(-time.Hour),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}
	foreign := insertMessage(t, f.q, older.ID, nil, roleSystem, "foreign")

	_ = sys // silence unused warning if test refactored later

	_, err = Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &foreign.ID,
		DestProviderType: "anthropic",
	})
	if !errors.Is(err, ErrLeafNotInActiveContext) {
		t.Fatalf("err = %v, want ErrLeafNotInActiveContext", err)
	}
}

func TestBuild_NoActiveContextErrors(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()

	user, err := q.CreateUser(ctx, store.CreateUserParams{
		ID:           mustUUID(t),
		Username:     "tester-" + uuid.NewString(),
		PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	profile, err := q.CreateProfile(ctx, store.CreateProfileParams{
		ID: mustUUID(t), UserID: user.ID, Name: "p",
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	// Conversation but no contexts attached.
	conv, err := q.CreateConversation(ctx, store.CreateConversationParams{
		ID:        mustUUID(t),
		UserID:    user.ID,
		ProfileID: profile.ID,
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}

	_, err = Build(ctx, q, Params{
		Conversation:     conv,
		DestProviderType: "anthropic",
	})
	if !errors.Is(err, ErrNoActiveContext) {
		t.Fatalf("err = %v, want ErrNoActiveContext", err)
	}
}

func TestBuild_UnknownRoleErrors(t *testing.T) {
	t.Parallel()
	// Pure unit test — no DB needed. Use a fake queries impl that returns
	// a message with an unrecognised role to exercise wireRoleFor's default
	// branch. (DB CHECK constraint prevents this in real data.)
	convID := mustUUID(t)
	ctxID := mustUUID(t)
	msgID := mustUUID(t)
	fake := &fakeQueries{
		active: store.Context{ID: ctxID, ConversationID: convID},
		messages: []store.Message{{
			ID:        msgID,
			ContextID: ctxID,
			Role:      "tool", // not yet wired up
			Content:   "x",
		}},
	}
	_, err := Build(context.Background(), fake, Params{
		Conversation:     store.Conversation{ID: convID},
		DestProviderType: "anthropic",
	})
	if !errors.Is(err, ErrUnknownRole) {
		t.Fatalf("err = %v, want ErrUnknownRole", err)
	}
}

func TestBuild_ListMessagesError(t *testing.T) {
	t.Parallel()
	convID := mustUUID(t)
	fake := &fakeQueries{
		active:  store.Context{ID: mustUUID(t), ConversationID: convID},
		listErr: errors.New("boom"),
	}
	_, err := Build(context.Background(), fake, Params{
		Conversation:     store.Conversation{ID: convID},
		DestProviderType: "anthropic",
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestBuild_BrokenParentChainErrors(t *testing.T) {
	t.Parallel()
	// A leaf in the active context whose parent chain crosses INTO a
	// different context. The recursive chain fetch follows parent_id
	// without regard for context boundaries, so Build must reject any
	// ancestor living outside the active context — the wire prefix
	// would otherwise smuggle in rows the user can't see.
	convID := mustUUID(t)
	ctxID := mustUUID(t)
	foreignCtxID := mustUUID(t)
	parent := store.Message{
		ID:        mustUUID(t),
		ContextID: foreignCtxID,
		Role:      roleSystem,
		Content:   "elsewhere",
	}
	leaf := store.Message{
		ID:        mustUUID(t),
		ContextID: ctxID,
		ParentID:  &parent.ID,
		Role:      roleUser,
		Content:   "orphan",
	}
	fake := &fakeQueries{
		active:   store.Context{ID: ctxID, ConversationID: convID},
		messages: []store.Message{parent, leaf},
	}
	_, err := Build(context.Background(), fake, Params{
		Conversation:     store.Conversation{ID: convID},
		LeafMessageID:    &leaf.ID,
		DestProviderType: "anthropic",
	})
	if !errors.Is(err, ErrBrokenParentChain) {
		t.Fatalf("err = %v, want ErrBrokenParentChain", err)
	}
}

// --- fake queries impl ----------------------------------------------------

type fakeQueries struct {
	active    store.Context
	activeErr error
	messages  []store.Message
	listErr   error
}

func (f *fakeQueries) GetActiveContextByConversation(_ context.Context, _ uuid.UUID) (store.Context, error) {
	if f.activeErr != nil {
		return store.Context{}, f.activeErr
	}
	return f.active, nil
}

// ListContextLeafIDs mirrors the real query: childless message ids in
// the given context, capped at 2.
func (f *fakeQueries) ListContextLeafIDs(_ context.Context, contextID uuid.UUID) ([]uuid.UUID, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	hasChild := make(map[uuid.UUID]bool, len(f.messages))
	for _, m := range f.messages {
		if m.ParentID != nil {
			hasChild[*m.ParentID] = true
		}
	}
	var out []uuid.UUID
	for _, m := range f.messages {
		if m.ContextID == contextID && !hasChild[m.ID] {
			out = append(out, m.ID)
			if len(out) == 2 {
				break
			}
		}
	}
	return out, nil
}

// ListMessageChainForHistory mirrors the real recursive CTE: walk
// parent_id from the leaf across ALL stored messages (context
// boundaries included — Build owns that validation), return root-first,
// stop when a parent id doesn't resolve (impossible against the real
// DB thanks to the FK, but fakes can be sparse).
func (f *fakeQueries) ListMessageChainForHistory(_ context.Context, id uuid.UUID) ([]store.ListMessageChainForHistoryRow, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	byID := make(map[uuid.UUID]store.Message, len(f.messages))
	for _, m := range f.messages {
		byID[m.ID] = m
	}
	var leafFirst []store.Message
	cur, ok := byID[id]
	for ok {
		leafFirst = append(leafFirst, cur)
		if cur.ParentID == nil {
			break
		}
		cur, ok = byID[*cur.ParentID]
	}
	out := make([]store.ListMessageChainForHistoryRow, 0, len(leafFirst))
	for i := len(leafFirst) - 1; i >= 0; i-- {
		out = append(out, store.ListMessageChainForHistoryRow{Message: leafFirst[i]})
	}
	return out, nil
}

func (f *fakeQueries) ListAttachmentsForMessages(_ context.Context, _ []uuid.UUID) ([]store.ListAttachmentsForMessagesRow, error) {
	// History tests don't exercise attachments — empty result keeps
	// the chain build wire-compatible. The dedicated attachment-flow
	// tests live in service_send_test.go alongside the rest of the
	// SendMessage integration coverage.
	return nil, nil
}

// stubInjector contributes a fixed block and records what it was told
// about the turn.
type stubInjector struct {
	block   string
	sawTurn pluginapi.TurnInfo
}

func (s *stubInjector) Name() string        { return "stub_injector" }
func (s *stubInjector) DisplayName() string { return "Stub" }
func (s *stubInjector) Description() string { return "test" }
func (s *stubInjector) BuildTurnContext(_ context.Context, t pluginapi.TurnInfo) (string, error) {
	s.sawTurn = t
	return s.block, nil
}

// TestBuild_TurnContextLandsOnTheHead pins the placement that makes
// per-turn state affordable. Anthropic's cache breakpoint sits at the end
// of the last assistant turn, so a block that changes every turn has to
// land AFTER it — in the head message. In the system slot it would
// invalidate the entire cached prefix on every send, which on a long
// conversation means re-reading the whole transcript at full price on
// every turn.
func TestBuild_TurnContextLandsOnTheHead(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "You are helpful.")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "user", "first question")
	a1 := insertMessage(t, f.q, f.ctxRow.ID, &u1.ID, "assistant", "first answer")
	head := insertMessage(t, f.q, f.ctxRow.ID, &a1.ID, "user", "second question")

	inj := &stubInjector{block: "<game_state>treasury 73</game_state>"}
	out, err := Build(context.Background(), f.q, Params{
		Conversation:  f.conv,
		LeafMessageID: &head.ID,
		UserID:        f.user.ID,
		Plugins:       pluginapi.Pipeline{inj},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if len(out) == 0 {
		t.Fatal("empty prefix")
	}

	last := out[len(out)-1]
	if !strings.Contains(last.Content, "treasury 73") {
		t.Errorf("turn context should be on the head message; head=%q", last.Content)
	}
	if !strings.Contains(last.Content, "second question") {
		t.Error("the user's own text must survive alongside the injected block")
	}
	for i, m := range out[:len(out)-1] {
		if strings.Contains(m.Content, "treasury 73") {
			t.Errorf("turn context leaked into message %d (role %s) — that is before the cache breakpoint", i, m.Role)
		}
	}
	if inj.sawTurn.LeafMessageID != head.ID {
		t.Errorf("injector got leaf %s, want %s", inj.sawTurn.LeafMessageID, head.ID)
	}
	if inj.sawTurn.ConversationID != f.conv.ID {
		t.Error("injector did not receive the conversation id")
	}
}

// TestBuild_TurnContextIsNotPersisted verifies the block is rebuilt per
// send rather than stored. Written through MessageEnvelope it would be
// saved beside the user's content and recomposed into every later prefix,
// accumulating one stale copy per turn for the life of the conversation.
func TestBuild_TurnContextIsNotPersisted(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	u1 := insertMessage(t, f.q, f.ctxRow.ID, nil, "user", "hello")

	inj := &stubInjector{block: "<game_state>turn 1</game_state>"}
	if _, err := Build(context.Background(), f.q, Params{
		Conversation:  f.conv,
		LeafMessageID: &u1.ID,
		UserID:        f.user.ID,
		Plugins:       pluginapi.Pipeline{inj},
	}); err != nil {
		t.Fatalf("build: %v", err)
	}

	row, err := f.q.GetMessageByID(context.Background(), u1.ID)
	if err != nil {
		t.Fatalf("reload message: %v", err)
	}
	if strings.Contains(row.Content, "game_state") {
		t.Error("turn context was written to the stored message; it must be ephemeral")
	}
	if row.MessageHeaders != nil && strings.Contains(*row.MessageHeaders, "game_state") {
		t.Error("turn context leaked into message_headers; it would replay into every future prefix")
	}

	// A second build with different state must not stack.
	inj.block = "<game_state>turn 2</game_state>"
	out, err := Build(context.Background(), f.q, Params{
		Conversation:  f.conv,
		LeafMessageID: &u1.ID,
		UserID:        f.user.ID,
		Plugins:       pluginapi.Pipeline{inj},
	})
	if err != nil {
		t.Fatalf("second build: %v", err)
	}
	head := out[len(out)-1].Content
	if strings.Contains(head, "turn 1") {
		t.Error("a stale block from the previous build survived into this one")
	}
	if !strings.Contains(head, "turn 2") {
		t.Error("the current block is missing")
	}
}
