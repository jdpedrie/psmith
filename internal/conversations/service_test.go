package conversations

import (
	"context"
	"errors"
	"strconv"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// numericValue is a small test helper for building pgtype.Numeric from a float
// — mirrors the production conversion in stream/consume.go's floatToNumeric
// (string round-trip) but lives in the test file to avoid coupling tests to
// internal package helpers.
func numericValue(t *testing.T, v float64) pgtype.Numeric {
	t.Helper()
	var n pgtype.Numeric
	if err := n.Scan(strconv.FormatFloat(v, 'f', 6, 64)); err != nil {
		t.Fatalf("numeric scan %f: %v", v, err)
	}
	return n
}

// --- helpers ---

func newTestSvc(t *testing.T) (*Service, *store.Queries) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	return NewService(q, nil, nil, nil, crypto.Nop{}, nil), q
}

func mustCreateUser(t *testing.T, q *store.Queries, username string) store.User {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	u, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID:           id,
		Username:     username,
		PasswordHash: "x",
		IsAdmin:      false,
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return u
}

func ctxAs(u store.User) context.Context {
	return auth.ContextWithUser(context.Background(), auth.User{
		ID:          u.ID,
		Username:    u.Username,
		DisplayName: u.DisplayName,
		IsAdmin:     u.IsAdmin,
		CreatedAt:   u.CreatedAt,
		UpdatedAt:   u.UpdatedAt,
	})
}

// makeProfile inserts a profile directly via the queries layer; bypassing the
// profiles service keeps these tests focused on conversations behavior.
func makeProfile(t *testing.T, q *store.Queries, userID uuid.UUID, sysMsg, userMsg *string, parent *uuid.UUID) store.Profile {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	p, err := q.CreateProfile(context.Background(), store.CreateProfileParams{
		ID:                 id,
		UserID:             userID,
		ParentProfileID:    parent,
		Name:               "p-" + id.String()[:8],
		SystemMessage:      sysMsg,
		DefaultUserMessage: userMsg,
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return p
}

func strPtr(s string) *string { return &s }

func assertCode(t *testing.T, err error, want connect.Code) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error with code %v, got nil", want)
	}
	var ce *connect.Error
	if !errors.As(err, &ce) {
		t.Fatalf("expected *connect.Error, got %T (%v)", err, err)
	}
	if ce.Code() != want {
		t.Errorf("got code %v want %v (%v)", ce.Code(), want, err)
	}
}

// --- CreateConversation ---

func TestService_CreateConversation_BothSeedMessages(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, user.ID, strPtr("system-text"), strPtr("default-user-text"), nil)

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
		Title:     strPtr("hello world"),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if resp.Msg.Conversation.OwnerUserId != user.ID.String() {
		t.Errorf("owner: %q vs %s", resp.Msg.Conversation.OwnerUserId, user.ID)
	}
	if resp.Msg.Conversation.ProfileId != prof.ID.String() {
		t.Errorf("profile_id: %q", resp.Msg.Conversation.ProfileId)
	}
	if resp.Msg.Conversation.Title == nil || *resp.Msg.Conversation.Title != "hello world" {
		t.Errorf("title: %+v", resp.Msg.Conversation.Title)
	}
	if resp.Msg.InitialContext == nil {
		t.Fatal("initial_context nil")
	}
	if resp.Msg.InitialContext.ConversationId != resp.Msg.Conversation.Id {
		t.Errorf("context conversation id mismatch")
	}
	if resp.Msg.Conversation.ActiveContextId != resp.Msg.InitialContext.Id {
		t.Errorf("active_context_id should match initial: %s vs %s", resp.Msg.Conversation.ActiveContextId, resp.Msg.InitialContext.Id)
	}
	if len(resp.Msg.SeedMessages) != 2 {
		t.Fatalf("seeds: got %d want 2", len(resp.Msg.SeedMessages))
	}
	sys := resp.Msg.SeedMessages[0]
	usr := resp.Msg.SeedMessages[1]
	if sys.Role != reevev1.MessageRole_MESSAGE_ROLE_SYSTEM {
		t.Errorf("sys role: %v", sys.Role)
	}
	if sys.Content != "system-text" {
		t.Errorf("sys content: %q", sys.Content)
	}
	if sys.ParentId != nil {
		t.Errorf("sys parent should be nil: %+v", sys.ParentId)
	}
	if usr.Role != reevev1.MessageRole_MESSAGE_ROLE_CONTEXT {
		t.Errorf("user-msg role: %v", usr.Role)
	}
	if usr.Content != "default-user-text" {
		t.Errorf("user-msg content: %q", usr.Content)
	}
	if usr.ParentId == nil || *usr.ParentId != sys.Id {
		t.Errorf("user-msg parent should chain off system: %+v", usr.ParentId)
	}
}

