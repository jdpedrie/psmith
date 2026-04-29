package profiles

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/internal/auth"
	"github.com/jdpedrie/clark/internal/store"
	"github.com/jdpedrie/clark/internal/testutil"
)

// --- helpers ---

func newTestSvc(t *testing.T) (*Service, *store.Queries) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	return NewService(q, pool), q
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
		PasswordHash: "x", // not exercised here
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

func mustCreateProvider(t *testing.T, q *store.Queries, userID uuid.UUID) store.UserModelProvider {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	p, err := q.CreateUserModelProvider(context.Background(), store.CreateUserModelProviderParams{
		ID:     id,
		UserID: userID,
		Type:   "openai-compatible",
		Label:  "test",
		Config: []byte(`{}`),
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}
	return p
}

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

// --- CreateProfile ---

func TestService_CreateProfile_Minimal(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	resp, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name: "minimal",
	}))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if resp.Msg.Profile.Name != "minimal" {
		t.Errorf("name: %q", resp.Msg.Profile.Name)
	}
	if resp.Msg.Profile.OwnerUserId != user.ID.String() {
		t.Errorf("owner: %q vs %s", resp.Msg.Profile.OwnerUserId, user.ID)
	}
	if resp.Msg.Profile.SystemMessage != nil {
		t.Errorf("system_message should be nil: %+v", resp.Msg.Profile.SystemMessage)
	}
}

func TestService_CreateProfile_AllFields(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")
	prov := mustCreateProvider(t, q, user.ID)
	provIDStr := prov.ID.String()
	mode := clarkv1.CompressionMode_COMPRESSION_MODE_APPEND
	includeThinking := true

	resp, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:                  "full",
		SystemMessage:         strPtr("sys"),
		DefaultUserMessage:    strPtr("ctx"),
		CompressionGuide:      strPtr("guide"),
		CompressionMode:       &mode,
		CompressionProviderId: &provIDStr,
		CompressionModelId:    strPtr("the-model"),
		DefaultSettings: &clarkv1.ProfileDefaults{
			DefaultModelId:           strPtr("default-model"),
			IncludeThinkingInHistory: &includeThinking,
		},
	}))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	got := resp.Msg.Profile
	if got.SystemMessage == nil || *got.SystemMessage != "sys" {
		t.Errorf("system_message: %+v", got.SystemMessage)
	}
	if got.CompressionMode == nil || *got.CompressionMode != clarkv1.CompressionMode_COMPRESSION_MODE_APPEND {
		t.Errorf("compression_mode: %+v", got.CompressionMode)
	}
	if got.CompressionProviderId == nil || *got.CompressionProviderId != provIDStr {
		t.Errorf("compression_provider_id: %+v", got.CompressionProviderId)
	}
	if got.DefaultSettings == nil {
		t.Fatal("default_settings nil")
	}
	if got.DefaultSettings.DefaultModelId == nil || *got.DefaultSettings.DefaultModelId != "default-model" {
		t.Errorf("default_settings.default_model_id: %+v", got.DefaultSettings.DefaultModelId)
	}
	if got.DefaultSettings.IncludeThinkingInHistory == nil || !*got.DefaultSettings.IncludeThinkingInHistory {
		t.Errorf("default_settings.include_thinking: %+v", got.DefaultSettings.IncludeThinkingInHistory)
	}
}

func TestService_CreateProfile_DescriptionAndParentOnly(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	resp, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:        "tmpl",
		Description: "Shared base prompt",
		ParentOnly:  true,
	}))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if resp.Msg.Profile.Description != "Shared base prompt" {
		t.Errorf("description: %q", resp.Msg.Profile.Description)
	}
	if !resp.Msg.Profile.ParentOnly {
		t.Errorf("parent_only should be true")
	}
}

func TestService_CreateProfile_DescriptionAndParentOnlyDefaults(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	resp, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name: "default",
	}))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if resp.Msg.Profile.Description != "" {
		t.Errorf("description default: %q", resp.Msg.Profile.Description)
	}
	if resp.Msg.Profile.ParentOnly {
		t.Errorf("parent_only default should be false")
	}
}

