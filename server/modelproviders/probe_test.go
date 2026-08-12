package modelproviders

import (
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/server/modelmeta"
	"github.com/jdpedrie/psmith/server/providers"
)

// --- The apply rule ---------------------------------------------------------

// Additive only. This is the property that makes the probe safe to run without
// reading the code first: it can help and cannot hurt.
func TestApply_TurnsCapabilitiesOnNeverOff(t *testing.T) {
	current := modelmeta.Capabilities{Vision: true, ToolUse: true}
	next, enabled := applyProbeResults(current, map[string]probeOutcome{
		"streaming": outcomeSupported,   // off → on
		"tool_use":  outcomeSupported,   // already on, no change reported
		"vision":    outcomeUnsupported, // claimed but refused: must NOT clear
		"thinking":  outcomeInconclusive,
	})
	if !next.Streaming {
		t.Error("a supported capability should be switched on")
	}
	if !next.Vision {
		t.Error("an unsupported verdict must never clear a flag")
	}
	if !next.ToolUse {
		t.Error("an already-on capability must stay on")
	}
	if next.Thinking {
		t.Error("inconclusive must not switch anything on")
	}
	if len(enabled) != 1 || enabled[0] != "streaming" {
		t.Errorf("enabled should list only what actually changed, got %v", enabled)
	}
}

func TestApply_SkippedChangesNothing(t *testing.T) {
	next, enabled := applyProbeResults(modelmeta.Capabilities{}, map[string]probeOutcome{
		"prompt_caching":   outcomeSkipped,
		"generates_images": outcomeSkipped,
	})
	if next.PromptCaching || next.GeneratesImages {
		t.Error("a skipped probe must not switch anything on")
	}
	if len(enabled) != 0 {
		t.Errorf("nothing should be reported as enabled, got %v", enabled)
	}
}

// The useful half of a result we refuse to act on.
func TestDisagreements_ReportOnlyClaimedAndRefused(t *testing.T) {
	got := disagreements(
		modelmeta.Capabilities{Vision: true, Thinking: true},
		map[string]probeOutcome{
			"vision":   outcomeUnsupported, // claimed + refused → report
			"thinking": outcomeInconclusive, // claimed but unclear → silent
			"tool_use": outcomeUnsupported,  // refused but never claimed → silent
		})
	if len(got) != 1 || got[0] != "vision" {
		t.Errorf("expected only vision, got %v", got)
	}
}

// --- Judgements -------------------------------------------------------------

func judgeFor(t *testing.T, name string, o observed) (probeOutcome, string) {
	t.Helper()
	for _, p := range probes() {
		if p.name == name {
			if p.judge == nil {
				t.Fatalf("%s has no judge", name)
			}
			return p.judge(o)
		}
	}
	t.Fatalf("no probe named %q", name)
	return outcomeInconclusive, ""
}

// A network failure is not a fact about a model. This is the judgement that
// keeps a bad minute from being recorded as a permanent verdict.
func TestJudge_TransientFailuresAreInconclusive(t *testing.T) {
	for _, name := range []string{"streaming", "tool_use", "vision", "thinking"} {
		for _, msg := range []string{
			"dial tcp: connection refused",
			"429 rate limit exceeded",
			"context deadline exceeded",
			"503 service unavailable",
		} {
			got, _ := judgeFor(t, name, observed{sendErr: errStr(msg)})
			if got != outcomeInconclusive {
				t.Errorf("%s + %q: got %v, want inconclusive", name, msg, got)
			}
		}
	}
}

// Only a refusal that names the capability is clean enough to call
// unsupported. Anything looser turns an unrelated 400 into a recorded verdict.
func TestJudge_NamedRefusalIsUnsupported(t *testing.T) {
	cases := []struct{ probe, msg string }{
		{"tool_use", "400: tools are not supported by this model"},
		{"tool_use", "this endpoint does not accept function calls"},
		{"vision", "400: image input is not supported"},
		{"vision", "model is not multimodal"},
		{"thinking", "extended thinking is not available for this model"},
	}
	for _, c := range cases {
		got, detail := judgeFor(t, c.probe, observed{sendErr: errStr(c.msg)})
		if got != outcomeUnsupported {
			t.Errorf("%s + %q: got %v, want unsupported", c.probe, c.msg, got)
		}
		if detail == "" {
			t.Errorf("%s: refusal should carry the upstream's own words", c.probe)
		}
	}
}

