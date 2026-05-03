package plugins

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeAssistantTransformer wraps the embedded dummyPlugin so tests
// can attach an AssistantContentTransformer to a Pipeline without
// depending on a registered concrete plugin.
type fakeAssistantTransformer struct {
	dummyPlugin
	prefix, suffix string
}

func (f *fakeAssistantTransformer) TransformAssistantContent(content string) string {
	return f.prefix + content + f.suffix
}

func TestPipeline_TransformAssistantContent_AppliesInOrder(t *testing.T) {
	t.Parallel()
	p := Pipeline{
		&fakeAssistantTransformer{dummyPlugin: dummyPlugin{name: "wrapA"}, prefix: "[A]", suffix: "[/A]"},
		&fakeAssistantTransformer{dummyPlugin: dummyPlugin{name: "wrapB"}, prefix: "<B>", suffix: "</B>"},
	}
	got := p.TransformAssistantContent("hello")
	want := "<B>[A]hello[/A]</B>"
	if got != want {
		t.Errorf("ordering / composition wrong:\n  got:  %q\n  want: %q", got, want)
	}
}

func TestPipeline_TransformAssistantContent_SkipsNonImplementers(t *testing.T) {
	t.Parallel()
	// dummyPlugin alone doesn't implement AssistantContentTransformer
	// — the pipeline should pass through unchanged rather than panic.
	p := Pipeline{
		&dummyPlugin{name: "passive"},
		&fakeAssistantTransformer{dummyPlugin: dummyPlugin{name: "tag"}, prefix: "<", suffix: ">"},
	}
	got := p.TransformAssistantContent("x")
	if got != "<x>" {
		t.Errorf("non-implementing plugins must be skipped, got %q", got)
	}
}

func TestPipeline_TransformAssistantContent_EmptyPipelinePassesThrough(t *testing.T) {
	t.Parallel()
	var p Pipeline
	got := p.TransformAssistantContent("untouched")
	if got != "untouched" {
		t.Errorf("empty pipeline must pass content through unchanged, got %q", got)
	}
}

// fakeLifecycleRecorder captures every PersistedMessage it receives,
// behind a mutex so the test can read it after the goroutines flush.
// One concrete recorder is used to assert ordering / fan-out / safety.
type fakeLifecycleRecorder struct {
	dummyPlugin
	mu       sync.Mutex
	received []PersistedMessage
	delay    time.Duration
}

func (f *fakeLifecycleRecorder) OnMessagePersisted(_ context.Context, m PersistedMessage) {
	if f.delay > 0 {
		time.Sleep(f.delay)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.received = append(f.received, m)
}

func (f *fakeLifecycleRecorder) snapshot() []PersistedMessage {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]PersistedMessage, len(f.received))
	copy(out, f.received)
	return out
}

// fakeLifecyclePanicker panics on every invocation; lets us check
// FireMessagePersisted recovers cleanly so one bad plugin can't kill
// the goroutine pool.
type fakeLifecyclePanicker struct {
	dummyPlugin
	called atomic.Bool
}

func (f *fakeLifecyclePanicker) OnMessagePersisted(_ context.Context, _ PersistedMessage) {
	f.called.Store(true)
	panic("plugin gone wrong")
}

func TestPipeline_FireMessagePersisted_FansOutToAllHooks(t *testing.T) {
	t.Parallel()
	a := &fakeLifecycleRecorder{dummyPlugin: dummyPlugin{name: "a"}}
	b := &fakeLifecycleRecorder{dummyPlugin: dummyPlugin{name: "b"}}
	p := Pipeline{a, b, &dummyPlugin{name: "passive"}}

	msg := PersistedMessage{ID: "msg-1", ContextID: "ctx-1", Role: "user", Content: "hi"}
	p.FireMessagePersisted(context.Background(), msg, slog.New(slog.NewTextHandler(io.Discard, nil)))

	// Hooks run in detached goroutines — wait briefly for both to
	// flush. 200ms is generous; on a healthy machine they finish
	// in microseconds.
	deadline := time.Now().Add(200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if len(a.snapshot()) > 0 && len(b.snapshot()) > 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if got := a.snapshot(); len(got) != 1 || got[0].ID != "msg-1" {
		t.Errorf("recorder a: expected one msg-1, got %v", got)
	}
	if got := b.snapshot(); len(got) != 1 || got[0].ID != "msg-1" {
		t.Errorf("recorder b: expected one msg-1, got %v", got)
	}
}

func TestPipeline_FireMessagePersisted_RecoversFromPanic(t *testing.T) {
	t.Parallel()
	bad := &fakeLifecyclePanicker{dummyPlugin: dummyPlugin{name: "bad"}}
	good := &fakeLifecycleRecorder{dummyPlugin: dummyPlugin{name: "good"}}
	p := Pipeline{bad, good}

	msg := PersistedMessage{ID: "msg-1"}
	p.FireMessagePersisted(context.Background(), msg, slog.New(slog.NewTextHandler(io.Discard, nil)))

	// Both goroutines should run; the panicker's recovery must not
	// affect the well-behaved hook.
	deadline := time.Now().Add(200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if bad.called.Load() && len(good.snapshot()) > 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !bad.called.Load() {
		t.Error("panicker should have been invoked")
	}
	if got := good.snapshot(); len(got) != 1 {
		t.Errorf("good hook should have received the msg even though sibling panicked, got %d", len(got))
	}
}

func TestPipeline_FireMessagePersisted_NilLoggerOK(t *testing.T) {
	t.Parallel()
	// A nil logger is allowed — the panic-recovery path silently
	// swallows the panic when there's no logger to report to. Test
	// confirms no crash.
	bad := &fakeLifecyclePanicker{dummyPlugin: dummyPlugin{name: "bad"}}
	p := Pipeline{bad}
	p.FireMessagePersisted(context.Background(), PersistedMessage{ID: "x"}, nil)
	deadline := time.Now().Add(100 * time.Millisecond)
	for time.Now().Before(deadline) {
		if bad.called.Load() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Error("panicker did not run")
}

func TestDescribe_DetectsNewCapabilities(t *testing.T) {
	t.Parallel()
	// Register a one-off plugin implementing both new interfaces so
	// Describe detects them. Use a unique name so re-running the
	// suite doesn't trip the duplicate-Register panic.
	name := "cap_test_" + time.Now().Format("150405.000000000")
	Register(name, func(_ json.RawMessage) (Plugin, error) {
		return &capProbe{name: name}, nil
	})
	desc, err := Describe(name)
	if err != nil {
		t.Fatalf("Describe: %v", err)
	}
	if !desc.Capabilities.AssistantContentTransformer {
		t.Error("AssistantContentTransformer not detected")
	}
	if !desc.Capabilities.MessageLifecycleHook {
		t.Error("MessageLifecycleHook not detected")
	}
}

type capProbe struct {
	name string
}

func (c *capProbe) Name() string                                       { return c.name }
func (c *capProbe) DisplayName() string                                { return c.name }
func (c *capProbe) Description() string                                { return "test" }
func (c *capProbe) TransformAssistantContent(s string) string          { return s }
func (c *capProbe) OnMessagePersisted(context.Context, PersistedMessage) {}
