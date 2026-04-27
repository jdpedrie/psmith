package modelmeta_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/store"
	"github.com/jdpedrie/clark/internal/testutil"
)

func newCatalog(t *testing.T) *modelmeta.DBCatalog {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	return modelmeta.NewDBCatalog(q, nil)
}

func sampleSnapshot(fetched time.Time) modelmeta.Snapshot {
	knowledge := time.Date(2024, 10, 1, 0, 0, 0, 0, time.UTC)
	return modelmeta.Snapshot{
		FetchedAt: fetched,
		Providers: []modelmeta.ProviderSnapshot{
			{
				Provider: modelmeta.Provider{
					ID:        "anthropic",
					Name:      "Anthropic",
					APIBase:   "https://api.anthropic.com/v1",
					EnvKey:    "ANTHROPIC_API_KEY",
					DocURL:    "https://docs.anthropic.com",
					FetchedAt: fetched,
				},
				RawJSON: []byte(`{"id":"anthropic"}`),
				Models: []modelmeta.ModelSnapshot{
					{
						Model: modelmeta.Model{
							ProviderID:      "anthropic",
							ID:              "claude-opus-4-5",
							DisplayName:     "Claude Opus 4.5",
							ContextWindow:   200000,
							MaxOutputTokens: 8192,
							Pricing: &modelmeta.Pricing{
								InputPerMillion:      15,
								OutputPerMillion:     75,
								CacheReadPerMillion:  1.5,
								CacheWritePerMillion: 18.75,
							},
							Modalities:      []string{"text", "image"},
							KnowledgeCutoff: &knowledge,
							Capabilities: modelmeta.Capabilities{
								Streaming: true, Thinking: true, ToolUse: true, Vision: true, PromptCaching: true,
							},
							FetchedAt: fetched,
						},
						RawJSON: []byte(`{"id":"claude-opus-4-5"}`),
					},
				},
			},
			{
				Provider: modelmeta.Provider{
					ID:        "groq",
					Name:      "Groq",
					APIBase:   "https://api.groq.com/openai/v1",
					EnvKey:    "GROQ_API_KEY",
					FetchedAt: fetched,
				},
				RawJSON: []byte(`{"id":"groq"}`),
				Models: nil,
			},
		},
	}
}

func TestDBCatalog_Upsert_LookupModel(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	now := time.Date(2026, 4, 25, 12, 0, 0, 0, time.UTC)

	if err := cat.Upsert(context.Background(), sampleSnapshot(now)); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	m, err := cat.LookupModel(context.Background(), "anthropic", "claude-opus-4-5")
	if err != nil {
		t.Fatalf("LookupModel: %v", err)
	}
	if m.DisplayName != "Claude Opus 4.5" || m.ContextWindow != 200000 || m.MaxOutputTokens != 8192 {
		t.Errorf("model fields off: %+v", m)
	}
	if m.Pricing == nil || m.Pricing.InputPerMillion != 15 || m.Pricing.CacheWritePerMillion != 18.75 {
		t.Errorf("pricing not preserved: %+v", m.Pricing)
	}
	if !m.Capabilities.Thinking || !m.Capabilities.ToolUse || !m.Capabilities.Vision {
		t.Errorf("capabilities not preserved: %+v", m.Capabilities)
	}
	if m.KnowledgeCutoff == nil || m.KnowledgeCutoff.Year() != 2024 {
		t.Errorf("knowledge cutoff lost: %+v", m.KnowledgeCutoff)
	}
}

func TestDBCatalog_LookupModel_NotFound(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	_, err := cat.LookupModel(context.Background(), "anthropic", "nope")
	if !errors.Is(err, modelmeta.ErrNotFound) {
		t.Errorf("got %v want ErrNotFound", err)
	}
}

func TestDBCatalog_Upsert_LookupProvider(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	if err := cat.Upsert(context.Background(), sampleSnapshot(time.Now().UTC())); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	p, err := cat.LookupProvider(context.Background(), "groq")
	if err != nil {
		t.Fatalf("LookupProvider: %v", err)
	}
	if p.Name != "Groq" || p.APIBase != "https://api.groq.com/openai/v1" || p.EnvKey != "GROQ_API_KEY" {
		t.Errorf("provider fields off: %+v", p)
	}
}

func TestDBCatalog_LookupProvider_NotFound(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	_, err := cat.LookupProvider(context.Background(), "nope")
	if !errors.Is(err, modelmeta.ErrNotFound) {
		t.Errorf("got %v want ErrNotFound", err)
	}
}

func TestDBCatalog_ListProviders(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	if err := cat.Upsert(context.Background(), sampleSnapshot(time.Now().UTC())); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	ps, err := cat.ListProviders(context.Background())
	if err != nil {
		t.Fatalf("ListProviders: %v", err)
	}
	if len(ps) != 2 {
		t.Fatalf("got %d providers want 2", len(ps))
	}
	// ListCatalogProviders orders by id.
	if ps[0].ID != "anthropic" || ps[1].ID != "groq" {
		t.Errorf("ordering: %v", []string{ps[0].ID, ps[1].ID})
	}
}

func TestDBCatalog_Upsert_Idempotent(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	now := time.Now().UTC()
	if err := cat.Upsert(context.Background(), sampleSnapshot(now)); err != nil {
		t.Fatalf("first Upsert: %v", err)
	}
	if err := cat.Upsert(context.Background(), sampleSnapshot(now)); err != nil {
		t.Fatalf("second Upsert: %v", err)
	}
	st, err := cat.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.ProvidersCount != 2 {
		t.Errorf("providers count drift: %d", st.ProvidersCount)
	}
	if st.ModelsCount != 1 {
		t.Errorf("models count drift: %d", st.ModelsCount)
	}
}

func TestDBCatalog_Status_Empty(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	st, err := cat.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.ProvidersCount != 0 || st.ModelsCount != 0 {
		t.Errorf("expected empty, got %+v", st)
	}
	if st.LastRefreshAt != nil {
		t.Errorf("expected nil last_refresh_at, got %v", st.LastRefreshAt)
	}
}

func TestDBCatalog_Status_PopulatedHasTimestamp(t *testing.T) {
	t.Parallel()
	cat := newCatalog(t)
	now := time.Date(2026, 4, 25, 12, 0, 0, 0, time.UTC)
	if err := cat.Upsert(context.Background(), sampleSnapshot(now)); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	st, err := cat.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.LastRefreshAt == nil {
		t.Fatal("expected non-nil LastRefreshAt")
	}
	if !st.LastRefreshAt.Equal(now) {
		t.Errorf("expected %v, got %v", now, *st.LastRefreshAt)
	}
}