func TestService_CreateConversation_SystemOnly(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, user.ID, strPtr("system-only"), nil, nil)

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if len(resp.Msg.SeedMessages) != 1 {
		t.Fatalf("seeds: got %d want 1", len(resp.Msg.SeedMessages))
	}
	if resp.Msg.SeedMessages[0].Role != reevev1.MessageRole_MESSAGE_ROLE_SYSTEM {
		t.Errorf("role: %v", resp.Msg.SeedMessages[0].Role)
	}
}

func TestService_CreateConversation_NoSeedMessages(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, user.ID, nil, nil, nil)

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if len(resp.Msg.SeedMessages) != 0 {
		t.Fatalf("seeds: got %d want 0", len(resp.Msg.SeedMessages))
	}
	// Initial context still created.
	if resp.Msg.InitialContext == nil {
		t.Fatal("initial_context nil")
	}
}

func TestService_CreateConversation_DefaultUserMessageWithoutSystem(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, user.ID, nil, strPtr("only-user"), nil)

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if len(resp.Msg.SeedMessages) != 1 {
		t.Fatalf("seeds: got %d want 1", len(resp.Msg.SeedMessages))
	}
	m := resp.Msg.SeedMessages[0]
	if m.Role != reevev1.MessageRole_MESSAGE_ROLE_CONTEXT {
		t.Errorf("role: %v", m.Role)
	}
	if m.ParentId != nil {
		t.Errorf("parent should be nil when no system message present: %+v", m.ParentId)
	}
}

func TestService_CreateConversation_ProfileInheritance(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	parent := makeProfile(t, q, user.ID, strPtr("parent-system"), nil, nil)
	// Child overrides nothing — should inherit parent's system_message.
	child := makeProfile(t, q, user.ID, nil, strPtr("child-default-user"), &parent.ID)

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: child.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if len(resp.Msg.SeedMessages) != 2 {
		t.Fatalf("seeds: got %d want 2", len(resp.Msg.SeedMessages))
	}
	sys := resp.Msg.SeedMessages[0]
	if sys.Content != "parent-system" {
		t.Errorf("inherited system content: %q", sys.Content)
	}
}

func TestService_CreateConversation_ChildOverridesParent(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	parent := makeProfile(t, q, user.ID, strPtr("parent-system"), nil, nil)
	child := makeProfile(t, q, user.ID, strPtr("child-system"), nil, &parent.ID)

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: child.ID.String(),
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if len(resp.Msg.SeedMessages) != 1 {
		t.Fatalf("seeds: got %d", len(resp.Msg.SeedMessages))
	}
	if resp.Msg.SeedMessages[0].Content != "child-system" {
		t.Errorf("expected child override: %q", resp.Msg.SeedMessages[0].Content)
	}
}

func TestService_CreateConversation_OtherUserProfile(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	bobProf := makeProfile(t, q, bob.ID, nil, nil, nil)

	_, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: bobProf.ID.String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_CreateConversation_ProfileNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	_, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: uuid.New().String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_CreateConversation_InvalidProfileID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	_, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_CreateConversation_WithSettings(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, user.ID, nil, nil, nil)
	include := true

	resp, err := svc.CreateConversation(ctxAs(user), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
		Settings: &reevev1.ConversationSettings{
			DefaultModelId:           strPtr("gpt-x"),
			IncludeThinkingInHistory: &include,
		},
	}))
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if resp.Msg.Conversation.Settings == nil {
		t.Fatal("settings nil")
	}
	if resp.Msg.Conversation.Settings.DefaultModelId == nil || *resp.Msg.Conversation.Settings.DefaultModelId != "gpt-x" {
		t.Errorf("default_model_id: %+v", resp.Msg.Conversation.Settings.DefaultModelId)
	}
	if resp.Msg.Conversation.Settings.IncludeThinkingInHistory == nil || !*resp.Msg.Conversation.Settings.IncludeThinkingInHistory {
		t.Errorf("include_thinking_in_history: %+v", resp.Msg.Conversation.Settings.IncludeThinkingInHistory)
	}
}

