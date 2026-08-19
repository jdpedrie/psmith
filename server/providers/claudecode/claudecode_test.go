package claudecode

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/server/providers"
)

// newTestDriver builds a driver pinned to the fake CLI, with the argv log
// routed to a per-test file.
func newTestDriver(t *testing.T) (*Driver, func() []string) {
	t.Helper()
	fake, err := filepath.Abs("testdata/fake-claude")
	if err != nil {
		t.Fatal(err)
	}
	argsLog := filepath.Join(t.TempDir(), "args.log")
	t.Setenv("FAKE_CLAUDE_ARGS_LOG", argsLog)

	cfg, _ := json.Marshal(Config{CLIPath: fake})
	p, err := providers.Build("claude-code-subprocess", providers.Deps{}, cfg)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	d, ok := p.(*Driver)
	if !ok {
		t.Fatalf("Build returned %T, want *Driver", p)
	}
	readArgs := func() []string {
		b, err := os.ReadFile(argsLog)
		if err != nil {
			t.Fatalf("read args log: %v", err)
		}
		return strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	}
	return d, readArgs
}

// drain collects all chunks and decodes the interesting ones.
type turnResult struct {
	text    string
	handle  string
	usage   *providers.Usage
	errMsg  string
	gotDone bool
}

func drain(t *testing.T, ch <-chan providers.Chunk) turnResult {
	t.Helper()
	var r turnResult
	for c := range ch {
		switch c.Type {
		case providers.ChunkText:
			var p struct {
				Text string `json:"text"`
			}
			if err := json.Unmarshal(c.Payload, &p); err != nil {
				t.Fatalf("bad text payload: %v", err)
			}
			r.text += p.Text
		case providers.ChunkSessionHandle:
			var p struct {
				SessionID string `json:"session_id"`
			}
			if err := json.Unmarshal(c.Payload, &p); err != nil {
				t.Fatalf("bad handle payload: %v", err)
			}
			r.handle = p.SessionID
		case providers.ChunkUsage:
			var u providers.Usage
			if err := json.Unmarshal(c.Payload, &u); err != nil {
				t.Fatalf("bad usage payload: %v", err)
			}
			r.usage = &u
		case providers.ChunkError:
			var p struct {
				Message string `json:"message"`
			}
			_ = json.Unmarshal(c.Payload, &p)
			r.errMsg = p.Message
		case providers.ChunkDone:
			r.gotDone = true
		}
		if c.Payload == nil {
			t.Errorf("chunk %s has nil payload", c.Type)
		}
	}
	return r
}

func hasFlagPair(args []string, flag, value string) bool {
	for i, a := range args {
		if a == flag && i+1 < len(args) && args[i+1] == value {
			return true
		}
	}
	return false
}

