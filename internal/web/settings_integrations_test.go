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
	"github.com/jdpedrie/spalt/internal/embeddersvc"
	_ "github.com/jdpedrie/spalt/internal/embeddings/openai" // registers the "openai" embedder type
	"github.com/jdpedrie/spalt/internal/langfuse"
	"github.com/jdpedrie/spalt/internal/langfusesvc"
	"github.com/jdpedrie/spalt/internal/store"
	"github.com/jdpedrie/spalt/internal/testutil"
)

func TestEmbedderSettings(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	emb := embeddersvc.NewService(q, crypto.Nop{}, func(uuid.UUID) {}, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Embedder: emb, Logger: slog.Default()})

	userCtx, _ := seedUserCtx(t, q)

	// Page renders for an unconfigured user.
	pageRec := do(h.handleEmbedder, httptest.NewRequest("GET", "/settings/embedder", nil).WithContext(userCtx))
	if pageRec.Code != http.StatusOK || !strings.Contains(pageRec.Body.String(), "Embedder") {
		t.Fatalf("embedder page bad; code=%d", pageRec.Code)
	}

	// Save a config.
	form := url.Values{
		"enabled":    {"on"},
		"type":       {"openai"},
		"base_url":   {"http://localhost:11434/v1"},
		"model":      {"nomic-embed-text"},
		"dimensions": {"768"},
		"api_key":    {"sk-x"},
	}
	saveReq := httptest.NewRequest("POST", "/settings/embedder", strings.NewReader(form.Encode())).WithContext(userCtx)
	saveReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if rec := do(h.handleEmbedderSave, saveReq); rec.Code != http.StatusSeeOther {
		t.Fatalf("embedder save status=%d; body:\n%s", rec.Code, rec.Body.String())
	}

	got, err := emb.GetEmbedderConfig(userCtx, connect.NewRequest(&spaltv1.GetEmbedderConfigRequest{}))
	if err != nil {
		t.Fatalf("GetEmbedderConfig: %v", err)
	}
	c := got.Msg.GetConfig()
	if c.GetModel() != "nomic-embed-text" || c.GetDimensions() != 768 || !c.GetEnabled() || !c.GetApiKeySet() {
		t.Errorf("config not persisted: %+v", c)
	}
}

func TestLangfuseSettings(t *testing.T) {
	t.Parallel()

	pool := testutil.Pool(t)
	q := store.New(pool)
	emitter := langfuse.NewEmitter(slog.Default(), langfuse.EmitterConfig{})
	defer emitter.Stop(context.Background())
	lf := langfusesvc.NewService(q, crypto.Nop{}, emitter, slog.Default())
	h := New(Deps{Queries: q, Auth: auth.NewService(q), Langfuse: lf, Logger: slog.Default()})

	userCtx, _ := seedUserCtx(t, q)

	pageRec := do(h.handleLangfuse, httptest.NewRequest("GET", "/settings/langfuse", nil).WithContext(userCtx))
	if pageRec.Code != http.StatusOK || !strings.Contains(pageRec.Body.String(), "Langfuse") {
		t.Fatalf("langfuse page bad; code=%d", pageRec.Code)
	}

	form := url.Values{
		"enabled":    {"on"},
		"host":       {"https://us.cloud.langfuse.com"},
		"public_key": {"pk-123"},
		"secret_key": {"sk-456"},
	}
	saveReq := httptest.NewRequest("POST", "/settings/langfuse", strings.NewReader(form.Encode())).WithContext(userCtx)
	saveReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if rec := do(h.handleLangfuseSave, saveReq); rec.Code != http.StatusSeeOther {
		t.Fatalf("langfuse save status=%d; body:\n%s", rec.Code, rec.Body.String())
	}

	got, err := lf.GetLangfuseConfig(userCtx, connect.NewRequest(&spaltv1.GetLangfuseConfigRequest{}))
	if err != nil {
		t.Fatalf("GetLangfuseConfig: %v", err)
	}
	c := got.Msg.GetConfig()
	if c.GetPublicKey() != "pk-123" || !c.GetEnabled() || !c.GetSecretKeySet() {
		t.Errorf("config not persisted: %+v", c)
	}
}

// seedUserCtx creates a user and returns a context carrying it.
func seedUserCtx(t *testing.T, q *store.Queries) (context.Context, uuid.UUID) {
	t.Helper()
	uid, _ := uuid.NewV7()
	user, err := q.CreateUser(context.Background(), store.CreateUserParams{ID: uid, Username: t.Name(), PasswordHash: "x"})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	return auth.ContextWithUser(context.Background(), auth.User{ID: user.ID, Username: "u"}), user.ID
}