// --- ListConversations ---

func TestService_ListConversations_PerUser(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	aProf := makeProfile(t, q, alice.ID, nil, nil, nil)
	bProf := makeProfile(t, q, bob.ID, nil, nil, nil)

	for i := 0; i < 3; i++ {
		if _, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
			ProfileId: aProf.ID.String(),
		})); err != nil {
			t.Fatalf("seed alice: %v", err)
		}
	}
	if _, err := svc.CreateConversation(ctxAs(bob), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: bProf.ID.String(),
	})); err != nil {
		t.Fatalf("seed bob: %v", err)
	}

	aResp, err := svc.ListConversations(ctxAs(alice), connect.NewRequest(&reevev1.ListConversationsRequest{}))
	if err != nil {
		t.Fatalf("ListConversations alice: %v", err)
	}
	if len(aResp.Msg.Conversations) != 3 {
		t.Errorf("alice: got %d want 3", len(aResp.Msg.Conversations))
	}
	for _, c := range aResp.Msg.Conversations {
		if c.OwnerUserId != alice.ID.String() {
			t.Errorf("leaked conversation: %s", c.OwnerUserId)
		}
	}

	bResp, err := svc.ListConversations(ctxAs(bob), connect.NewRequest(&reevev1.ListConversationsRequest{}))
	if err != nil {
		t.Fatalf("ListConversations bob: %v", err)
	}
	if len(bResp.Msg.Conversations) != 1 {
		t.Errorf("bob: got %d want 1", len(bResp.Msg.Conversations))
	}
}

func TestService_ListConversations_PageSizeCap(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	for i := 0; i < 5; i++ {
		if _, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
			ProfileId: prof.ID.String(),
		})); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	resp, err := svc.ListConversations(ctxAs(alice), connect.NewRequest(&reevev1.ListConversationsRequest{
		PageSize: 2,
	}))
	if err != nil {
		t.Fatalf("ListConversations: %v", err)
	}
	if len(resp.Msg.Conversations) != 2 {
		t.Errorf("expected 2 with page_size=2, got %d", len(resp.Msg.Conversations))
	}
}

// --- GetConversation ---

func TestService_GetConversation_ReturnsActiveContext(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	resp, err := svc.GetConversation(ctxAs(alice), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: created.Msg.Conversation.Id,
	}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if resp.Msg.ActiveContext == nil {
		t.Fatal("active_context nil")
	}
	if resp.Msg.ActiveContext.Id != created.Msg.InitialContext.Id {
		t.Errorf("active context: %s want %s", resp.Msg.ActiveContext.Id, created.Msg.InitialContext.Id)
	}
}

