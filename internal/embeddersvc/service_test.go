package embeddersvc

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/embeddings"

	// Register the openai driver so IsRegistered passes in tests.
	_ "github.com/jdpedrie/psmith/internal/embeddings/openai"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/internal/testutil"
)

type fixture struct {
	svc       *Service
	user      store.User
	invalCnt  *invalidationCounter
	cipher    crypto.Cipher
	queries   *store.Queries
	ctxAsUser context.Context
}

type invalidationCounter struct {
	mu  sync.Mutex
	n   int
	ids []uuid.UUID
}

func (c *invalidationCounter) invalidate(id uuid.UUID) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n++
	c.ids = append(c.ids, id)
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	cipher := crypto.Nop{} // plaintext fallback for the test bench
	inval := &invalidationCounter{}
	svc := NewService(q, cipher, inval.invalidate, nil)

	user, err := q.CreateUser(context.Background(), store.CreateUserParams{
		ID: uuid.New(), Username: "embeddersvc-test-" + uuid.NewString()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	ctx := auth.ContextWithUser(context.Background(), auth.User{
		ID: user.ID, Username: user.Username,
	})
	return fixture{
		svc: svc, user: user, invalCnt: inval, cipher: cipher,
		queries: q, ctxAsUser: ctx,
	}
}

func TestGetEmbedderConfig_DefaultsWhenNoRow(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	resp, err := f.svc.GetEmbedderConfig(f.ctxAsUser,
		connect.NewRequest(&psmithv1.GetEmbedderConfigRequest{}))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	c := resp.Msg.Config
	if c == nil {
		t.Fatal("Config should be non-nil even with no row")
	}
	if c.Type != "openai" {
		t.Errorf("Type=%q want openai", c.Type)
	}
	if c.BaseUrl != "http://localhost:11434/v1" || c.Model != "nomic-embed-text" || c.Dimensions != 768 {
		t.Errorf("defaults wrong: %+v", c)
	}
	if c.Enabled {
		t.Error("Enabled should default false")
	}
	if c.ApiKeySet {
		t.Error("ApiKeySet should default false")
	}
}

func TestUpdateEmbedderConfig_FullWrite(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	apiKey := "sk-test-key"
	enabled := true
	resp, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type:       strPtr("openai"),
		BaseUrl:    strPtr("https://api.openai.com/v1"),
		Model:      strPtr("text-embedding-3-small"),
		Dimensions: int32Ptr(1536),
		ApiKey:     &apiKey,
		Enabled:    &enabled,
	}))
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	c := resp.Msg.Config
	if c.BaseUrl != "https://api.openai.com/v1" {
		t.Errorf("BaseUrl=%q", c.BaseUrl)
	}
	if c.Model != "text-embedding-3-small" || c.Dimensions != 1536 {
		t.Errorf("model/dim wrong: %s/%d", c.Model, c.Dimensions)
	}
	if !c.ApiKeySet {
		t.Error("ApiKeySet should be true after writing a key")
	}
	if !c.Enabled {
		t.Error("Enabled should be true")
	}
	if f.invalCnt.n != 1 {
		t.Errorf("invalidateCache called %d times, want 1", f.invalCnt.n)
	}

	// Get should mirror what Update returned, never echoing the key.
	getResp, _ := f.svc.GetEmbedderConfig(f.ctxAsUser,
		connect.NewRequest(&psmithv1.GetEmbedderConfigRequest{}))
	if !getResp.Msg.Config.ApiKeySet {
		t.Error("ApiKeySet should persist across Get")
	}
}

func TestUpdateEmbedderConfig_SparseMergePreservesUnchanged(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	// First write: full row.
	apiKey := "sk-initial"
	enabled := true
	_, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type:       strPtr("openai"),
		BaseUrl:    strPtr("https://api.openai.com/v1"),
		Model:      strPtr("text-embedding-3-small"),
		Dimensions: int32Ptr(1536),
		ApiKey:     &apiKey,
		Enabled:    &enabled,
	}))
	if err != nil {
		t.Fatalf("first Update: %v", err)
	}

	// Second write: only changes the model. Everything else stays.
	resp, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Model: strPtr("text-embedding-3-large"),
	}))
	if err != nil {
		t.Fatalf("second Update: %v", err)
	}
	c := resp.Msg.Config
	if c.Model != "text-embedding-3-large" {
		t.Errorf("Model=%q", c.Model)
	}
	if c.BaseUrl != "https://api.openai.com/v1" {
		t.Errorf("BaseUrl reset to %q on sparse update", c.BaseUrl)
	}
	if c.Dimensions != 1536 {
		t.Errorf("Dimensions reset to %d", c.Dimensions)
	}
	if !c.ApiKeySet {
		t.Error("ApiKeySet should be preserved on sparse update")
	}
	if !c.Enabled {
		t.Error("Enabled should be preserved on sparse update")
	}
}

