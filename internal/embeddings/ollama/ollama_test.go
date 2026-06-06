package ollama

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeOllama is a stub that speaks `/api/embed` well enough to round-trip
// against the embedder. Tests pass an optional response shape per case.
func fakeOllama(t *testing.T, status int, body string, captureReq *embedRequest) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/embed" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Errorf("method=%s want POST", r.Method)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("Content-Type=%q", got)
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

func newWithEndpoint(t *testing.T, endpoint string, extras map[string]any) *embedder {
	t.Helper()
	cfg := map[string]any{
		"endpoint":   endpoint,
		"model":      "nomic-embed-text",
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
	srv := fakeOllama(t, http.StatusOK,
		`{"model":"nomic-embed-text","embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]]}`,
		&captured)

	e := newWithEndpoint(t, srv.URL, nil)
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
	if captured.Model != "nomic-embed-text" {
		t.Errorf("captured model=%q", captured.Model)
	}
	if len(captured.Input) != 2 || captured.Input[0] != "alpha" {
		t.Errorf("captured inputs=%v", captured.Input)
	}
}

func TestEmbed_EmptyInputReturnsNil(t *testing.T) {
	// No request should ever be made for an empty batch.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Error("server should not be called for empty input")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	e := newWithEndpoint(t, srv.URL, nil)
	out, err := e.Embed(context.Background(), nil)
	if err != nil {
		t.Fatalf("Embed nil: %v", err)
	}
	if out != nil {
		t.Errorf("expected nil out, got %v", out)
	}
}

func TestEmbed_DimensionMismatchSurfaces(t *testing.T) {
	// Model returns a 4-d vector but config says 3-d → loud failure
	// rather than persisting bad data.
	srv := fakeOllama(t, http.StatusOK,
		`{"embeddings":[[0.1,0.2,0.3,0.4]]}`, nil)
	e := newWithEndpoint(t, srv.URL, nil)
	_, err := e.Embed(context.Background(), []string{"x"})
	if err == nil || !strings.Contains(err.Error(), "dim 4") {
		t.Errorf("want dimension-mismatch error, got %v", err)
	}
}

func TestEmbed_CountMismatchSurfaces(t *testing.T) {
	// 2 inputs in, 1 vector out → loud failure (catches truncation
	// or a partial-success backend bug we don't want to silently
	// pad over).
	srv := fakeOllama(t, http.StatusOK,
		`{"embeddings":[[0.1,0.2,0.3]]}`, nil)
	e := newWithEndpoint(t, srv.URL, nil)
	_, err := e.Embed(context.Background(), []string{"a", "b"})
	if err == nil || !strings.Contains(err.Error(), "1 embeddings for 2 inputs") {
		t.Errorf("want count-mismatch error, got %v", err)
	}
}

func TestEmbed_ServerErrorPropagates(t *testing.T) {
	srv := fakeOllama(t, http.StatusNotFound,
		`{"error":"model not found"}`, nil)
	e := newWithEndpoint(t, srv.URL, nil)
	_, err := e.Embed(context.Background(), []string{"x"})
	if err == nil || !strings.Contains(err.Error(), "HTTP 404") {
		t.Errorf("want 404 surface, got %v", err)
	}
}

func TestNewEmbedder_DefaultsAreSensible(t *testing.T) {
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
	if emb.cfg.Endpoint != "http://localhost:11434" {
		t.Errorf("default Endpoint=%q", emb.cfg.Endpoint)
	}
}

func TestNewEmbedder_InvalidTimeoutRejected(t *testing.T) {
	_, err := newEmbedder(json.RawMessage(`{"timeout":"not-a-duration"}`))
	if err == nil || !strings.Contains(err.Error(), "invalid timeout") {
		t.Errorf("want invalid-timeout error, got %v", err)
	}
}

func TestNewEmbedder_PartialConfigKeepsDefaults(t *testing.T) {
	// User supplies only a model name; endpoint/dim/timeout fall back.
	e, err := newEmbedder(json.RawMessage(`{"model":"bge-large"}`))
	if err != nil {
		t.Fatalf("newEmbedder: %v", err)
	}
	emb := e.(*embedder)
	if emb.Model() != "bge-large" {
		t.Errorf("Model=%q", emb.Model())
	}
	if emb.cfg.Endpoint != "http://localhost:11434" {
		t.Errorf("Endpoint=%q", emb.cfg.Endpoint)
	}
	if emb.Dimensions() != 768 {
		t.Errorf("Dimensions=%d (defaults to 768, user must override for non-768 models)",
			emb.Dimensions())
	}
}
