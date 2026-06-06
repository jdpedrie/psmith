package openai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeOpenAI is a stub that speaks `/embeddings` (relative to the
// configured base) and lets tests capture the request body + headers.
// status + body let cases simulate success / 4xx / 5xx paths.
func fakeOpenAI(t *testing.T, status int, body string,
	captureReq *embedRequest, captureAuth *string,
) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/embeddings" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Errorf("method=%s want POST", r.Method)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("Content-Type=%q", got)
		}
		if captureAuth != nil {
			*captureAuth = r.Header.Get("Authorization")
		}
		if captureReq != nil {
			if err := json.NewDecoder(r.Body).Decode(captureReq); err != nil {
				t.Errorf("decode req: %v", err)
			}
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func newWithConfig(t *testing.T, baseURL string, extras map[string]any) *embedder {
	t.Helper()
	cfg := map[string]any{
		"base_url":   baseURL,
		"model":      "test-embed",
		"dimensions": 3,
	}
	for k, v := range extras {
		cfg[k] = v
	}
	raw, _ := json.Marshal(cfg)
	e, err := newEmbedder(raw)
	if err != nil {
		t.Fatalf("newEmbedder: %v", err)
	}
	return e.(*embedder)
}

func TestEmbed_HappyPath(t *testing.T) {
	var captured embedRequest
	srv := fakeOpenAI(t, http.StatusOK,
		`{"data":[{"embedding":[0.1,0.2,0.3],"index":0},{"embedding":[0.4,0.5,0.6],"index":1}]}`,
		&captured, nil)

	e := newWithConfig(t, srv.URL, nil)
	out, err := e.Embed(context.Background(), []string{"alpha", "beta"})
	if err != nil {
		t.Fatalf("Embed: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("got %d vectors, want 2", len(out))
	}
	if out[0][0] != 0.1 || out[1][2] != 0.6 {
		t.Errorf("vectors decoded wrong: %v", out)
	}
	if captured.Model != "test-embed" {
		t.Errorf("captured model=%q", captured.Model)
	}
	if len(captured.Input) != 2 || captured.Input[0] != "alpha" {
		t.Errorf("captured inputs=%v", captured.Input)
	}
}

func TestEmbed_AuthorizationHeaderSetWhenAPIKey(t *testing.T) {
	var auth string
	srv := fakeOpenAI(t, http.StatusOK,
		`{"data":[{"embedding":[0.1,0.2,0.3],"index":0}]}`, nil, &auth)

	e := newWithConfig(t, srv.URL, map[string]any{"api_key": "sk-test"})
	if _, err := e.Embed(context.Background(), []string{"x"}); err != nil {
		t.Fatalf("Embed: %v", err)
	}
	if auth != "Bearer sk-test" {
		t.Errorf("Authorization=%q want Bearer sk-test", auth)
	}
}

func TestEmbed_AuthorizationHeaderOmittedWhenNoKey(t *testing.T) {
	var auth string
	srv := fakeOpenAI(t, http.StatusOK,
		`{"data":[{"embedding":[0.1,0.2,0.3],"index":0}]}`, nil, &auth)

	e := newWithConfig(t, srv.URL, nil) // no api_key — Ollama-style
	if _, err := e.Embed(context.Background(), []string{"x"}); err != nil {
		t.Fatalf("Embed: %v", err)
	}
	if auth != "" {
		t.Errorf("Authorization should be empty for Ollama-style auth, got %q", auth)
	}
}

func TestEmbed_ResponseOutOfOrderReassembled(t *testing.T) {
	// Some gateways have shipped responses out of input order. The
	// driver re-sorts by index to recover the original mapping.
	srv := fakeOpenAI(t, http.StatusOK,
		`{"data":[{"embedding":[0.4,0.5,0.6],"index":1},{"embedding":[0.1,0.2,0.3],"index":0}]}`,
		nil, nil)
	e := newWithConfig(t, srv.URL, nil)
	out, err := e.Embed(context.Background(), []string{"alpha", "beta"})
	if err != nil {
		t.Fatalf("Embed: %v", err)
	}
	if out[0][0] != 0.1 || out[1][2] != 0.6 {
		t.Errorf("reorder broken: %v", out)
	}
}

func TestEmbed_EmptyInputReturnsNil(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Error("server should not be called for empty input")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	e := newWithConfig(t, srv.URL, nil)
	out, err := e.Embed(context.Background(), nil)
	if err != nil {
		t.Fatalf("Embed nil: %v", err)
	}
	if out != nil {
		t.Errorf("expected nil out, got %v", out)
	}
}

func TestEmbed_DimensionMismatchSurfaces(t *testing.T) {
	srv := fakeOpenAI(t, http.StatusOK,
		`{"data":[{"embedding":[0.1,0.2,0.3,0.4],"index":0}]}`, nil, nil)
	e := newWithConfig(t, srv.URL, nil)
	_, err := e.Embed(context.Background(), []string{"x"})
	if err == nil || !strings.Contains(err.Error(), "dim 4") {
		t.Errorf("want dimension-mismatch error, got %v", err)
	}
}

func TestEmbed_CountMismatchSurfaces(t *testing.T) {
	srv := fakeOpenAI(t, http.StatusOK,
		`{"data":[{"embedding":[0.1,0.2,0.3],"index":0}]}`, nil, nil)
	e := newWithConfig(t, srv.URL, nil)
	_, err := e.Embed(context.Background(), []string{"a", "b"})
	if err == nil || !strings.Contains(err.Error(), "1 embeddings for 2 inputs") {
		t.Errorf("want count-mismatch error, got %v", err)
	}
}

func TestEmbed_ServerErrorPropagates(t *testing.T) {
	srv := fakeOpenAI(t, http.StatusNotFound,
		`{"error":{"message":"model not found"}}`, nil, nil)
	e := newWithConfig(t, srv.URL, nil)
	_, err := e.Embed(context.Background(), []string{"x"})
	if err == nil || !strings.Contains(err.Error(), "HTTP 404") {
		t.Errorf("want 404 surface, got %v", err)
	}
}

func TestNewEmbedder_DefaultsTargetLocalOllama(t *testing.T) {
	e, err := newEmbedder(nil)
	if err != nil {
		t.Fatalf("newEmbedder(nil): %v", err)
	}
	emb := e.(*embedder)
	if emb.Model() != "nomic-embed-text" {
		t.Errorf("default Model=%q", emb.Model())
	}
	if emb.Dimensions() != 768 {
		t.Errorf("default Dimensions=%d", emb.Dimensions())
	}
	if emb.cfg.BaseURL != "http://localhost:11434/v1" {
		t.Errorf("default BaseURL=%q", emb.cfg.BaseURL)
	}
	if emb.cfg.APIKey != "" {
		t.Errorf("default APIKey should be empty, got %q", emb.cfg.APIKey)
	}
}

func TestNewEmbedder_InvalidTimeoutRejected(t *testing.T) {
	_, err := newEmbedder(json.RawMessage(`{"timeout":"not-a-duration"}`))
	if err == nil || !strings.Contains(err.Error(), "invalid timeout") {
		t.Errorf("want invalid-timeout error, got %v", err)
	}
}

func TestNewEmbedder_PartialConfigKeepsDefaults(t *testing.T) {
	e, err := newEmbedder(json.RawMessage(`{"model":"text-embedding-3-small"}`))
	if err != nil {
		t.Fatalf("newEmbedder: %v", err)
	}
	emb := e.(*embedder)
	if emb.Model() != "text-embedding-3-small" {
		t.Errorf("Model=%q", emb.Model())
	}
	if emb.cfg.BaseURL != "http://localhost:11434/v1" {
		t.Errorf("BaseURL=%q (should fall back to default when unset)", emb.cfg.BaseURL)
	}
}
