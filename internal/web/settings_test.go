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

	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/modelproviders"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// TestProvidersSettings proves the provider CRUD surface: the add form lists
// driver types, creating a provider redirects to its detail page, the list and
// detail render it, and deleting it removes it.
func TestProvidersSettings(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	cat := modelmeta.NewLiveCatalog(nil)
	models := modelproviders.NewService(q, cat, crypto.Nop{}, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Models: models, Logger: slog.Default()})

	ctx := context.Background()
	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(ctx, store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	userCtx := auth.ContextWithUser(ctx, auth.User{ID: user.ID, Username: "u"})

	// The add form lists at least the anthropic driver type.
	newRec := do(h.handleProviderNew, httptest.NewRequest("GET", "/settings/providers/new", nil).WithContext(userCtx))
	if newRec.Code != http.StatusOK || !strings.Contains(newRec.Body.String(), `value="anthropic"`) {
		t.Fatalf("new form missing anthropic type; code=%d body:\n%s", newRec.Code, newRec.Body.String())
	}

	// Create a provider.
	form := url.Values{"type": {"anthropic"}, "label": {"MyProv"}, "api_key": {"sk-test"}}
	createReq := httptest.NewRequest("POST", "/settings/providers", strings.NewReader(form.Encode())).WithContext(userCtx)
	createReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	createRec := do(h.handleProviderCreate, createReq)
	if createRec.Code != http.StatusSeeOther {
		t.Fatalf("create status=%d want 303; body:\n%s", createRec.Code, createRec.Body.String())
	}
	loc := createRec.Header().Get("Location")
	provID := strings.TrimPrefix(loc, "/settings/providers/")
	if provID == "" || provID == loc {
		t.Fatalf("unexpected redirect %q", loc)
	}

	// It appears in the list.
	listRec := do(h.handleProviders, httptest.NewRequest("GET", "/settings/providers", nil).WithContext(userCtx))
	if !strings.Contains(listRec.Body.String(), "MyProv") {
		t.Errorf("providers list missing MyProv; body:\n%s", listRec.Body.String())
	}

	// The detail page renders it with no models enabled.
	detReq := httptest.NewRequest("GET", "/settings/providers/"+provID, nil).WithContext(userCtx)
	detReq.SetPathValue("id", provID)
	detRec := do(h.handleProvider, detReq)
	if !strings.Contains(detRec.Body.String(), "MyProv") || !strings.Contains(detRec.Body.String(), "No models enabled") {
		t.Errorf("detail page wrong; body:\n%s", detRec.Body.String())
	}

	// Delete removes it.
	delReq := httptest.NewRequest("POST", "/settings/providers/"+provID+"/delete", nil).WithContext(userCtx)
	delReq.SetPathValue("id", provID)
	delRec := do(h.handleProviderDelete, delReq)
	if delRec.Code != http.StatusSeeOther || delRec.Header().Get("Location") != "/settings/providers" {
		t.Fatalf("delete redirect wrong: code=%d loc=%q", delRec.Code, delRec.Header().Get("Location"))
	}
	list2 := do(h.handleProviders, httptest.NewRequest("GET", "/settings/providers", nil).WithContext(userCtx))
	if strings.Contains(list2.Body.String(), "MyProv") {
		t.Errorf("provider still listed after delete")
	}
}

func do(fn http.HandlerFunc, req *http.Request) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	fn(rec, req)
	return rec
}
