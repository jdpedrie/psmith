package google

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/providers"
)

// ---------- Test fakes ---------------------------------------------------

// fakeCatalog is a minimal modelmeta.Catalog stub used by discover_test.go
// and the constructor tests.
type fakeCatalog struct {
	models map[string]*modelmeta.Model
}

func (f *fakeCatalog) LookupModel(_ context.Context, _, modelID string) (*modelmeta.Model, error) {
	if m, ok := f.models[modelID]; ok {
		return m, nil
	}
	return nil, modelmeta.ErrNotFound
}

func (f *fakeCatalog) LookupProvider(_ context.Context, _ string) (*modelmeta.Provider, error) {
	return nil, modelmeta.ErrNotFound
}

func (f *fakeCatalog) ListProviders(_ context.Context) ([]modelmeta.Provider, error) {
	return nil, nil
}

func (f *fakeCatalog) ListModelsByProvider(_ context.Context, _ string) ([]modelmeta.Model, error) {
	return nil, nil
}

func (f *fakeCatalog) Refresh(_ context.Context) error { return nil }

func (f *fakeCatalog) Status(_ context.Context) (modelmeta.Status, error) {
	return modelmeta.Status{}, nil
}

// validConfig returns a json.RawMessage that satisfies New's required fields.
func validConfig(t *testing.T) json.RawMessage {
	t.Helper()
	cfg := Config{APIKey: "test-key"}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal cfg: %v", err)
	}
	return raw
}

// newDriverWithBaseURL constructs a Driver pointed at the given base URL,
// satisfying the providers.StatelessProvider interface.
func newDriverWithBaseURL(t *testing.T, baseURL string, deps providers.Deps) *Driver {
	t.Helper()
	p, err := New(deps, validConfig(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	d := p.(*Driver)
	d.baseURL = baseURL
	return d
}

// ---------- New() --------------------------------------------------------

func TestNew_Valid(t *testing.T) {
	cfg := validConfig(t)
	p, err := New(providers.Deps{}, cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if p.Type() != "google" {
		t.Errorf("Type=%q want google", p.Type())
	}
	if p.Stateful() {
		t.Errorf("Stateful=true want false")
	}
}

func TestNew_MissingAPIKey(t *testing.T) {
	cfg := json.RawMessage(`{}`)
	if _, err := New(providers.Deps{}, cfg); err == nil ||
		!strings.Contains(err.Error(), "api_key") {
		t.Errorf("expected api_key error, got %v", err)
	}
}

func TestNew_EmptyConfig(t *testing.T) {
	if _, err := New(providers.Deps{}, nil); err == nil {
		t.Error("expected error for nil config (api_key missing)")
	}
	if _, err := New(providers.Deps{}, json.RawMessage{}); err == nil {
		t.Error("expected error for empty config (api_key missing)")
	}
}

func TestNew_InvalidJSON(t *testing.T) {
	cfg := json.RawMessage(`{"api_key":`)
	if _, err := New(providers.Deps{}, cfg); err == nil {
		t.Error("expected JSON parse error")
	}
}

// ---------- Registry round trip ------------------------------------------

func TestRegistry_BuildGoogle(t *testing.T) {
	cfg := validConfig(t)
	p, err := providers.Build("google", providers.Deps{}, cfg)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if p == nil {
		t.Fatal("Build returned nil provider")
	}
	if p.Type() != "google" {
		t.Errorf("Type=%q want google", p.Type())
	}
	if _, ok := p.(providers.StatelessProvider); !ok {
		t.Error("driver should satisfy StatelessProvider")
	}
	if _, ok := p.(providers.TokenCounter); !ok {
		t.Error("driver should satisfy TokenCounter")
	}
}

// ---------- RenderThinkingToText() ---------------------------------------

func TestRenderThinkingToText(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"nil", "", ""},
		{"empty-string", `""`, ""},
		{"object-array-canonical", `[{"type":"text","text":"first"},{"type":"text","text":"second"}]`, "first\n\nsecond"},
		{"object-array-no-type", `[{"text":"a"},{"text":"b"}]`, "a\n\nb"},
		{"string-array", `["thought a","thought b"]`, "thought a\n\nthought b"},
		{"single-text-object", `{"text":"alone"}`, "alone"},
		{"malformed", `{not json}`, ""},
		{"unknown-shape", `{"foo":"bar"}`, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := RenderThinkingToText(json.RawMessage(c.in))
			if got != c.want {
				t.Errorf("got %q want %q", got, c.want)
			}
		})
	}
}

func TestRenderThinkingToText_NoPanicOnNil(t *testing.T) {
	var d Driver
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("panic on nil thinking: %v", r)
		}
	}()
	if got := d.RenderThinkingToText(nil); got != "" {
		t.Errorf("nil thinking: got %q want empty", got)
	}
}

// ---------- Helpers -----------------------------------------------------

// captureRequest mounts an SSE handler at path that records the request
// body and emits the canned terminator. Returns server + pointer to the
// captured body string (stable after server close).
func captureRequest(t *testing.T, path string, terminator string) (*httptest.Server, *string) {
	t.Helper()
	var captured string
	mux := http.NewServeMux()
	mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 256*1024)
		n, _ := r.Body.Read(buf)
		captured = string(buf[:n])
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(terminator))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &captured
}

// Compile-time interface checks.
var (
	_ providers.Provider          = (*Driver)(nil)
	_ providers.StatelessProvider = (*Driver)(nil)
	_ providers.TokenCounter      = (*Driver)(nil)
)
