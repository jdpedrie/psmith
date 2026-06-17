package conversations

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/spalt/internal/devicetools"
)

// TestNewDeviceToolBinding_NilOnMissingDeps verifies the
// constructor short-circuits when either dependency is nil — the
// conversations service relies on this for the "device tools
// disabled" path (registry/broker can be wired or not; nil cleanly
// means "feature off").
func TestNewDeviceToolBinding_NilOnMissingDeps(t *testing.T) {
	t.Parallel()
	registry := devicetools.NewRegistry()
	broker := devicetools.NewBroker()

	if got := newDeviceToolBinding(nil, registry, uuid.New(), uuid.New(), nil); got != nil {
		t.Errorf("nil broker should yield nil binding; got %#v", got)
	}
	if got := newDeviceToolBinding(broker, nil, uuid.New(), uuid.New(), nil); got != nil {
		t.Errorf("nil registry should yield nil binding; got %#v", got)
	}
}

// TestDeviceToolBinding_Invoke routes through the real broker —
// the test plays the role of "client" by Respond'ing to whatever
// the broker emits.
func TestDeviceToolBinding_Invoke_HappyPath(t *testing.T) {
	t.Parallel()
	registry := devicetools.NewRegistry()
	broker := devicetools.NewBroker()
	user := uuid.New()
	conv := uuid.New()

	var emitted devicetools.Request
	var emittedMu sync.Mutex
	emit := func(req devicetools.Request) {
		emittedMu.Lock()
		emitted = req
		emittedMu.Unlock()
	}

	b := newDeviceToolBinding(broker, registry, user, conv, emit)
	if b == nil {
		t.Fatal("binding should be non-nil with both deps")
	}

	// Play the client side from a goroutine that watches for the
	// emit to land + responds with structured output.
	done := make(chan struct{})
	go func() {
		defer close(done)
		// Spin until emit captures the call id (Invoke registers
		// + emits in quick succession).
		for {
			emittedMu.Lock()
			id := emitted.CallID
			emittedMu.Unlock()
			if id != uuid.Nil {
				_ = broker.Respond(conv, id, devicetools.Response{
					Output: json.RawMessage(`{"ok":true}`),
				})
				return
			}
		}
	}()

	out, err := b.Invoke(context.Background(), "calendar_list_events",
		json.RawMessage(`{"start_date":"2026-06-07"}`))
	if err != nil {
		t.Fatalf("Invoke: %v", err)
	}
	if string(out) != `{"ok":true}` {
		t.Errorf("Invoke output=%s", out)
	}
	<-done

	// Confirm conv id rode through the emit faithfully.
	emittedMu.Lock()
	defer emittedMu.Unlock()
	if emitted.ToolName != "calendar_list_events" {
		t.Errorf("emitted.ToolName=%q", emitted.ToolName)
	}
}

// TestDeviceToolBinding_SupportedTools_PreferPerConvOverNil
// confirms the registry-walk shape: per-(user, conv) entry wins
// over the (user, nil-conv) fallback so future per-conversation
// registration takes precedence cleanly.
func TestDeviceToolBinding_SupportedTools_PreferPerConvOverNil(t *testing.T) {
	t.Parallel()
	registry := devicetools.NewRegistry()
	broker := devicetools.NewBroker()
	user := uuid.New()
	conv := uuid.New()

	// Register both: the per-conv set has obsidian; the per-user
	// fallback has only calendar. Binding should report the
	// per-conv set (preferred).
	registry.Register(user, conv, []string{"obsidian_read_note"}, nil)
	registry.Register(user, uuid.Nil, []string{"calendar_list_events"}, nil)

	b := newDeviceToolBinding(broker, registry, user, conv, nil)
	got := b.SupportedTools(context.Background())
	if _, ok := got["obsidian_read_note"]; !ok {
		t.Errorf("expected per-conv obsidian; got %v", got)
	}
	if _, ok := got["calendar_list_events"]; ok {
		t.Errorf("per-conv should mask per-user fallback; got %v", got)
	}
}

// TestDeviceToolBinding_SupportedTools_FallsBackToNilConv
// confirms the (user, nil) fallback when no per-conv entry exists
// — covers the current iOS handshake which only knows about the
// user at register-time.
func TestDeviceToolBinding_SupportedTools_FallsBackToNilConv(t *testing.T) {
	t.Parallel()
	registry := devicetools.NewRegistry()
	broker := devicetools.NewBroker()
	user := uuid.New()
	conv := uuid.New()

	// Only the per-user fallback is registered.
	registry.Register(user, uuid.Nil, []string{"calendar_list_events"}, nil)

	b := newDeviceToolBinding(broker, registry, user, conv, nil)
	got := b.SupportedTools(context.Background())
	if _, ok := got["calendar_list_events"]; !ok {
		t.Errorf("expected fallback to nil-conv set; got %v", got)
	}
}

// TestDeviceToolBinding_SupportedTools_EmptyWhenNoneRegistered
// confirms the empty-string path — used by the app_tools plugin
// to gate "no client has registered" silently.
func TestDeviceToolBinding_SupportedTools_EmptyWhenNoneRegistered(t *testing.T) {
	t.Parallel()
	registry := devicetools.NewRegistry()
	broker := devicetools.NewBroker()
	b := newDeviceToolBinding(broker, registry, uuid.New(), uuid.New(), nil)
	if got := b.SupportedTools(context.Background()); got != nil {
		t.Errorf("empty registry should yield nil supported set; got %v", got)
	}
}