func TestService_UpdateProfile_DescriptionAndParentOnly(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	created, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name: "p",
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	desc := "Now described"
	parentOnly := true
	resp, err := svc.UpdateProfile(ctxAs(user), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:          created.Msg.Profile.Id,
		Description: &desc,
		ParentOnly:  &parentOnly,
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.Description != desc {
		t.Errorf("description: %q", resp.Msg.Profile.Description)
	}
	if !resp.Msg.Profile.ParentOnly {
		t.Errorf("parent_only should be true after update")
	}

	// clear description via clear_fields → empty string
	resp2, err := svc.UpdateProfile(ctxAs(user), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:          created.Msg.Profile.Id,
		ClearFields: []string{"description"},
	}))
	if err != nil {
		t.Fatalf("UpdateProfile clear: %v", err)
	}
	if resp2.Msg.Profile.Description != "" {
		t.Errorf("description after clear: %q", resp2.Msg.Profile.Description)
	}
	if !resp2.Msg.Profile.ParentOnly {
		t.Errorf("parent_only should still be true after unrelated clear")
	}
}

func TestService_CreateProfile_MissingName(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	user := mustCreateUser(t, q, "alice")

	_, err := svc.CreateProfile(ctxAs(user), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name: "",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_CreateProfile_ParentOwnedBySomeoneElse(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")

	// Alice's parent profile.
	parentResp, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "alice-parent"}))
	if err != nil {
		t.Fatalf("seed parent: %v", err)
	}
	pid := parentResp.Msg.Profile.Id

	// Bob tries to use it.
	_, err = svc.CreateProfile(ctxAs(bob), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:            "bob-child",
		ParentProfileId: &pid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_CreateProfile_ParentNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	missing := uuid.New().String()
	_, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:            "child",
		ParentProfileId: &missing,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_CreateProfile_ParentBadUUID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	bad := "not-a-uuid"
	_, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:            "child",
		ParentProfileId: &bad,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_CreateProfile_CompressionProviderOwnedBySomeoneElse(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	bobProv := mustCreateProvider(t, q, bob.ID)
	pid := bobProv.ID.String()

	_, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:                  "x",
		CompressionProviderId: &pid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_CreateProfile_CompressionProviderNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	pid := uuid.New().String()
	_, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:                  "x",
		CompressionProviderId: &pid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- ListProfiles ---

func TestService_ListProfiles_PerUser(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")

	for _, n := range []string{"a1", "a2"} {
		if _, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: n})); err != nil {
			t.Fatalf("seed alice: %v", err)
		}
	}
	if _, err := svc.CreateProfile(ctxAs(bob), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "b1"})); err != nil {
		t.Fatalf("seed bob: %v", err)
	}

	// Alice sees her two.
	resp, err := svc.ListProfiles(ctxAs(alice), connect.NewRequest(&clarkv1.ListProfilesRequest{}))
	if err != nil {
		t.Fatalf("ListProfiles: %v", err)
	}
	if len(resp.Msg.Profiles) != 2 {
		t.Errorf("alice: got %d want 2", len(resp.Msg.Profiles))
	}
	for _, p := range resp.Msg.Profiles {
		if p.OwnerUserId != alice.ID.String() {
			t.Errorf("leaked profile from %s", p.OwnerUserId)
		}
	}

	// Bob sees his one.
	bResp, err := svc.ListProfiles(ctxAs(bob), connect.NewRequest(&clarkv1.ListProfilesRequest{}))
	if err != nil {
		t.Fatalf("ListProfiles bob: %v", err)
	}
	if len(bResp.Msg.Profiles) != 1 {
		t.Errorf("bob: got %d want 1", len(bResp.Msg.Profiles))
	}
}

// --- GetProfile ---

func TestService_GetProfile_Found(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	created, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:          "p",
		SystemMessage: strPtr("hello"),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	resp, err := svc.GetProfile(ctxAs(alice), connect.NewRequest(&clarkv1.GetProfileRequest{
		Id: created.Msg.Profile.Id,
	}))
	if err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	if resp.Msg.Profile.SystemMessage == nil || *resp.Msg.Profile.SystemMessage != "hello" {
		t.Errorf("system_message: %+v", resp.Msg.Profile.SystemMessage)
	}
	if resp.Msg.Resolved != nil {
		t.Errorf("resolved should be nil when resolve=false: %+v", resp.Msg.Resolved)
	}
}

