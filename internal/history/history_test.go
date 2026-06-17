package history

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/testutil"
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
	// Construct a context whose only message references a parent_id not
	// present in the context. walkParentChain should reject this — the DB
	// schema usually prevents it, but defensive coverage matters.
	convID := mustUUID(t)
	ctxID := mustUUID(t)
	leaf := store.Message{
		ID:        mustUUID(t),
		ContextID: ctxID,
		ParentID:  ptr(mustUUID(t)),
		Role:      roleUser,
		Content:   "orphan",
	}
	fake := &fakeQueries{
		active:   store.Context{ID: ctxID, ConversationID: convID},
		messages: []store.Message{leaf},
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

func (f *fakeQueries) ListMessagesByContext(_ context.Context, _ uuid.UUID) ([]store.Message, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	return f.messages, nil
}

func (f *fakeQueries) ListAttachmentsForMessages(_ context.Context, _ []uuid.UUID) ([]store.ListAttachmentsForMessagesRow, error) {
	// History tests don't exercise attachments — empty result keeps
	// the chain build wire-compatible. The dedicated attachment-flow
	// tests live in service_send_test.go alongside the rest of the
	// SendMessage integration coverage.
	return nil, nil
}
