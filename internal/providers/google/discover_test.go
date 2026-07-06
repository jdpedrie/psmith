package google

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/providers"
)

// modelsHandler mounts /v1beta/models with a canned listModelsResponse.
// `methods` defaults to []string{"generateContent"} for every entry; pass
// per-id overrides via methodsByID.
func modelsHandler(t *testing.T, ids []string, methodsByID map[string][]string) http.Handler {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1beta/models", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("models: unexpected method %s", r.Method)
		}
		// API key must arrive via the x-goog-api-key header, NEVER as
		// a query param — query strings end up in error messages /
		// proxy logs and have leaked a key into a committed test
		// artifact in the past.
		if got := r.URL.Query().Get("key"); got != "" {
			t.Errorf("models: API key leaked into query string (got %q)", got)
		}
		if got := r.Header.Get("x-goog-api-key"); got == "" {
			t.Errorf("models: missing x-goog-api-key header")
		}
		var data []geminiModelInfo
		for _, id := range ids {
			methods := methodsByID[id]
			if methods == nil {
				methods = []string{"generateContent"}
			}
			data = append(data, geminiModelInfo{
				Name:                       "models/" + id,
				DisplayName:                strings.ToUpper(id[:1]) + id[1:],
				SupportedGenerationMethods: methods,
			})
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(listModelsResponse{Models: data})
	})
	return mux
}

func TestDiscoverModels_HappyPath(t *testing.T) {
	srv := httptest.NewServer(modelsHandler(t,
		[]string{"gemini-test-known", "gemini-test-unknown"},
		nil))
	defer srv.Close()

	cutoff := time.Date(2025, 1, 15, 0, 0, 0, 0, time.UTC)
	cat := &fakeCatalog{models: map[string]*modelmeta.Model{
		"gemini-test-known": {
			ID:              "gemini-test-known",
			DisplayName:     "Gemini Test Known",
			ContextWindow:   1_000_000,
			MaxOutputTokens: 65536,
			Pricing: &modelmeta.Pricing{
				InputPerMillion:  0.075,
				OutputPerMillion: 0.3,
			},
			Capabilities: modelmeta.Capabilities{
				Streaming: true,
				Thinking:  true,
				ToolUse:   true,
			},
			Modalities:      []string{"text", "image"},
			KnowledgeCutoff: &cutoff,
		},
	}}

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{Catalog: cat})

	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 2 {
		t.Fatalf("got %d models, want 2: %+v", len(models), models)
	}
	byID := map[string]providers.Model{}
	for _, m := range models {
		byID[m.ID] = m
	}

	hit := byID["gemini-test-known"]
	if hit.MetadataSource != modelmeta.SourceCatalog {
		t.Errorf("known: source=%q want catalog", hit.MetadataSource)
	}
	if hit.DisplayName != "Gemini Test Known" {
		t.Errorf("known: DisplayName=%q want catalog override", hit.DisplayName)
	}
	if hit.ContextWindow != 1_000_000 {
		t.Errorf("known: ContextWindow=%d want 1_000_000", hit.ContextWindow)
	}
	if hit.Pricing == nil || hit.Pricing.InputPerMillion != 0.075 {
		t.Errorf("known: Pricing not copied: %+v", hit.Pricing)
	}
	if !hit.Capabilities.Thinking {
		t.Errorf("known: Capabilities.Thinking not copied")
	}
	if hit.KnowledgeCutoff != "2025-01-15" {
		t.Errorf("known: KnowledgeCutoff=%q want 2025-01-15", hit.KnowledgeCutoff)
	}

	miss := byID["gemini-test-unknown"]
	if miss.MetadataSource != modelmeta.SourceDriver {
		t.Errorf("miss: source=%q want driver", miss.MetadataSource)
	}
	if miss.ContextWindow != 0 {
		t.Errorf("miss: ContextWindow=%d want 0", miss.ContextWindow)
	}
}

func TestDiscoverModels_NoCatalog(t *testing.T) {
	srv := httptest.NewServer(modelsHandler(t, []string{"gemini-a", "gemini-b"}, nil))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 2 {
		t.Fatalf("got %d models, want 2", len(models))
	}
	for _, m := range models {
		if m.MetadataSource != modelmeta.SourceDriver {
			t.Errorf("model %q: source=%q want driver", m.ID, m.MetadataSource)
		}
	}
}

func TestDiscoverModels_FiltersGenerateContentOnly(t *testing.T) {
	srv := httptest.NewServer(modelsHandler(t,
		[]string{"gemini-chat", "embedding-001"},
		map[string][]string{
			"gemini-chat":   {"generateContent", "streamGenerateContent"},
			"embedding-001": {"embedContent"},
		}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})

	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 1 || models[0].ID != "gemini-chat" {
		t.Errorf("expected only gemini-chat, got %+v", models)
	}
}

func TestDiscoverModels_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"code":500,"message":"boom"}}`))
	}))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	_, err := d.DiscoverModels(context.Background())
	if err == nil {
		t.Fatal("expected error from upstream 500")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("expected 500 in error message, got %v", err)
	}
}

func TestDiscoverModels_StripsModelsPrefix(t *testing.T) {
	srv := httptest.NewServer(modelsHandler(t, []string{"gemini-2.5-flash"}, nil))
	defer srv.Close()

	d := newDriverWithBaseURL(t, srv.URL+"/v1beta", providers.Deps{})
	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatalf("DiscoverModels: %v", err)
	}
	if len(models) != 1 {
		t.Fatalf("got %d models, want 1", len(models))
	}
	if models[0].ID != "gemini-2.5-flash" {
		t.Errorf("ID=%q want gemini-2.5-flash (no models/ prefix)", models[0].ID)
	}
}