func TestUpdateEmbedderConfig_EmptyAPIKeyClearsIt(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	// Save a key first.
	apiKey := "sk-keep"
	_, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type:       strPtr("openai"),
		BaseUrl:    strPtr("https://api.openai.com/v1"),
		Model:      strPtr("text-embedding-3-small"),
		Dimensions: int32Ptr(1536),
		ApiKey:     &apiKey,
	}))
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	// Clear it.
	empty := ""
	resp, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		ApiKey: &empty,
	}))
	if err != nil {
		t.Fatalf("Update clear: %v", err)
	}
	if resp.Msg.Config.ApiKeySet {
		t.Error("ApiKeySet should be false after clearing")
	}
}

func TestUpdateEmbedderConfig_RejectsUnknownType(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type:       strPtr("not-a-driver"),
		BaseUrl:    strPtr("https://x"),
		Model:      strPtr("m"),
		Dimensions: int32Ptr(1),
	}))
	if err == nil || !strings.Contains(err.Error(), "unknown embedder type") {
		t.Errorf("want unknown-type error, got %v", err)
	}
}

func TestDeleteEmbedderConfig_RemovesAndInvalidates(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	apiKey := "sk"
	_, _ = f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type: strPtr("openai"), BaseUrl: strPtr("https://x"), Model: strPtr("m"),
		Dimensions: int32Ptr(8), ApiKey: &apiKey,
	}))
	f.invalCnt.n = 0 // reset so we can assert Delete invalidates

	_, err := f.svc.DeleteEmbedderConfig(f.ctxAsUser,
		connect.NewRequest(&psmithv1.DeleteEmbedderConfigRequest{}))
	if err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if f.invalCnt.n != 1 {
		t.Errorf("Delete invalidateCache=%d want 1", f.invalCnt.n)
	}
	// Subsequent Get returns the defaults again.
	resp, _ := f.svc.GetEmbedderConfig(f.ctxAsUser,
		connect.NewRequest(&psmithv1.GetEmbedderConfigRequest{}))
	if resp.Msg.Config.ApiKeySet {
		t.Error("ApiKeySet should be false after Delete")
	}
}

func TestListEmbedderTypes_IncludesRegistered(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	resp, err := f.svc.ListEmbedderTypes(f.ctxAsUser,
		connect.NewRequest(&psmithv1.ListEmbedderTypesRequest{}))
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	var found bool
	for _, t := range resp.Msg.Types {
		if t == "openai" {
			found = true
		}
	}
	if !found {
		t.Errorf("openai missing from types: %v", resp.Msg.Types)
	}
}

func TestNewDBResolver_NoRowSurfacesSentinel(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	build := NewDBResolver(f.queries, f.cipher)
	_, err := build(context.Background(), f.user.ID)
	if !errors.Is(err, embeddings.ErrNoEmbedderForUser) {
		t.Errorf("want ErrNoEmbedderForUser, got %v", err)
	}
}

func TestNewDBResolver_DisabledRowSurfacesSentinel(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	disabled := false
	apiKey := "k"
	_, _ = f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type:       strPtr("openai"),
		BaseUrl:    strPtr("https://x"),
		Model:      strPtr("m"),
		Dimensions: int32Ptr(8),
		ApiKey:     &apiKey,
		Enabled:    &disabled,
	}))
	build := NewDBResolver(f.queries, f.cipher)
	_, err := build(context.Background(), f.user.ID)
	if !errors.Is(err, embeddings.ErrNoEmbedderForUser) {
		t.Errorf("disabled row should be ErrNoEmbedderForUser, got %v", err)
	}
}

func TestNewDBResolver_BuildsEmbedderForEnabledRow(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	enabled := true
	apiKey := "k"
	_, _ = f.svc.UpdateEmbedderConfig(f.ctxAsUser, connect.NewRequest(&psmithv1.UpdateEmbedderConfigRequest{
		Type:       strPtr("openai"),
		BaseUrl:    strPtr("https://api.openai.com/v1"),
		Model:      strPtr("text-embedding-3-small"),
		Dimensions: int32Ptr(1536),
		ApiKey:     &apiKey,
		Enabled:    &enabled,
	}))
	build := NewDBResolver(f.queries, f.cipher)
	e, err := build(context.Background(), f.user.ID)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if e.Model() != "text-embedding-3-small" {
		t.Errorf("Model=%q", e.Model())
	}
	if e.Dimensions() != 1536 {
		t.Errorf("Dimensions=%d", e.Dimensions())
	}
}

func strPtr(s string) *string { return &s }
func int32Ptr(i int32) *int32 { return &i }