func TestJudge_DemonstrationIsSupported(t *testing.T) {
	if got, _ := judgeFor(t, "streaming", observed{textChunks: 3}); got != outcomeSupported {
		t.Errorf("text over a stream should be supported, got %v", got)
	}
	if got, _ := judgeFor(t, "tool_use", observed{toolUse: true}); got != outcomeSupported {
		t.Errorf("a tool call should be supported, got %v", got)
	}
	if got, _ := judgeFor(t, "vision", observed{textChunks: 1}); got != outcomeSupported {
		t.Errorf("an accepted image should be supported, got %v", got)
	}
	if got, _ := judgeFor(t, "thinking", observed{thinking: true}); got != outcomeSupported {
		t.Errorf("emitted reasoning should be supported, got %v", got)
	}
}

// Accepting a parameter and ignoring it is the most common shape, and it is
// not a refusal. Calling it one would be how a probe clears a real capability.
func TestJudge_SilentAcceptanceIsInconclusive(t *testing.T) {
	if got, _ := judgeFor(t, "thinking", observed{textChunks: 2}); got != outcomeInconclusive {
		t.Errorf("thinking accepted but unused should be inconclusive, got %v", got)
	}
	if got, _ := judgeFor(t, "tool_use", observed{textChunks: 2}); got != outcomeInconclusive {
		t.Errorf("tools accepted but unused should be inconclusive, got %v", got)
	}
}

// --- Probe definitions ------------------------------------------------------

func TestProbes_SkippedOnesExplainThemselves(t *testing.T) {
	for _, p := range probes() {
		if p.skip == "" {
			continue
		}
		if p.build != nil || p.judge != nil {
			t.Errorf("%s is skipped but still carries a probe", p.name)
		}
		if len(p.skip) < 20 {
			t.Errorf("%s: reason should say why, got %q", p.name, p.skip)
		}
	}
}

// A capability with no probe and no stated reason would silently never be
// checked, which reads as "we checked and found nothing".
func TestProbes_CoverEveryCapability(t *testing.T) {
	want := []string{"streaming", "thinking", "tool_use", "vision", "prompt_caching", "generates_images"}
	have := map[string]bool{}
	for _, p := range probes() {
		have[p.name] = true
	}
	for _, w := range want {
		if !have[w] {
			t.Errorf("no probe or stated skip for %q", w)
		}
	}
}

func TestProbes_VisionSendsARealImage(t *testing.T) {
	for _, p := range probes() {
		if p.name != "vision" {
			continue
		}
		req := p.build("m")
		if len(req.Messages) != 1 || len(req.Messages[0].Attachments) != 1 {
			t.Fatal("vision probe must attach exactly one image")
		}
		att := req.Messages[0].Attachments[0]
		if att.Kind != providers.AttachmentImage || att.MimeType != "image/png" {
			t.Errorf("unexpected attachment: %+v", att)
		}
		// Small enough that running the probe is a rounding error.
		if len(att.Data) == 0 || len(att.Data) > 200 {
			t.Errorf("probe image should be tiny and non-empty, got %d bytes", len(att.Data))
		}
	}
}

func TestProbes_ToolProbeDeclaresOneCallableTool(t *testing.T) {
	for _, p := range probes() {
		if p.name != "tool_use" {
			continue
		}
		req := p.build("m")
		if len(req.Tools) != 1 {
			t.Fatalf("expected exactly one tool, got %d", len(req.Tools))
		}
		if !strings.Contains(string(req.Tools[0].InputSchema), "\"type\":\"object\"") {
			t.Errorf("tool schema should be an object: %s", req.Tools[0].InputSchema)
		}
	}
}

type errString string

func (e errString) Error() string { return string(e) }
func errStr(s string) error       { return errString(s) }
