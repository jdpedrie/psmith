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

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/auth"
	"github.com/jdpedrie/spalt/internal/crypto"
	"github.com/jdpedrie/spalt/internal/profiles"
	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/testutil"
)

// TestPluginPipeline proves attaching and removing a plugin on a profile.
func TestPluginPipeline(t *testing.T) {
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
	pid, _ := uuid.NewV7()
	if _, err := q.CreateProfile(context.Background(), store.CreateProfileParams{ID: pid, UserID: user.ID, Name: "P"}); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	profileID := pid.String()

	// The page lists available plugin types.
	pageReq := httptest.NewRequest("GET", "/settings/profiles/"+profileID+"/plugins", nil).WithContext(userCtx)
	pageReq.SetPathValue("id", profileID)
	pageRec := do(h.handlePluginsPage, pageReq)
	if pageRec.Code != http.StatusOK || !strings.Contains(pageRec.Body.String(), "basic_grounding") {
		t.Fatalf("plugins page bad; code=%d body:\n%s", pageRec.Code, pageRec.Body.String())
	}

	// Add a plugin.
	addForm := url.Values{"plugin_name": {"basic_grounding"}}
	addReq := httptest.NewRequest("POST", "/settings/profiles/"+profileID+"/plugins/add", strings.NewReader(addForm.Encode())).WithContext(userCtx)
	addReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	addReq.SetPathValue("id", profileID)
	if rec := do(h.handlePluginAdd, addReq); rec.Code != http.StatusSeeOther {
		t.Fatalf("add status=%d; body:\n%s", rec.Code, rec.Body.String())
	}
	got, err := prof.GetProfilePlugins(userCtx, connect.NewRequest(&spaltv1.GetProfilePluginsRequest{ProfileId: profileID}))
	if err != nil {
		t.Fatalf("GetProfilePlugins: %v", err)
	}
	if len(got.Msg.GetPlugins()) != 1 || got.Msg.GetPlugins()[0].GetPluginName() != "basic_grounding" {
		t.Fatalf("after add, plugins=%+v", got.Msg.GetPlugins())
	}

	// Remove it.
	rmForm := url.Values{"ordinal": {"0"}}
	rmReq := httptest.NewRequest("POST", "/settings/profiles/"+profileID+"/plugins/remove", strings.NewReader(rmForm.Encode())).WithContext(userCtx)
	rmReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rmReq.SetPathValue("id", profileID)
	if rec := do(h.handlePluginRemove, rmReq); rec.Code != http.StatusSeeOther {
		t.Fatalf("remove status=%d", rec.Code)
	}
	got2, _ := prof.GetProfilePlugins(userCtx, connect.NewRequest(&spaltv1.GetProfilePluginsRequest{ProfileId: profileID}))
	if len(got2.Msg.GetPlugins()) != 0 {
		t.Errorf("after remove, plugins=%d want 0", len(got2.Msg.GetPlugins()))
	}
}
