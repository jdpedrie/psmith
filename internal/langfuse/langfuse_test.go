package langfuse

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// captureServer accepts ingestion POSTs and records their bodies
// + auth headers for assertion.
type captureServer struct {
	t       *testing.T
	server  *httptest.Server
	mu      sync.Mutex
	bodies  [][]byte
	auth    []string
	count   atomic.Int32
	respond int // status code; 0 → 200
}

func newCaptureServer(t *testing.T) *captureServer {
	t.Helper()
	cs := &captureServer{t: t}
	cs.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		cs.mu.Lock()
		cs.bodies = append(cs.bodies, body)
		cs.auth = append(cs.auth, r.Header.Get("Authorization"))
		cs.mu.Unlock()
		cs.count.Add(1)
		status := cs.respond
		if status == 0 {
			status = 200
		}
		w.WriteHeader(status)
	}))
	t.Cleanup(cs.server.Close)
	return cs
}

func (cs *captureServer) waitFor(n int32, d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cs.count.Load() >= n {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

func TestEmitter_DropsEventsForUnconfiguredUser(t *testing.T) {
	t.Parallel()
	cs := newCaptureServer(t)
	e := NewEmitter(slog.Default(), EmitterConfig{
		FlushInterval: 20 * time.Millisecond,
	})
	defer e.Stop(context.Background())

	// No SetUserConfig call — emit should silently drop.
	e.EmitTurn("user-without-config", Trace{ID: "t1", Name: "x"}, Generation{ID: "g1", TraceID: "t1"})

	if cs.waitFor(1, 200*time.Millisecond) {
		t.Fatalf("server received %d POSTs; expected 0 for unconfigured user", cs.count.Load())
	}
}

func TestEmitter_RoutesByUserCredentials(t *testing.T) {
	t.Parallel()
	cs := newCaptureServer(t)
	e := NewEmitter(slog.Default(), EmitterConfig{
		FlushInterval:  20 * time.Millisecond,
		FlushBatchSize: 100,
	})
	defer e.Stop(context.Background())

	e.SetUserConfig("user-a", Config{
		Host:      cs.server.URL,
		PublicKey: "pk-a",
		SecretKey: "sk-a",
		Enabled:   true,
	})
	e.SetUserConfig("user-b", Config{
		Host:      cs.server.URL,
		PublicKey: "pk-b",
		SecretKey: "sk-b",
		Enabled:   true,
	})

	e.EmitTurn("user-a", Trace{ID: "ta", Name: "a"}, Generation{ID: "ga", TraceID: "ta"})
	e.EmitTurn("user-b", Trace{ID: "tb", Name: "b"}, Generation{ID: "gb", TraceID: "tb"})

	if !cs.waitFor(2, 1*time.Second) {
		t.Fatalf("expected 2 POSTs (one per user batch), got %d", cs.count.Load())
	}

	cs.mu.Lock()
	defer cs.mu.Unlock()
	// Each POST should carry exactly that user's basic-auth header.
	saw := map[string]bool{}
	for _, a := range cs.auth {
		saw[a] = true
	}
	if !saw["Basic cGstYTpzay1h"] || !saw["Basic cGstYjpzay1i"] { // base64 of pk-a:sk-a / pk-b:sk-b
		t.Errorf("expected both users' Authorization headers, got %v", cs.auth)
	}
}

func TestEmitter_BatchesEventsBeforeFlush(t *testing.T) {
	t.Parallel()
	cs := newCaptureServer(t)
	e := NewEmitter(slog.Default(), EmitterConfig{
		// Long interval so the batch fills before the timer fires.
		FlushInterval:  10 * time.Second,
		FlushBatchSize: 4, // not consulted by the current flush impl, but kept for shape
	})
	defer e.Stop(context.Background())

	e.SetUserConfig("user", Config{
		Host: cs.server.URL, PublicKey: "pk", SecretKey: "sk", Enabled: true,
	})

	for i := 0; i < 5; i++ {
		e.EmitTurn("user",
			Trace{ID: "t", Name: "x"},
			Generation{ID: "g", TraceID: "t"})
	}

	// Force a flush via Stop instead of waiting for the ticker.
	e.Stop(context.Background())

	if cs.count.Load() == 0 {
		t.Fatalf("expected ≥1 batch POST after Stop, got 0")
	}
	cs.mu.Lock()
	defer cs.mu.Unlock()
	if len(cs.bodies) == 0 {
		t.Fatalf("no body captured")
	}
	// Confirm the batched envelope contains both event types.
	var env struct {
		Batch []struct {
			Type string `json:"type"`
		} `json:"batch"`
	}
	if err := json.Unmarshal(cs.bodies[0], &env); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	hasTrace, hasGen := false, false
	for _, b := range env.Batch {
		if b.Type == "trace-create" {
			hasTrace = true
		}
		if b.Type == "generation-create" {
			hasGen = true
		}
	}
	if !hasTrace || !hasGen {
		t.Errorf("expected both trace-create + generation-create in batch, got %+v", env.Batch)
	}
}

func TestEmitter_StopFlushesPendingEvents(t *testing.T) {
	t.Parallel()
	cs := newCaptureServer(t)
	e := NewEmitter(slog.Default(), EmitterConfig{
		// Very long ticker — only Stop should cause the flush.
		FlushInterval: 1 * time.Hour,
	})

	e.SetUserConfig("u", Config{
		Host: cs.server.URL, PublicKey: "pk", SecretKey: "sk", Enabled: true,
	})
	e.EmitTurn("u", Trace{ID: "t1"}, Generation{ID: "g1", TraceID: "t1"})

	// Without Stop, nothing flushes for an hour. With Stop, we get
	// the POST before the call returns.
	e.Stop(context.Background())

	if cs.count.Load() != 1 {
		t.Errorf("expected 1 POST after Stop, got %d", cs.count.Load())
	}
}

func TestEmitter_DisabledConfigSkipsEmit(t *testing.T) {
	t.Parallel()
	cs := newCaptureServer(t)
	e := NewEmitter(slog.Default(), EmitterConfig{
		FlushInterval: 20 * time.Millisecond,
	})
	defer e.Stop(context.Background())

	e.SetUserConfig("u", Config{
		Host: cs.server.URL, PublicKey: "pk", SecretKey: "sk", Enabled: false,
	})
	e.EmitTurn("u", Trace{ID: "t"}, Generation{ID: "g", TraceID: "t"})

	if cs.waitFor(1, 200*time.Millisecond) {
		t.Errorf("expected 0 POSTs when disabled, got %d", cs.count.Load())
	}
}

func TestEmitter_HTTPErrorIsLoggedNotFatal(t *testing.T) {
	t.Parallel()
	cs := newCaptureServer(t)
	cs.respond = 500
	e := NewEmitter(slog.Default(), EmitterConfig{
		FlushInterval: 20 * time.Millisecond,
	})
	defer e.Stop(context.Background())

	e.SetUserConfig("u", Config{
		Host: cs.server.URL, PublicKey: "pk", SecretKey: "sk", Enabled: true,
	})
	e.EmitTurn("u", Trace{ID: "t"}, Generation{ID: "g", TraceID: "t"})

	if !cs.waitFor(1, 1*time.Second) {
		t.Fatalf("expected POST attempt; server saw %d", cs.count.Load())
	}
	// Subsequent emits should still flow — emitter must not enter a
	// permanent error state on a single 500.
	e.EmitTurn("u", Trace{ID: "t2"}, Generation{ID: "g2", TraceID: "t2"})
	if !cs.waitFor(2, 1*time.Second) {
		t.Errorf("emitter stopped accepting after 500; got %d POSTs", cs.count.Load())
	}
}

func TestConfigValid(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		cfg  Config
		want bool
	}{
		{"zero", Config{}, false},
		{"disabled", Config{Host: "h", PublicKey: "p", SecretKey: "s", Enabled: false}, false},
		{"missing key", Config{Host: "h", PublicKey: "p", Enabled: true}, false},
		{"complete", Config{Host: "h", PublicKey: "p", SecretKey: "s", Enabled: true}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.cfg.Valid(); got != c.want {
				t.Errorf("Valid() = %v, want %v", got, c.want)
			}
		})
	}
}
