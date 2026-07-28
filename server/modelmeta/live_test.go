package modelmeta

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
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

// A snapshot older than maxAge must be re-fetched by the next lookup —
// otherwise a long-running daemon serves its launch-day model list
// forever and newly released models never show up in discovery.
func TestLiveCatalog_StaleSnapshot_Refetches(t *testing.T) {
	var phase atomic.Int32
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.Header().Set("Content-Type", "application/json")
		// Phase 0: catalog without the new model. Phase 1: with it.
		if phase.Load() == 0 {
			_, _ = w.Write([]byte(`{
				"anthropic": {"id":"anthropic","name":"Anthropic","models":{
					"claude-sonnet-4-6":{"id":"claude-sonnet-4-6","name":"Claude Sonnet 4.6"}}}
			}`))
		} else {
			_, _ = w.Write([]byte(`{
				"anthropic": {"id":"anthropic","name":"Anthropic","models":{
					"claude-sonnet-4-6":{"id":"claude-sonnet-4-6","name":"Claude Sonnet 4.6"},
					"claude-sonnet-5":{"id":"claude-sonnet-5","name":"Claude Sonnet 5"}}}
			}`))
		}
	}))
	defer srv.Close()
	c := NewLiveCatalog(&Fetcher{URL: srv.URL, Client: &http.Client{Timeout: 5 * time.Second}})

	if _, err := c.LookupModel(context.Background(), "anthropic", "claude-sonnet-4-6"); err != nil {
		t.Fatalf("initial lookup: %v", err)
	}
	if _, err := c.LookupModel(context.Background(), "anthropic", "claude-sonnet-5"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("sonnet-5 should be absent pre-release, got %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("fresh snapshot must not refetch, calls=%d", got)
	}

	// The model releases; the local snapshot passes maxAge.
	phase.Store(1)
	c.mu.Lock()
	c.loadedAt = time.Now().Add(-c.maxAge - time.Minute)
	c.lastAttempt = c.loadedAt
	c.mu.Unlock()

	if _, err := c.LookupModel(context.Background(), "anthropic", "claude-sonnet-5"); err != nil {
		t.Errorf("stale snapshot should refetch and find the new model, got %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("stale lookup should fetch exactly once more, calls=%d", got)
	}
}

// A failed refresh of a stale snapshot serves the stale data (stale
// beats dead) and leaves the snapshot eligible for retry by the next
// caller past maxAge.
func TestLiveCatalog_StaleRefreshFailure_ServesStale(t *testing.T) {
	var failing atomic.Bool
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&calls, 1)
		if failing.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(fakePayload))
	}))
	defer srv.Close()
	c := NewLiveCatalog(&Fetcher{URL: srv.URL, Client: &http.Client{Timeout: 5 * time.Second}})

	if _, err := c.LookupModel(context.Background(), "openai", "gpt-5"); err != nil {
		t.Fatalf("initial lookup: %v", err)
	}

	failing.Store(true)
	c.mu.Lock()
	c.loadedAt = time.Now().Add(-c.maxAge - time.Minute)
	c.lastAttempt = c.loadedAt
	c.mu.Unlock()

	// Refresh attempt fails; the stale snapshot must still answer.
	if _, err := c.LookupModel(context.Background(), "openai", "gpt-5"); err != nil {
		t.Errorf("stale data should be served when refresh fails, got %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("failed refresh should have been attempted once, calls=%d", got)
	}

	// Within the retry backoff, lookups serve stale WITHOUT re-attempting
	// the fetch — an outage must not turn every lookup into a network call.
	if _, err := c.LookupModel(context.Background(), "openai", "gpt-5"); err != nil {
		t.Errorf("lookup during backoff: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("backoff should suppress refetch, calls=%d", got)
	}

	// Upstream recovers and the backoff elapses: the next lookup retries.
	failing.Store(false)
	c.mu.Lock()
	c.lastAttempt = time.Now().Add(-refreshRetryBackoff - time.Minute)
	c.mu.Unlock()
	if _, err := c.LookupModel(context.Background(), "openai", "gpt-5"); err != nil {
		t.Errorf("recovered refresh: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 3 {
		t.Errorf("recovery should refetch, calls=%d", got)
	}
	st, _ := c.Status(context.Background())
	if st.LastRefreshAt == nil || time.Since(*st.LastRefreshAt) > time.Minute {
		t.Errorf("recovered refresh should bump LastRefreshAt, got %+v", st.LastRefreshAt)
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

// Cold-start lookup while another goroutine's fetch is already in flight
// must fetch anyway (no wait queue) without corrupting the mutex — the
// original TTL implementation double-unlocked here, which is a fatal
// runtime error that took the whole daemon down under concurrent first
// touches.
func TestLiveCatalog_ColdStartConcurrentFetch(t *testing.T) {
	c, _, cleanup := newCatalogWithFake(t)
	defer cleanup()

	c.mu.Lock()
	c.fetching = true // simulate another goroutine mid-fetch
	c.mu.Unlock()

	if _, err := c.LookupModel(context.Background(), "openai", "gpt-5"); err != nil {
		t.Fatalf("cold-start lookup during in-flight fetch: %v", err)
	}
	// The simulated claimant's flag must survive this call (we didn't
	// claim, so we must not clear it).
	c.mu.RLock()
	fetching := c.fetching
	c.mu.RUnlock()
	if !fetching {
		t.Error("non-claiming fetch must not clear the claimant's fetching flag")
	}
}

// Hammer ensureLoaded from many goroutines across cold start and a stale
// snapshot — guards the locking discipline (go test -race covers the
// data-race half; the fatal double-unlock half crashes the test binary).
func TestLiveCatalog_ConcurrentLookups(t *testing.T) {
	c, _, cleanup := newCatalogWithFake(t)
	defer cleanup()

	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = c.LookupModel(context.Background(), "openai", "gpt-5")
		}()
	}
	wg.Wait()

	// Age the snapshot and hammer again — exercises the refresh-claim path.
	c.mu.Lock()
	c.loadedAt = time.Now().Add(-c.maxAge - time.Minute)
	c.lastAttempt = c.loadedAt
	c.mu.Unlock()
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = c.LookupModel(context.Background(), "openai", "gpt-5")
		}()
	}
	wg.Wait()
}