func hasFlag(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func TestCreationTurn(t *testing.T) {
	d, readArgs := newTestDriver(t)
	ctx := context.Background()

	handle, err := d.StartSession(ctx, "haiku", providers.SessionConfig{SystemPrompt: "You are terse."})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if !strings.HasPrefix(handle, provisionalPrefix) {
		t.Fatalf("StartSession handle = %q, want %s prefix", handle, provisionalPrefix)
	}

	ch, err := d.SendInSession(ctx, handle, providers.WireMessage{Role: "user", Content: "hello"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession: %v", err)
	}
	r := drain(t, ch)

	if r.errMsg != "" {
		t.Fatalf("unexpected error chunk: %s", r.errMsg)
	}
	if r.text != "echo: hello" {
		t.Errorf("text = %q, want %q", r.text, "echo: hello")
	}
	if !strings.HasPrefix(r.handle, durablePrefix+"haiku:created-") {
		t.Errorf("handle = %q, want %shaiku:created-*", r.handle, durablePrefix)
	}
	if !r.gotDone {
		t.Error("no done chunk")
	}
	if r.usage == nil || r.usage.InputTokens == nil || *r.usage.InputTokens != 11 || *r.usage.OutputTokens != 7 {
		t.Errorf("usage = %+v, want input 11 / output 7", r.usage)
	}

	args := readArgs()
	if !hasFlagPair(args, "--system-prompt", "You are terse.") {
		t.Errorf("creation turn missing --system-prompt: %v", args)
	}
	if !hasFlagPair(args, "--model", "haiku") {
		t.Errorf("creation turn missing --model haiku: %v", args)
	}
	if hasFlag(args, "--resume") || hasFlag(args, "--fork-session") {
		t.Errorf("creation turn must not resume or fork: %v", args)
	}
	if !hasFlagPair(args, "--tools", "") {
		t.Errorf("tools not disabled: %v", args)
	}

	// The provisional handle is consumed once the durable one lands.
	d.mu.Lock()
	_, still := d.pending[handle]
	d.mu.Unlock()
	if still {
		t.Error("provisional handle not cleared after creation turn")
	}
}

func TestResumeForksAndBranches(t *testing.T) {
	d, readArgs := newTestDriver(t)
	ctx := context.Background()

	parent := encodeHandle("haiku", "abc-123")
	ch, err := d.SendInSession(ctx, parent, providers.WireMessage{Role: "user", Content: "branch one"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession: %v", err)
	}
	r1 := drain(t, ch)

	args := readArgs()
	if !hasFlagPair(args, "--resume", "abc-123") {
		t.Errorf("resumed turn missing --resume abc-123: %v", args)
	}
	if !hasFlag(args, "--fork-session") {
		t.Errorf("resumed turn missing --fork-session: %v", args)
	}
	if hasFlag(args, "--system-prompt") {
		t.Errorf("resumed turn must not re-send the system prompt: %v", args)
	}
	if !strings.HasPrefix(r1.handle, durablePrefix+"haiku:fork-of-abc-123-") {
		t.Errorf("handle = %q, want fork-of-abc-123 lineage", r1.handle)
	}

	// A second send against the SAME parent handle forks independently:
	// same lineage, distinct model-encoded handle usable later.
	ch2, err := d.SendInSession(ctx, parent, providers.WireMessage{Role: "user", Content: "branch two"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession (second): %v", err)
	}
	r2 := drain(t, ch2)
	if !strings.HasPrefix(r2.handle, durablePrefix+"haiku:fork-of-abc-123-") {
		t.Errorf("second handle = %q, want fork-of-abc-123 lineage", r2.handle)
	}

	// Resuming a child handle decodes model and CLI id back out of it.
	rest := strings.TrimPrefix(r1.handle, durablePrefix+"haiku:")
	ch3, err := d.SendInSession(ctx, r1.handle, providers.WireMessage{Role: "user", Content: "deeper"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession (child): %v", err)
	}
	drain(t, ch3)
	args = readArgs()
	if !hasFlagPair(args, "--resume", rest) {
		t.Errorf("child turn resumed %v, want --resume %s", args, rest)
	}
}

func TestHarnessErrorBecomesErrorChunk(t *testing.T) {
	d, _ := newTestDriver(t)
	ctx := context.Background()

	ch, err := d.SendInSession(ctx, encodeHandle("haiku", "x"), providers.WireMessage{Role: "user", Content: "please FAIL"}, providers.CallSettings{})
	if err != nil {
		t.Fatalf("SendInSession: %v", err)
	}
	r := drain(t, ch)
	if r.errMsg != "synthetic failure" {
		t.Errorf("errMsg = %q, want %q", r.errMsg, "synthetic failure")
	}
	if r.gotDone {
		t.Error("error turn must not emit done")
	}
	if r.handle != "" {
		t.Errorf("error turn emitted handle %q", r.handle)
	}
}

func TestHandleValidation(t *testing.T) {
	d, _ := newTestDriver(t)
	ctx := context.Background()

	if _, err := d.SendInSession(ctx, "garbage", providers.WireMessage{Role: "user", Content: "hi"}, providers.CallSettings{}); err == nil {
		t.Error("garbage handle accepted")
	}
	if _, err := d.SendInSession(ctx, provisionalPrefix+"unknown", providers.WireMessage{Role: "user", Content: "hi"}, providers.CallSettings{}); err == nil {
		t.Error("unknown provisional handle accepted")
	}
	if _, err := d.SendInSession(ctx, encodeHandle("haiku", "x"), providers.WireMessage{Role: "assistant", Content: "hi"}, providers.CallSettings{}); err == nil {
		t.Error("assistant role accepted")
	}
	if _, err := d.StartSession(ctx, "week:end", providers.SessionConfig{}); err == nil {
		t.Error("model with colon accepted")
	}

	// TerminateSession clears provisional state and tolerates unknowns.
	h, err := d.StartSession(ctx, "haiku", providers.SessionConfig{})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.TerminateSession(ctx, h); err != nil {
		t.Fatal(err)
	}
	if _, err := d.SendInSession(ctx, h, providers.WireMessage{Role: "user", Content: "hi"}, providers.CallSettings{}); err == nil {
		t.Error("terminated provisional handle accepted")
	}
	if err := d.TerminateSession(ctx, "never-existed"); err != nil {
		t.Errorf("TerminateSession on unknown handle: %v", err)
	}
}

func TestDiscoverModels(t *testing.T) {
	d, _ := newTestDriver(t)
	models, err := d.DiscoverModels(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 3 {
		t.Fatalf("got %d models, want 3", len(models))
	}
	if models[0].ID != "sonnet" {
		t.Errorf("models[0].ID = %q", models[0].ID)
	}
	if !d.Stateful() {
		t.Error("Stateful() = false")
	}
	if d.Type() != "claude-code-subprocess" {
		t.Errorf("Type() = %q", d.Type())
	}
}