func TestService_GetConversation_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err = svc.GetConversation(ctxAs(bob), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: created.Msg.Conversation.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_GetConversation_NotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.GetConversation(ctxAs(alice), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: uuid.New().String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_GetConversation_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.GetConversation(ctxAs(alice), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- UpdateConversation ---

func TestService_UpdateConversation_TitleAndSettings(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	include := true
	resp, err := svc.UpdateConversation(ctxAs(alice), connect.NewRequest(&reevev1.UpdateConversationRequest{
		Id:    created.Msg.Conversation.Id,
		Title: strPtr("renamed"),
		Settings: &reevev1.ConversationSettings{
			IncludeThinkingInHistory: &include,
		},
	}))
	if err != nil {
		t.Fatalf("UpdateConversation: %v", err)
	}
	if resp.Msg.Conversation.Title == nil || *resp.Msg.Conversation.Title != "renamed" {
		t.Errorf("title: %+v", resp.Msg.Conversation.Title)
	}
	if resp.Msg.Conversation.Settings == nil || resp.Msg.Conversation.Settings.IncludeThinkingInHistory == nil ||
		!*resp.Msg.Conversation.Settings.IncludeThinkingInHistory {
		t.Errorf("settings: %+v", resp.Msg.Conversation.Settings)
	}
}

func TestService_UpdateConversation_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err = svc.UpdateConversation(ctxAs(bob), connect.NewRequest(&reevev1.UpdateConversationRequest{
		Id:    created.Msg.Conversation.Id,
		Title: strPtr("hijack"),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_UpdateConversation_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.UpdateConversation(ctxAs(alice), connect.NewRequest(&reevev1.UpdateConversationRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- DeleteConversation ---

func TestService_DeleteConversation_Success(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, strPtr("sys"), nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := svc.DeleteConversation(ctxAs(alice), connect.NewRequest(&reevev1.DeleteConversationRequest{
		Id: created.Msg.Conversation.Id,
	})); err != nil {
		t.Fatalf("DeleteConversation: %v", err)
	}
	// Verify cascade: subsequent get returns NotFound.
	_, err = svc.GetConversation(ctxAs(alice), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: created.Msg.Conversation.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_DeleteConversation_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err = svc.DeleteConversation(ctxAs(bob), connect.NewRequest(&reevev1.DeleteConversationRequest{
		Id: created.Msg.Conversation.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_DeleteConversation_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.DeleteConversation(ctxAs(alice), connect.NewRequest(&reevev1.DeleteConversationRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ListContexts ---

func TestService_ListContexts_AllForConversation(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	convoUUID, _ := uuid.Parse(created.Msg.Conversation.Id)
	// Insert a second context directly to verify ordering.
	id2, _ := uuid.NewV7()
	_, err = q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    id2,
		ConversationID:        convoUUID,
		ParentContextID:       nil,
		ContextActivationTime: time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("seed second context: %v", err)
	}

	resp, err := svc.ListContexts(ctxAs(alice), connect.NewRequest(&reevev1.ListContextsRequest{
		ConversationId: created.Msg.Conversation.Id,
	}))
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	if len(resp.Msg.Contexts) != 2 {
		t.Fatalf("contexts: got %d want 2", len(resp.Msg.Contexts))
	}
	// Sorted by activation_time DESC: the future-dated one comes first.
	if resp.Msg.Contexts[0].Id != id2.String() {
		t.Errorf("ordering: first is %s want %s", resp.Msg.Contexts[0].Id, id2)
	}
}

// Aggregated message counts are exposed via ListContexts so the client can
// render context-list rows without N+1 round trips.
func TestService_ListContexts_MessageCount(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	convoUUID, _ := uuid.Parse(created.Msg.Conversation.Id)
	ctx1UUID, _ := uuid.Parse(created.Msg.InitialContext.Id)

	// Two messages in context 1.
	for range 2 {
		mid, _ := uuid.NewV7()
		if _, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
			ID:        mid,
			ContextID: ctx1UUID,
			Role:      "user",
			Content:   "hello",
		}); err != nil {
			t.Fatalf("seed message: %v", err)
		}
	}

	// Empty second context.
	ctx2UUID, _ := uuid.NewV7()
	if _, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    ctx2UUID,
		ConversationID:        convoUUID,
		ContextActivationTime: time.Now().UTC().Add(time.Hour),
	}); err != nil {
		t.Fatalf("seed second context: %v", err)
	}

	resp, err := svc.ListContexts(ctxAs(alice), connect.NewRequest(&reevev1.ListContextsRequest{
		ConversationId: created.Msg.Conversation.Id,
	}))
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	if len(resp.Msg.Contexts) != 2 {
		t.Fatalf("contexts: got %d want 2", len(resp.Msg.Contexts))
	}

	byID := map[string]*reevev1.Context{}
	for _, c := range resp.Msg.Contexts {
		byID[c.Id] = c
	}
	if got := byID[ctx1UUID.String()].MessageCount; got != 2 {
		t.Errorf("ctx1 message_count: got %d want 2", got)
	}
	if got := byID[ctx2UUID.String()].MessageCount; got != 0 {
		t.Errorf("ctx2 message_count: got %d want 0", got)
	}
}

// Per-context aggregates last_message_total_tokens and cumulative_cost_usd
// are exposed via ListContexts so the client can render context-list rows
// without N+1 round trips. Empty contexts (no assistant message with usage)
// must yield zero on both fields. Contexts with multiple assistant messages
// must report the LAST assistant's input+output tokens and the SUM of every
// row's total_cost_usd (ignoring NULL costs).
func TestService_ListContexts_TokenAndCostAggregates(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	convoUUID, _ := uuid.Parse(created.Msg.Conversation.Id)
	ctx1UUID, _ := uuid.Parse(created.Msg.InitialContext.Id)

	// Context 1: one user msg (no usage), two assistant msgs (with usage).
	// Cost expectation: 0.001 + 0.002 = 0.003.
	// Last-message-tokens expectation: assistant #2 (the most recent) → 30 + 7 = 37.
	uID, _ := uuid.NewV7()
	if _, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID:        uID,
		ContextID: ctx1UUID,
		Role:      "user",
		Content:   "hi",
	}); err != nil {
		t.Fatalf("user msg: %v", err)
	}

	in1, out1 := int32(20), int32(5)
	a1ID, _ := uuid.NewV7()
	if _, err := q.CreateAssistantMessageWithUsage(context.Background(), store.CreateAssistantMessageWithUsageParams{
		ID:           a1ID,
		ContextID:    ctx1UUID,
		ParentID:     &uID,
		Role:         "assistant",
		Content:      "first",
		InputTokens:  &in1,
		OutputTokens: &out1,
		TotalCostUsd: numericValue(t, 0.001),
	}); err != nil {
		t.Fatalf("assistant 1: %v", err)
	}

	// Pause briefly so created_at differs (UUIDv7 already encodes time, but
	// the SQL ordering goes by created_at column — ensure monotonic separation
	// rather than relying on same-microsecond rows).
	time.Sleep(10 * time.Millisecond)

	in2, out2 := int32(30), int32(7)
	a2ID, _ := uuid.NewV7()
	if _, err := q.CreateAssistantMessageWithUsage(context.Background(), store.CreateAssistantMessageWithUsageParams{
		ID:           a2ID,
		ContextID:    ctx1UUID,
		ParentID:     &a1ID,
		Role:         "assistant",
		Content:      "second",
		InputTokens:  &in2,
		OutputTokens: &out2,
		TotalCostUsd: numericValue(t, 0.002),
	}); err != nil {
		t.Fatalf("assistant 2: %v", err)
	}

	// Context 2: empty (no messages at all). Must yield zero on both fields.
	ctx2UUID, _ := uuid.NewV7()
	if _, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    ctx2UUID,
		ConversationID:        convoUUID,
		ContextActivationTime: time.Now().UTC().Add(time.Hour),
	}); err != nil {
		t.Fatalf("ctx2: %v", err)
	}

	// Context 3: one assistant message but with NULL usage columns. Must yield
	// zero on last-message-tokens (the SQL only counts rows with non-null
	// input_tokens or output_tokens) and zero on cost (NULL total_cost_usd
	// summed via COALESCE/SUM).
	ctx3UUID, _ := uuid.NewV7()
	if _, err := q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    ctx3UUID,
		ConversationID:        convoUUID,
		ContextActivationTime: time.Now().UTC().Add(2 * time.Hour),
	}); err != nil {
		t.Fatalf("ctx3: %v", err)
	}
	a3ID, _ := uuid.NewV7()
	if _, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID:        a3ID,
		ContextID: ctx3UUID,
		Role:      "assistant",
		Content:   "no usage",
	}); err != nil {
		t.Fatalf("assistant no usage: %v", err)
	}

	resp, err := svc.ListContexts(ctxAs(alice), connect.NewRequest(&reevev1.ListContextsRequest{
		ConversationId: created.Msg.Conversation.Id,
	}))
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	if len(resp.Msg.Contexts) != 3 {
		t.Fatalf("contexts: got %d want 3", len(resp.Msg.Contexts))
	}

	byID := map[string]*reevev1.Context{}
	for _, c := range resp.Msg.Contexts {
		byID[c.Id] = c
	}

	// Context 1 — populated.
	c1 := byID[ctx1UUID.String()]
	if got := c1.LastMessageTotalTokens; got != 37 {
		t.Errorf("ctx1 last_message_total_tokens: got %d want 37", got)
	}
	const epsilon = 1e-9
	if got := c1.CumulativeCostUsd; got < 0.003-epsilon || got > 0.003+epsilon {
		t.Errorf("ctx1 cumulative_cost_usd: got %f want ~0.003", got)
	}

	// Context 2 — empty.
	c2 := byID[ctx2UUID.String()]
	if got := c2.LastMessageTotalTokens; got != 0 {
		t.Errorf("ctx2 last_message_total_tokens: got %d want 0", got)
	}
	if got := c2.CumulativeCostUsd; got != 0 {
		t.Errorf("ctx2 cumulative_cost_usd: got %f want 0", got)
	}

	// Context 3 — assistant with NULL usage.
	c3 := byID[ctx3UUID.String()]
	if got := c3.LastMessageTotalTokens; got != 0 {
		t.Errorf("ctx3 last_message_total_tokens: got %d want 0 (no usage data)", got)
	}
	if got := c3.CumulativeCostUsd; got != 0 {
		t.Errorf("ctx3 cumulative_cost_usd: got %f want 0", got)
	}
}

func TestService_ListContexts_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err = svc.ListContexts(ctxAs(bob), connect.NewRequest(&reevev1.ListContextsRequest{
		ConversationId: created.Msg.Conversation.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_ListContexts_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.ListContexts(ctxAs(alice), connect.NewRequest(&reevev1.ListContextsRequest{
		ConversationId: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ActivateContext ---

func TestService_ActivateContext_FlipsActive(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	convoUUID, _ := uuid.Parse(created.Msg.Conversation.Id)

	// Insert an older context.
	olderID, _ := uuid.NewV7()
	_, err = q.CreateContext(context.Background(), store.CreateContextParams{
		ID:                    olderID,
		ConversationID:        convoUUID,
		ParentContextID:       nil,
		ContextActivationTime: time.Now().UTC().Add(-time.Hour),
	})
	if err != nil {
		t.Fatalf("seed older context: %v", err)
	}

	// Confirm initial active is the one created with the conversation.
	getResp, err := svc.GetConversation(ctxAs(alice), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: created.Msg.Conversation.Id,
	}))
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if getResp.Msg.ActiveContext.Id != created.Msg.InitialContext.Id {
		t.Fatalf("pre-activate: active was %s, want %s", getResp.Msg.ActiveContext.Id, created.Msg.InitialContext.Id)
	}

	// Activate the older one.
	beforeT := getResp.Msg.ActiveContext.ActivationTime.AsTime()
	actResp, err := svc.ActivateContext(ctxAs(alice), connect.NewRequest(&reevev1.ActivateContextRequest{
		ContextId: olderID.String(),
	}))
	if err != nil {
		t.Fatalf("ActivateContext: %v", err)
	}
	if actResp.Msg.Context.Id != olderID.String() {
		t.Errorf("returned context: %s want %s", actResp.Msg.Context.Id, olderID)
	}
	afterT := actResp.Msg.Context.ActivationTime.AsTime()
	if !afterT.After(beforeT) {
		t.Errorf("activation_time should advance: before=%v after=%v", beforeT, afterT)
	}

	// And now GetConversation should report the older one as active.
	getResp2, err := svc.GetConversation(ctxAs(alice), connect.NewRequest(&reevev1.GetConversationRequest{
		Id: created.Msg.Conversation.Id,
	}))
	if err != nil {
		t.Fatalf("GetConversation 2: %v", err)
	}
	if getResp2.Msg.ActiveContext.Id != olderID.String() {
		t.Errorf("post-activate: active was %s, want %s", getResp2.Msg.ActiveContext.Id, olderID)
	}
}

func TestService_ActivateContext_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err = svc.ActivateContext(ctxAs(bob), connect.NewRequest(&reevev1.ActivateContextRequest{
		ContextId: created.Msg.InitialContext.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_ActivateContext_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.ActivateContext(ctxAs(alice), connect.NewRequest(&reevev1.ActivateContextRequest{
		ContextId: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ListMessages ---

func TestService_ListMessages_FullTree(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, strPtr("sys"), strPtr("seed-user"), nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	resp, err := svc.ListMessages(ctxAs(alice), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId: created.Msg.InitialContext.Id,
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(resp.Msg.Messages) != 2 {
		t.Errorf("messages: got %d want 2", len(resp.Msg.Messages))
	}
}

func TestService_ListMessages_LeafChain(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	contextUUID, _ := uuid.Parse(created.Msg.InitialContext.Id)

	// Build a tree:
	//   root
	//   ├── childA
	//   │     └── grandA
	//   └── childB
	mk := func(parent *uuid.UUID, role, content string) store.Message {
		t.Helper()
		id, _ := uuid.NewV7()
		m, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
			ID:        id,
			ContextID: contextUUID,
			ParentID:  parent,
			Role:      role,
			Content:   content,
		})
		if err != nil {
			t.Fatalf("CreateMessage: %v", err)
		}
		return m
	}
	root := mk(nil, "user", "root")
	childA := mk(&root.ID, "assistant", "A")
	grandA := mk(&childA.ID, "user", "A1")
	_ = mk(&root.ID, "assistant", "B")

	leaf := grandA.ID.String()
	resp, err := svc.ListMessages(ctxAs(alice), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId:     created.Msg.InitialContext.Id,
		LeafMessageId: &leaf,
	}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(resp.Msg.Messages) != 3 {
		t.Fatalf("chain: got %d want 3", len(resp.Msg.Messages))
	}
	if resp.Msg.Messages[0].Id != root.ID.String() {
		t.Errorf("root-first: got %s want %s", resp.Msg.Messages[0].Id, root.ID)
	}
	if resp.Msg.Messages[1].Id != childA.ID.String() {
		t.Errorf("middle: got %s want %s", resp.Msg.Messages[1].Id, childA.ID)
	}
	if resp.Msg.Messages[2].Id != grandA.ID.String() {
		t.Errorf("leaf: got %s want %s", resp.Msg.Messages[2].Id, grandA.ID)
	}
}

func TestService_ListMessages_LeafFromDifferentContext(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	c1, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("c1: %v", err)
	}
	c2, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("c2: %v", err)
	}
	c2ContextUUID, _ := uuid.Parse(c2.Msg.InitialContext.Id)
	id, _ := uuid.NewV7()
	m, err := q.CreateMessage(context.Background(), store.CreateMessageParams{
		ID:        id,
		ContextID: c2ContextUUID,
		Role:      "user",
		Content:   "alien",
	})
	if err != nil {
		t.Fatalf("seed alien: %v", err)
	}
	leaf := m.ID.String()
	_, err = svc.ListMessages(ctxAs(alice), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId:     c1.Msg.InitialContext.Id,
		LeafMessageId: &leaf,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_ListMessages_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err = svc.ListMessages(ctxAs(bob), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId: created.Msg.InitialContext.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_ListMessages_InvalidContextID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.ListMessages(ctxAs(alice), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_ListMessages_LeafNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, nil, nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	leaf := uuid.New().String()
	_, err = svc.ListMessages(ctxAs(alice), connect.NewRequest(&reevev1.ListMessagesRequest{
		ContextId:     created.Msg.InitialContext.Id,
		LeafMessageId: &leaf,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

// --- GetMessage ---

func TestService_GetMessage_Found(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	prof := makeProfile(t, q, alice.ID, strPtr("sys"), nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	if len(created.Msg.SeedMessages) != 1 {
		t.Fatalf("seeds: got %d want 1", len(created.Msg.SeedMessages))
	}
	mid := created.Msg.SeedMessages[0].Id
	resp, err := svc.GetMessage(ctxAs(alice), connect.NewRequest(&reevev1.GetMessageRequest{Id: mid}))
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if resp.Msg.Message.Id != mid {
		t.Errorf("id: got %s want %s", resp.Msg.Message.Id, mid)
	}
	if resp.Msg.Message.Content != "sys" {
		t.Errorf("content: %q", resp.Msg.Message.Content)
	}
}

func TestService_GetMessage_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	prof := makeProfile(t, q, alice.ID, strPtr("sys"), nil, nil)
	created, err := svc.CreateConversation(ctxAs(alice), connect.NewRequest(&reevev1.CreateConversationRequest{
		ProfileId: prof.ID.String(),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	mid := created.Msg.SeedMessages[0].Id
	_, err = svc.GetMessage(ctxAs(bob), connect.NewRequest(&reevev1.GetMessageRequest{Id: mid}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_GetMessage_NotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_, err := svc.GetMessage(ctxAs(alice), connect.NewRequest(&reevev1.GetMessageRequest{
		Id: uuid.New().String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_GetMessage_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	_ = q
	_, err := svc.GetMessage(ctxAs(alice), connect.NewRequest(&reevev1.GetMessageRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