func TestService_GetProfile_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")

	created, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, err = svc.GetProfile(ctxAs(bob), connect.NewRequest(&clarkv1.GetProfileRequest{
		Id: created.Msg.Profile.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_GetProfile_NotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	_, err := svc.GetProfile(ctxAs(alice), connect.NewRequest(&clarkv1.GetProfileRequest{
		Id: uuid.New().String(),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_GetProfile_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	_, err := svc.GetProfile(ctxAs(alice), connect.NewRequest(&clarkv1.GetProfileRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_GetProfile_Resolve_WalksParentChain(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	parent, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:             "parent",
		CompressionGuide: strPtr("inherited-guide"),
	}))
	if err != nil {
		t.Fatalf("seed parent: %v", err)
	}
	pid := parent.Msg.Profile.Id

	child, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:            "child",
		ParentProfileId: &pid,
		SystemMessage:   strPtr("child-sys"),
	}))
	if err != nil {
		t.Fatalf("seed child: %v", err)
	}

	resp, err := svc.GetProfile(ctxAs(alice), connect.NewRequest(&clarkv1.GetProfileRequest{
		Id:      child.Msg.Profile.Id,
		Resolve: true,
	}))
	if err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	if resp.Msg.Profile.CompressionGuide != nil {
		t.Errorf("raw profile compression_guide should be nil: %+v", resp.Msg.Profile.CompressionGuide)
	}
	if resp.Msg.Resolved == nil {
		t.Fatal("resolved missing")
	}
	if resp.Msg.Resolved.CompressionGuide == nil || *resp.Msg.Resolved.CompressionGuide != "inherited-guide" {
		t.Errorf("resolved compression_guide: %+v", resp.Msg.Resolved.CompressionGuide)
	}
	if resp.Msg.Resolved.SystemMessage == nil || *resp.Msg.Resolved.SystemMessage != "child-sys" {
		t.Errorf("resolved system_message: %+v", resp.Msg.Resolved.SystemMessage)
	}
}

// --- UpdateProfile ---

func TestService_UpdateProfile_SetField(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:            p.Msg.Profile.Id,
		SystemMessage: strPtr("new-sys"),
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.SystemMessage == nil || *resp.Msg.Profile.SystemMessage != "new-sys" {
		t.Errorf("system_message: %+v", resp.Msg.Profile.SystemMessage)
	}
}

func TestService_UpdateProfile_RenameViaName(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "old"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	newName := "new"
	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:   p.Msg.Profile.Id,
		Name: &newName,
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.Name != "new" {
		t.Errorf("name: %q", resp.Msg.Profile.Name)
	}
}

func TestService_UpdateProfile_ClearField(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	// Create with system_message set.
	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:          "p",
		SystemMessage: strPtr("seeded"),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Clear via clear_fields.
	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:          p.Msg.Profile.Id,
		ClearFields: []string{"system_message"},
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.SystemMessage != nil {
		t.Errorf("system_message should be cleared: %+v", resp.Msg.Profile.SystemMessage)
	}
}

func TestService_UpdateProfile_LeavesUntouchedFieldsAlone(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:               "p",
		SystemMessage:      strPtr("sys"),
		DefaultUserMessage: strPtr("user"),
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Update only compression_guide; the other fields must remain.
	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:               p.Msg.Profile.Id,
		CompressionGuide: strPtr("guide"),
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.SystemMessage == nil || *resp.Msg.Profile.SystemMessage != "sys" {
		t.Errorf("system_message lost: %+v", resp.Msg.Profile.SystemMessage)
	}
	if resp.Msg.Profile.DefaultUserMessage == nil || *resp.Msg.Profile.DefaultUserMessage != "user" {
		t.Errorf("default_user_message lost: %+v", resp.Msg.Profile.DefaultUserMessage)
	}
	if resp.Msg.Profile.CompressionGuide == nil || *resp.Msg.Profile.CompressionGuide != "guide" {
		t.Errorf("compression_guide: %+v", resp.Msg.Profile.CompressionGuide)
	}
}

func TestService_UpdateProfile_CompressionMode(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	mode := clarkv1.CompressionMode_COMPRESSION_MODE_REPLACE
	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:              p.Msg.Profile.Id,
		CompressionMode: &mode,
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.CompressionMode == nil || *resp.Msg.Profile.CompressionMode != clarkv1.CompressionMode_COMPRESSION_MODE_REPLACE {
		t.Errorf("compression_mode: %+v", resp.Msg.Profile.CompressionMode)
	}

	// Then clear it.
	resp, err = svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:          p.Msg.Profile.Id,
		ClearFields: []string{"compression_mode"},
	}))
	if err != nil {
		t.Fatalf("UpdateProfile clear: %v", err)
	}
	if resp.Msg.Profile.CompressionMode != nil {
		t.Errorf("compression_mode should be cleared: %+v", resp.Msg.Profile.CompressionMode)
	}
}

func TestService_UpdateProfile_DefaultSettings(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	include := false
	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id: p.Msg.Profile.Id,
		DefaultSettings: &clarkv1.ProfileDefaults{
			DefaultModelId:           strPtr("m1"),
			IncludeThinkingInHistory: &include,
		},
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.DefaultSettings == nil {
		t.Fatal("default_settings nil")
	}
	if resp.Msg.Profile.DefaultSettings.DefaultModelId == nil || *resp.Msg.Profile.DefaultSettings.DefaultModelId != "m1" {
		t.Errorf("default_model_id: %+v", resp.Msg.Profile.DefaultSettings.DefaultModelId)
	}
}

