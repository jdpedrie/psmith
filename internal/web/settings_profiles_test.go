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
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// TestProfilesSettings proves the profile CRUD surface: create, list, edit
// (load + save), and delete.
func TestProfilesSettings(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	prof := profiles.NewService(q, pool, crypto.Nop{})
	h := New(q, auth.NewService(q), nil, nil, prof, nil, slog.Default())

	ctx := context.Background()
	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	userCtx := auth.ContextWithUser(ctx, auth.User{ID: user.ID, Username: "u"})

	// Create.
	cf := url.Values{"name": {"Helper"}, "system_message": {"be nice"}, "description": {"a helper"}}
	createReq := httptest.NewRequest("POST", "/settings/profiles", strings.NewReader(cf.Encode())).WithContext(userCtx)
	createReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	createRec := do(h.handleProfileCreate, createReq)
	if createRec.Code != http.StatusSeeOther {
		t.Fatalf("create status=%d; body:\n%s", createRec.Code, createRec.Body.String())
	}
	id := strings.TrimPrefix(createRec.Header().Get("Location"), "/settings/profiles/")
	if id == "" {
		t.Fatal("no profile id in redirect")
	}

	// List shows it.
	listRec := do(h.handleProfiles, httptest.NewRequest("GET", "/settings/profiles", nil).WithContext(userCtx))
	if !strings.Contains(listRec.Body.String(), "Helper") {
		t.Errorf("list missing Helper; body:\n%s", listRec.Body.String())
	}

	// Edit form loads current values.
	editReq := httptest.NewRequest("GET", "/settings/profiles/"+id, nil).WithContext(userCtx)
	editReq.SetPathValue("id", id)
	editRec := do(h.handleProfileEdit, editReq)
	if b := editRec.Body.String(); !strings.Contains(b, `value="Helper"`) || !strings.Contains(b, "be nice") {
		t.Errorf("edit form missing values; body:\n%s", b)
	}

	// Save changes.
	uf := url.Values{"name": {"Helper2"}, "system_message": {"be kind"}, "description": {"updated"}}
	upReq := httptest.NewRequest("POST", "/settings/profiles/"+id, strings.NewReader(uf.Encode())).WithContext(userCtx)
	upReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	upReq.SetPathValue("id", id)
	upRec := do(h.handleProfileUpdate, upReq)
	if upRec.Code != http.StatusSeeOther {
		t.Fatalf("update status=%d; body:\n%s", upRec.Code, upRec.Body.String())
	}

	got, err := prof.GetProfile(userCtx, connect.NewRequest(&reevev1.GetProfileRequest{Id: id}))
	if err != nil {
		t.Fatalf("GetProfile: %v", err)
	}
	if p := got.Msg.GetProfile(); p.GetName() != "Helper2" || p.GetSystemMessage() != "be kind" {
		t.Errorf("update not persisted: name=%q system=%q", p.GetName(), p.GetSystemMessage())
	}

	// Delete.
	delReq := httptest.NewRequest("POST", "/settings/profiles/"+id+"/delete", nil).WithContext(userCtx)
	delReq.SetPathValue("id", id)
	delRec := do(h.handleProfileDelete, delReq)
	if delRec.Code != http.StatusSeeOther || delRec.Header().Get("Location") != "/settings/profiles" {
		t.Fatalf("delete redirect wrong: code=%d loc=%q", delRec.Code, delRec.Header().Get("Location"))
	}
}
