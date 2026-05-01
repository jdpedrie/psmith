package modelmeta

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// fakePayload is a minimal models.dev shape with two providers and a
// couple of models — enough to exercise lookup/list paths.
const fakePayload = `{
	"openai": {
		"id": "openai",
		"name": "OpenAI",
		"models": {
			"gpt-5": {
				"id": "gpt-5",
				"name": "GPT-5",
				"limit": {"context": 128000, "output": 4096},
				"cost": {"input": 5.0, "output": 15.0, "cache_read": 0.5}
			}
		}
	},
	"anthropic": {
		"id": "anthropic",
		"name": "Anthropic",
		"models": {
			"claude-haiku-4-5": {
				"id": "claude-haiku-4-5",
				"name": "Claude Haiku 4.5",
				"limit": {"context": 200000, "output": 8192},
				"cost": {"input": 0.25, "output": 1.25}
			}
		}
	}
}`

func newCatalogWithFake(t *testing.T) (*LiveCatalog, *int32, func()) {
	t.Helper()
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(fakePayload))
	}))
	c := NewLiveCatalog(&Fetcher{URL: srv.URL, Client: &http.Client{Timeout: 5 * time.Second}})
	return c, &calls, srv.Close
}

func TestLiveCatalog_LookupModel_LazyFetch(t *testing.T) {
	c, calls, cleanup := newCatalogWithFake(t)
	defer cleanup()

	// Status before any lookup: zero counts, no last refresh time.
	st, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.ProvidersCount != 0 || st.ModelsCount != 0 || st.LastRefreshAt != nil {
		t.Errorf("pre-lookup status not empty: %+v", st)
	}

	m, err := c.LookupModel(context.Background(), "openai", "gpt-5")
	if err != nil {
		t.Fatalf("LookupModel: %v", err)
	}
	if m.ContextWindow != 128000 {
		t.Errorf("ContextWindow=%d want 128000", m.ContextWindow)
	}
	if m.Pricing == nil || m.Pricing.InputPerMillion != 5.0 {
		t.Errorf("Pricing input=%+v want 5.0", m.Pricing)
	}

	if got := atomic.LoadInt32(calls); got != 1 {
		t.Errorf("first lookup should fetch once, got %d", got)
	}

	// Second lookup hits the cache — no additional fetch.
	if _, err := c.LookupModel(context.Background(), "anthropic", "claude-haiku-4-5"); err != nil {
		t.Fatalf("second LookupModel: %v", err)
	}
	if got := atomic.LoadInt32(calls); got != 1 {
		t.Errorf("subsequent lookup must not refetch, got %d", got)
	}
}

func TestLiveCatalog_LookupModel_NotFound(t *testing.T) {
	c, _, cleanup := newCatalogWithFake(t)
	defer cleanup()
	_, err := c.LookupModel(context.Background(), "openai", "no-such-model")
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("want ErrNotFound, got %v", err)
	}
}

func TestLiveCatalog_LookupProvider(t *testing.T) {
	c, _, cleanup := newCatalogWithFake(t)
	defer cleanup()
	p, err := c.LookupProvider(context.Background(), "anthropic")
	if err != nil {
		t.Fatalf("LookupProvider: %v", err)
	}
	if p.Name != "Anthropic" {
		t.Errorf("name=%q want Anthropic", p.Name)
	}
}

func TestLiveCatalog_ListProviders_Sorted(t *testing.T) {
	c, _, cleanup := newCatalogWithFake(t)
	defer cleanup()
	got, err := c.ListProviders(context.Background())
	if err != nil {
		t.Fatalf("ListProviders: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len=%d want 2", len(got))
	}
	if got[0].ID != "anthropic" || got[1].ID != "openai" {
		t.Errorf("not sorted by id: %+v", got)
	}
}

func TestLiveCatalog_ListModelsByProvider_AbsentProvider(t *testing.T) {
	c, _, cleanup := newCatalogWithFake(t)
	defer cleanup()
	got, err := c.ListModelsByProvider(context.Background(), "no-such-provider")
	if err != nil {
		t.Fatalf("ListModelsByProvider: %v", err)
	}
	if got != nil {
		t.Errorf("missing provider should return nil slice, got %+v", got)
	}
}

// Refresh must blow away the existing cache and replace from the fetch
// — i.e. it can't be a merge or it would leak deleted entries.
func TestLiveCatalog_Refresh_Replaces(t *testing.T) {
	var phase atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// Phase 0: openai+gpt-5. Phase 1: only anthropic+haiku.
		if phase.Load() == 0 {
			_, _ = w.Write([]byte(`{
				"openai": {"id":"openai","name":"OpenAI","models":{
					"gpt-5":{"id":"gpt-5","name":"GPT-5"}}}
			}`))
		} else {
			_, _ = w.Write([]byte(`{
				"anthropic": {"id":"anthropic","name":"Anthropic","models":{
					"claude-haiku-4-5":{"id":"claude-haiku-4-5","name":"Claude Haiku 4.5"}}}
			}`))
		}
	}))
	defer srv.Close()
	c := NewLiveCatalog(&Fetcher{URL: srv.URL, Client: &http.Client{Timeout: 5 * time.Second}})

	if _, err := c.LookupModel(context.Background(), "openai", "gpt-5"); err != nil {
		t.Fatalf("phase0 lookup: %v", err)
	}

	phase.Store(1)
	if err := c.Refresh(context.Background()); err != nil {
		t.Fatalf("Refresh: %v", err)
	}

	if _, err := c.LookupModel(context.Background(), "openai", "gpt-5"); !errors.Is(err, ErrNotFound) {
		t.Errorf("openai/gpt-5 should be gone after refresh, got %v", err)
	}
	if _, err := c.LookupModel(context.Background(), "anthropic", "claude-haiku-4-5"); err != nil {
		t.Errorf("anthropic/claude after refresh: %v", err)
	}
}

func TestLiveCatalog_Status_AfterFetch(t *testing.T) {
	c, _, cleanup := newCatalogWithFake(t)
	defer cleanup()
	if _, err := c.LookupProvider(context.Background(), "openai"); err != nil {
		t.Fatalf("LookupProvider: %v", err)
	}
	st, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.ProvidersCount != 2 {
		t.Errorf("providers=%d want 2", st.ProvidersCount)
	}
	if st.ModelsCount != 2 {
		t.Errorf("models=%d want 2", st.ModelsCount)
	}
	if st.LastRefreshAt == nil {
		t.Error("LastRefreshAt should be populated after fetch")
	}
}

// Fetch errors must propagate so the caller can decide whether to retry
// or fall through to driver-only metadata. Cache stays empty so the next
// call will re-attempt rather than serve stale absence.
func TestLiveCatalog_Fetch_Error_Propagates(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	c := NewLiveCatalog(&Fetcher{URL: srv.URL, Client: &http.Client{Timeout: 5 * time.Second}})

	_, err := c.LookupModel(context.Background(), "openai", "gpt-5")
	if err == nil {
		t.Fatal("expected fetch error, got nil")
	}

	// Cache should still be empty — next call must re-attempt.
	st, _ := c.Status(context.Background())
	if st.ProvidersCount != 0 || st.LastRefreshAt != nil {
		t.Errorf("cache should be empty after failed fetch: %+v", st)
	}
}
