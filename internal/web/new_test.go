package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/conversations"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// TestNewConversationFlow proves the new-conversation page lists usable
// profiles and that picking one creates a conversation and redirects to it.
func TestNewConversationFlow(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	sup := stream.New(q, slog.Default())
	convos := conversations.NewService(q, pool, cat, sup, crypto.Nop{}, nil, slog.Default())
	prof := profiles.NewService(q, pool, crypto.Nop{})
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Conversations: convos, Profiles: prof, Supervisor: sup, Logger: slog.Default()})

	ctx := context.Background()
	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	pid, _ := uuid.NewV7()
	sys := "Be helpful."
	if _, err := q.CreateProfile(ctx, store.CreateProfileParams{ID: pid, UserID: user.ID, Name: "Helper", SystemMessage: &sys}); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	userCtx := auth.ContextWithUser(ctx, auth.User{ID: user.ID, Username: "u"})

	// The picker lists the profile.
	formReq := httptest.NewRequest("GET", "/new", nil).WithContext(userCtx)
	formRec := httptest.NewRecorder()
	h.handleNewForm(formRec, formReq)
	if formRec.Code != http.StatusOK {
		t.Fatalf("new form status=%d", formRec.Code)
	}
	if body := formRec.Body.String(); !strings.Contains(body, "Helper") || !strings.Contains(body, `action="/new"`) {
		t.Fatalf("new form missing profile or action; body:\n%s", body)
	}

	// Picking it creates a conversation and redirects to it.
	form := url.Values{"profile_id": {pid.String()}}
	createReq := httptest.NewRequest("POST", "/new", strings.NewReader(form.Encode())).WithContext(userCtx)
	createReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	createRec := httptest.NewRecorder()
	h.handleNewCreate(createRec, createReq)

	if createRec.Code != http.StatusSeeOther {
		t.Fatalf("create status=%d want 303; body:\n%s", createRec.Code, createRec.Body.String())
	}
	loc := createRec.Header().Get("Location")
	if !strings.HasPrefix(loc, "/c/") {
		t.Fatalf("redirect=%q want /c/<id>", loc)
	}

	// The conversation now exists for the user.
	list, err := convos.ListConversations(userCtx, connect.NewRequest(&reevev1.ListConversationsRequest{PageSize: 10}))
	if err != nil {
		t.Fatalf("ListConversations: %v", err)
	}
	if len(list.Msg.GetConversations()) != 1 {
		t.Fatalf("conversations=%d want 1", len(list.Msg.GetConversations()))
	}
	if got := "/c/" + list.Msg.GetConversations()[0].GetId(); got != loc {
		t.Errorf("redirect %q != created conversation %q", loc, got)
	}
}