func TestService_UpdateProfile_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, err = svc.UpdateProfile(ctxAs(bob), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:            p.Msg.Profile.Id,
		SystemMessage: strPtr("hijack"),
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_UpdateProfile_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	_, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_UpdateProfile_CompressionProviderOwnedBySomeoneElse(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")
	bobProv := mustCreateProvider(t, q, bob.ID)

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	bid := bobProv.ID.String()
	_, err = svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:                    p.Msg.Profile.Id,
		CompressionProviderId: &bid,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

// --- DeleteProfile ---

func TestService_DeleteProfile_Success(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	if _, err := svc.DeleteProfile(ctxAs(alice), connect.NewRequest(&clarkv1.DeleteProfileRequest{
		Id: p.Msg.Profile.Id,
	})); err != nil {
		t.Fatalf("DeleteProfile: %v", err)
	}

	// Subsequent get should not find it.
	_, err = svc.GetProfile(ctxAs(alice), connect.NewRequest(&clarkv1.GetProfileRequest{
		Id: p.Msg.Profile.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_DeleteProfile_OtherUserNotFound(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")
	bob := mustCreateUser(t, q, "bob")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, err = svc.DeleteProfile(ctxAs(bob), connect.NewRequest(&clarkv1.DeleteProfileRequest{
		Id: p.Msg.Profile.Id,
	}))
	assertCode(t, err, connect.CodeNotFound)
}

func TestService_DeleteProfile_InvalidID(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	_, err := svc.DeleteProfile(ctxAs(alice), connect.NewRequest(&clarkv1.DeleteProfileRequest{
		Id: "not-a-uuid",
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_DeleteProfile_WithChildren_FailedPrecondition(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	parent, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "parent"}))
	if err != nil {
		t.Fatalf("seed parent: %v", err)
	}
	pid := parent.Msg.Profile.Id
	if _, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:            "child",
		ParentProfileId: &pid,
	})); err != nil {
		t.Fatalf("seed child: %v", err)
	}

	_, err = svc.DeleteProfile(ctxAs(alice), connect.NewRequest(&clarkv1.DeleteProfileRequest{Id: pid}))
	assertCode(t, err, connect.CodeFailedPrecondition)
}

// --- title_provider_kind ---------------------------------------------------

func TestService_CreateProfile_WithTitleProviderKind(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	kind := TitleProviderKindAppleFoundation
	resp, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:              "local",
		TitleProviderKind: &kind,
	}))
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if resp.Msg.Profile.TitleProviderKind == nil || *resp.Msg.Profile.TitleProviderKind != kind {
		t.Errorf("title_provider_kind round-trip: %+v", resp.Msg.Profile.TitleProviderKind)
	}
}

func TestService_CreateProfile_RejectsUnknownTitleProviderKind(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	bogus := "not_a_real_kind"
	_, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:              "p",
		TitleProviderKind: &bogus,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}

func TestService_UpdateProfile_SetTitleProviderKind(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	kind := TitleProviderKindAppleFoundation
	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:                p.Msg.Profile.Id,
		TitleProviderKind: &kind,
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.TitleProviderKind == nil || *resp.Msg.Profile.TitleProviderKind != kind {
		t.Errorf("title_provider_kind: %+v", resp.Msg.Profile.TitleProviderKind)
	}
}

func TestService_UpdateProfile_ClearTitleProviderKind(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	kind := TitleProviderKindAppleFoundation
	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{
		Name:              "p",
		TitleProviderKind: &kind,
	}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	resp, err := svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:          p.Msg.Profile.Id,
		ClearFields: []string{"title_provider_kind"},
	}))
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if resp.Msg.Profile.TitleProviderKind != nil {
		t.Errorf("title_provider_kind should be cleared: %+v", resp.Msg.Profile.TitleProviderKind)
	}
}

func TestService_UpdateProfile_RejectsUnknownTitleProviderKind(t *testing.T) {
	t.Parallel()
	svc, q := newTestSvc(t)
	alice := mustCreateUser(t, q, "alice")

	p, err := svc.CreateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.CreateProfileRequest{Name: "p"}))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	bogus := "not_a_real_kind"
	_, err = svc.UpdateProfile(ctxAs(alice), connect.NewRequest(&clarkv1.UpdateProfileRequest{
		Id:                p.Msg.Profile.Id,
		TitleProviderKind: &bogus,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
}
