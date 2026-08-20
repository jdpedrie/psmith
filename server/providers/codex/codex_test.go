package codex

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/codexsdk"
	"github.com/jdpedrie/psmith/server/providers"
)

func newDriver(t *testing.T, cfg string) *Driver {
	t.Helper()
	p, err := New(providers.Deps{}, json.RawMessage(cfg))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return p.(*Driver)
}

// --- Handles ---------------------------------------------------------------

// The handle names a THREAD AT A TURN, not just a thread. That third part is
// the whole reason this driver differs from claudecode: forking with it
// branches exactly at that message rather than at the thread's tip.
func TestHandle_RoundTripsModelThreadAndTurn(t *testing.T) {
	d := newDriver(t, `{}`)
	h := encodeHandle("gpt-x", "thread-1", "turn-7")
	got, err := d.resolveHandle(h)
	if err != nil {
		t.Fatalf("resolveHandle: %v", err)
	}
	if got.model != "gpt-x" || got.threadID != "thread-1" || got.turnID != "turn-7" {
		t.Errorf("round trip lost data: %+v", got)
	}
}

// A thread whose turn id never arrived still has to be forkable, from the tip.
func TestHandle_ToleratesAnEmptyTurnID(t *testing.T) {
	d := newDriver(t, `{}`)
	got, err := d.resolveHandle(encodeHandle("m", "thread-1", ""))
	if err != nil {
		t.Fatalf("an empty turn id must still resolve: %v", err)
	}
	if got.threadID != "thread-1" || got.turnID != "" {
		t.Errorf("unexpected setup: %+v", got)
	}
}

func TestHandle_RejectsGarbage(t *testing.T) {
	d := newDriver(t, `{}`)
	for _, h := range []string{"", "nonsense", "codex-v1:only-one", "codex-v1:m:t", "codex-prov-v1:never-registered"} {
		if _, err := d.resolveHandle(h); err == nil {
			t.Errorf("expected %q to be rejected", h)
		}
	}
}

// A model id containing ':' would break the handle encoding, so it is refused
// at StartSession rather than producing a handle that cannot be parsed back.
func TestStartSession_RejectsAModelIDWithAColon(t *testing.T) {
	d := newDriver(t, `{}`)
	if _, err := d.StartSession(t.Context(), "bad:model", providers.SessionConfig{}); err == nil {
		t.Error("expected a colon in the model id to be rejected")
	}
}

func TestStartSession_FallsBackToTheConfiguredModel(t *testing.T) {
	d := newDriver(t, `{"default_model":"gpt-default"}`)
	h, err := d.StartSession(t.Context(), "", providers.SessionConfig{SystemPrompt: "be nice"})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	setup, err := d.resolveHandle(h)
	if err != nil {
		t.Fatalf("resolveHandle: %v", err)
	}
	if setup.model != "gpt-default" {
		t.Errorf("model = %q, want the configured default", setup.model)
	}
	if setup.baseInstructions != "be nice" {
		t.Errorf("system prompt not carried: %q", setup.baseInstructions)
	}
}

// StartSession must not create a thread upstream: a conversation the user
// abandons before their first message would otherwise litter their Codex
// history with an empty thread.
func TestStartSession_DoesNotSpawnTheSubprocess(t *testing.T) {
	d := newDriver(t, `{"cli_path":"/nonexistent/codex"}`)
	if _, err := d.StartSession(t.Context(), "m", providers.SessionConfig{}); err != nil {
		t.Fatalf("StartSession should not need the binary: %v", err)
	}
	d.mu.Lock()
	spawned := d.client != nil
	d.mu.Unlock()
	if spawned {
		t.Error("StartSession spawned an app-server; it should be lazy")
	}
}

func TestTerminateSession_ForgetsProvisionalSetup(t *testing.T) {
	d := newDriver(t, `{}`)
	h, _ := d.StartSession(t.Context(), "m", providers.SessionConfig{})
	if err := d.TerminateSession(t.Context(), h); err != nil {
		t.Fatalf("TerminateSession: %v", err)
	}
	if _, err := d.resolveHandle(h); err == nil {
		t.Error("a terminated provisional handle should no longer resolve")
	}
}

// A durable handle has no driver-side state, so terminating one must leave it
// forkable: Codex's threads stay on disk and history stays branchable.
func TestTerminateSession_LeavesDurableHandlesResolvable(t *testing.T) {
	d := newDriver(t, `{}`)
	h := encodeHandle("m", "thread-1", "turn-1")
	_ = d.TerminateSession(t.Context(), h)
	if _, err := d.resolveHandle(h); err != nil {
		t.Errorf("durable handle stopped resolving after terminate: %v", err)
	}
}

// --- Send guards -----------------------------------------------------------

func TestSendInSession_RejectsNonUserAndEmpty(t *testing.T) {
	d := newDriver(t, `{}`)
	h := encodeHandle("m", "t", "turn")
	if _, err := d.SendInSession(t.Context(), h, providers.WireMessage{Role: "assistant", Content: "x"}, providers.CallSettings{}); err == nil {
		t.Error("assistant messages should be refused")
	}
	if _, err := d.SendInSession(t.Context(), h, providers.WireMessage{Role: "user"}, providers.CallSettings{}); err == nil {
		t.Error("empty content should be refused")
	}
}

// --- Usage -----------------------------------------------------------------

// Codex's input count already includes the cached portion, matching Psmith's
// shape, so the two map across without adjustment. Subtracting would
// double-count the saving the cost engine computes itself.
func TestUsagePayload_MapsCountsWithoutAdjustment(t *testing.T) {
	payload := usagePayload(codexsdk.Usage{
		InputTokens: 100, CachedInputTokens: 40, OutputTokens: 7, ReasoningTokens: 3,
	})
	var u providers.Usage
	if err := json.Unmarshal(payload, &u); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if u.InputTokens == nil || *u.InputTokens != 100 {
		t.Errorf("input = %v, want 100 (unadjusted)", u.InputTokens)
	}
	if u.CacheReadTokens == nil || *u.CacheReadTokens != 40 {
		t.Errorf("cacheRead = %v, want 40", u.CacheReadTokens)
	}
	if u.OutputTokens == nil || *u.OutputTokens != 7 {
		t.Errorf("output = %v", u.OutputTokens)
	}
	if u.ReasoningTokens == nil || *u.ReasoningTokens != 3 {
		t.Errorf("reasoning = %v", u.ReasoningTokens)
	}
	if u.ProviderRaw == nil {
		t.Error("raw usage should be preserved for forensics")
	}
}

// Reasoning is omitted rather than reported as zero, so a model that does not
// reason is distinguishable from one that reasoned for free.
func TestUsagePayload_OmitsZeroReasoning(t *testing.T) {
	payload := usagePayload(codexsdk.Usage{InputTokens: 1, OutputTokens: 1})
	if strings.Contains(string(payload), "reasoning_tokens") {
		t.Errorf("zero reasoning should be omitted: %s", payload)
	}
}

// --- Interface ---------------------------------------------------------------

// The signature hazard that has bitten repeatedly in this codebase: a method
// with the wrong shape silently stops satisfying the interface and the runtime
// skips the driver entirely.
var _ providers.StatefulProvider = (*Driver)(nil)
