package preferencessvc

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/auth"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"
)

func TestGet_DefaultsWithoutRow(t *testing.T) {
	t.Parallel()
	q := store.New(testutil.Pool(t))
	svc := NewService(q)
	user := mustUser(t, q)

	resp, err := svc.GetPreferences(ctxAsUser(user), connect.NewRequest(&psmithv1.GetPreferencesRequest{}))
	if err != nil {
		t.Fatalf("GetPreferences: %v", err)
	}
	if got := resp.Msg.Preferences.GetContextWarningTokens(); got != 0 {
		t.Errorf("default context_warning_tokens = %d, want 0", got)
	}
}

func TestUpdate_SetsAndPersists(t *testing.T) {
	t.Parallel()
	q := store.New(testutil.Pool(t))
	svc := NewService(q)
	user := mustUser(t, q)

	v := int32(75_000)
	resp, err := svc.UpdatePreferences(ctxAsUser(user), connect.NewRequest(&psmithv1.UpdatePreferencesRequest{ContextWarningTokens: &v}))
	if err != nil {
		t.Fatalf("UpdatePreferences: %v", err)
	}
	if got := resp.Msg.Preferences.GetContextWarningTokens(); got != v {
		t.Errorf("response context_warning_tokens = %d, want %d", got, v)
	}
	got, err := svc.GetPreferences(ctxAsUser(user), connect.NewRequest(&psmithv1.GetPreferencesRequest{}))
	if err != nil {
		t.Fatalf("GetPreferences: %v", err)
	}
	if got.Msg.Preferences.GetContextWarningTokens() != v {
		t.Errorf("stored context_warning_tokens = %d, want %d", got.Msg.Preferences.GetContextWarningTokens(), v)
	}
}

// An update that sets nothing must not reset what's stored: future
// fields arrive as separate sparse updates from different screens.
func TestUpdate_UnsetFieldKeepsStoredValue(t *testing.T) {
	t.Parallel()
	q := store.New(testutil.Pool(t))
	svc := NewService(q)
	user := mustUser(t, q)

	v := int32(200_000)
	if _, err := svc.UpdatePreferences(ctxAsUser(user), connect.NewRequest(&psmithv1.UpdatePreferencesRequest{ContextWarningTokens: &v})); err != nil {
		t.Fatalf("first update: %v", err)
	}
	resp, err := svc.UpdatePreferences(ctxAsUser(user), connect.NewRequest(&psmithv1.UpdatePreferencesRequest{}))
	if err != nil {
		t.Fatalf("empty update: %v", err)
	}
	if got := resp.Msg.Preferences.GetContextWarningTokens(); got != v {
		t.Errorf("after empty update = %d, want %d", got, v)
	}
}

func TestUpdate_ZeroTurnsWarningOff(t *testing.T) {
	t.Parallel()
	q := store.New(testutil.Pool(t))
	svc := NewService(q)
	user := mustUser(t, q)

	on, off := int32(50_000), int32(0)
	for _, v := range []*int32{&on, &off} {
		if _, err := svc.UpdatePreferences(ctxAsUser(user), connect.NewRequest(&psmithv1.UpdatePreferencesRequest{ContextWarningTokens: v})); err != nil {
			t.Fatalf("UpdatePreferences(%d): %v", *v, err)
		}
	}
	row, err := q.GetUserPreferences(context.Background(), user.ID)
	if err != nil {
		t.Fatalf("GetUserPreferences: %v", err)
	}
	if row.ContextWarningTokens != 0 {
		t.Errorf("stored = %d, want 0", row.ContextWarningTokens)
	}
}

func TestUpdate_RejectsNegative(t *testing.T) {
	t.Parallel()
	q := store.New(testutil.Pool(t))
	svc := NewService(q)
	user := mustUser(t, q)

	v := int32(-1)
	_, err := svc.UpdatePreferences(ctxAsUser(user), connect.NewRequest(&psmithv1.UpdatePreferencesRequest{ContextWarningTokens: &v}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("got %v, want InvalidArgument", err)
	}
}

// Preferences are per user: one user's setting never shows up for
// another.
func TestPreferences_ArePerUser(t *testing.T) {
	t.Parallel()
	q := store.New(testutil.Pool(t))
	svc := NewService(q)
	alice, bob := mustUser(t, q), mustUser(t, q)

	v := int32(75_000)
	if _, err := svc.UpdatePreferences(ctxAsUser(alice), connect.NewRequest(&psmithv1.UpdatePreferencesRequest{ContextWarningTokens: &v})); err != nil {
		t.Fatalf("UpdatePreferences: %v", err)
	}
	resp, err := svc.GetPreferences(ctxAsUser(bob), connect.NewRequest(&psmithv1.GetPreferencesRequest{}))
	if err != nil {
		t.Fatalf("GetPreferences: %v", err)
	}
	if got := resp.Msg.Preferences.GetContextWarningTokens(); got != 0 {
		t.Errorf("bob sees %d, want 0", got)
	}
}

func mustUser(t *testing.T, q *store.Queries) store.User {
	t.Helper()
	id := uuid.New()
	u, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID:           id,
		Username:     "user-" + id.String()[:8],
		PasswordHash: "test-hash",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return u
}

func ctxAsUser(u store.User) context.Context {
	return auth.ContextWithUser(context.Background(), auth.User{
		ID: u.ID, Username: u.Username, IsAdmin: u.IsAdmin,
		CreatedAt: u.CreatedAt, UpdatedAt: u.UpdatedAt,
	})
}
