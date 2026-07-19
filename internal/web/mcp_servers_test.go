package web

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/profiles"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
)

// TestMCPServersSettings proves the registry CRUD round-trip through the
// web surface: create renders in the list, the edit form withholds
// secrets, and delete removes the row.
func TestMCPServersSettings(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	prof := profiles.NewService(q, pool, crypto.Nop{})
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Profiles: prof, Logger: slog.Default()})

	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(context.Background(), store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	userCtx := auth.ContextWithUser(context.Background(), auth.User{ID: user.ID, Username: "u"})

	// Create.
	form := url.Values{
		"name":      {"Firecrawl"},
		"transport": {"http"},
		"url":       {"https://mcp.firecrawl.test/rpc"},
		"headers":   {"Authorization: Bearer fc-secret"},
	}
	createReq := httptest.NewRequest("POST", "/settings/mcp-servers", strings.NewReader(form.Encode())).WithContext(userCtx)
	createReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := do(h.handleMCPServerSave, createReq)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("create: code=%d body:\n%s", rec.Code, rec.Body.String())
	}

	// List shows the server, not its secrets.
	listRec := do(h.handleMCPServers, httptest.NewRequest("GET", "/settings/mcp-servers", nil).WithContext(userCtx))
	if listRec.Code != http.StatusOK || !strings.Contains(listRec.Body.String(), "Firecrawl") {
		t.Fatalf("list missing server; code=%d", listRec.Code)
	}
	if strings.Contains(listRec.Body.String(), "fc-secret") {
		t.Fatal("secret leaked into the list page")
	}

	// Find the id via the store to hit the edit form.
	rows, err := q.ListUserMCPServers(context.Background(), user.ID)
	if err != nil || len(rows) != 1 {
		t.Fatalf("rows=%v err=%v", rows, err)
	}
	id := rows[0].ID.String()

	editReq := httptest.NewRequest("GET", "/settings/mcp-servers/"+id, nil).WithContext(userCtx)
	editReq.SetPathValue("id", id)
	editRec := do(h.handleMCPServerEdit, editReq)
	if editRec.Code != http.StatusOK || !strings.Contains(editRec.Body.String(), "leave blank to keep") {
		t.Fatalf("edit form should hint at kept secrets; code=%d", editRec.Code)
	}
	if strings.Contains(editRec.Body.String(), "fc-secret") {
		t.Fatal("secret leaked into the edit form")
	}

	// Delete.
	delReq := httptest.NewRequest("POST", "/settings/mcp-servers/"+id+"/delete", nil).WithContext(userCtx)
	delReq.SetPathValue("id", id)
	delRec := do(h.handleMCPServerDelete, delReq)
	if delRec.Code != http.StatusSeeOther {
		t.Fatalf("delete: code=%d", delRec.Code)
	}
	rows, _ = q.ListUserMCPServers(context.Background(), user.ID)
	if len(rows) != 0 {
		t.Fatalf("row survived delete: %v", rows)
	}
}
