package plugins

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/jdpedrie/reeve/internal/providers"
)

// dummyPlugin is a minimal Plugin used in registry tests.
type dummyPlugin struct{ name string }

func (d *dummyPlugin) Name() string        { return d.name }
func (d *dummyPlugin) DisplayName() string { return d.name }
func (d *dummyPlugin) Description() string { return "dummy" }

func TestRegistry_BuildUnknown(t *testing.T) {
	t.Parallel()
	if _, err := Build("does-not-exist", nil); err == nil {
		t.Fatal("expected error for unknown plugin")
	}
}

func TestRegistry_RegisterPanicsOnDuplicate(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic on duplicate Register")
		}
	}()
	// lettered_choices is already registered by package init; re-registering should panic.
	Register(LetteredChoicesName, func(json.RawMessage) (Plugin, error) {
		return &dummyPlugin{name: LetteredChoicesName}, nil
	})
}

func TestRegistry_RegisterPanicsOnEmptyName(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic on empty name")
		}
	}()
	Register("", func(json.RawMessage) (Plugin, error) { return &dummyPlugin{}, nil })
}

func TestRegistry_RegisterPanicsOnNilCtor(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic on nil constructor")
		}
	}()
	Register("nil-ctor", nil)
}

func TestRegistry_ListRegisteredIncludesBuiltins(t *testing.T) {
	t.Parallel()
	names := ListRegistered()
	found := false
	for _, n := range names {
		if n == LetteredChoicesName {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("ListRegistered did not include %q; got %v", LetteredChoicesName, names)
	}
}

// --- Pipeline ---

// fakeSystemPrompter implements just SystemPrompter so we can test Pipeline
// composition in isolation.
type fakeSystemPrompter struct {
	dummyPlugin
	pre, post string
}

func (f *fakeSystemPrompter) PrependSystemMessage() string { return f.pre }
func (f *fakeSystemPrompter) AppendSystemMessage() string  { return f.post }

// fakeHistoryTransformer always rewrites assistant content to a fixed string
// when FromHead is at least the configured threshold.
type fakeHistoryTransformer struct {
	dummyPlugin
	threshold int
	replace   string
}

func (f *fakeHistoryTransformer) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage {
	if msg.Role == "assistant" && pos.FromHead >= f.threshold {
		out := msg
		out.Content = f.replace
		return out
	}
	return msg
}

// fakeDisplayTransformer wraps content with brackets.
type fakeDisplayTransformer struct {
	dummyPlugin
	prefix, suffix string
}

func (f *fakeDisplayTransformer) TransformForDisplay(content string) string {
	return f.prefix + content + f.suffix
}

// fakeOutgoingTransformer prefixes outgoing user content.
type fakeOutgoingTransformer struct {
	dummyPlugin
	prefix string
}

func (f *fakeOutgoingTransformer) TransformOutgoingUserMessage(content string, _ map[string]string) string {
	return f.prefix + content
}

func TestPipeline_Empty(t *testing.T) {
	t.Parallel()
	var p Pipeline
	if !p.Empty() {
		t.Error("nil Pipeline should report Empty")
	}
	prep, app := p.SystemPrompts()
	if prep != "" || app != "" {
		t.Errorf("empty SystemPrompts should be (\"\", \"\"); got (%q, %q)", prep, app)
	}
	if got := p.TransformOutgoingUser("x", nil); got != "x" {
		t.Errorf("empty TransformOutgoingUser should be no-op; got %q", got)
	}
	if got := p.TransformForDisplay("x"); got != "x" {
		t.Errorf("empty TransformForDisplay should be no-op; got %q", got)
	}
	msg := providers.WireMessage{Role: "assistant", Content: "y"}
	if got := p.TransformHistoryMessage(msg, HistoryPos{FromHead: 3}); got.Content != "y" {
		t.Errorf("empty TransformHistoryMessage should be no-op; got %q", got.Content)
	}
}

func TestPipeline_SystemPromptsConcatenateInOrder(t *testing.T) {
	t.Parallel()
	p := Pipeline{
		&fakeSystemPrompter{dummyPlugin{name: "a"}, "PRE-A", "POST-A"},
		&fakeSystemPrompter{dummyPlugin{name: "b"}, "", "POST-B"},
		&fakeSystemPrompter{dummyPlugin{name: "c"}, "PRE-C", ""},
	}
	pre, post := p.SystemPrompts()
	if pre != "PRE-A\n\nPRE-C" {
		t.Errorf("pre = %q want %q", pre, "PRE-A\n\nPRE-C")
	}
	if post != "POST-A\n\nPOST-B" {
		t.Errorf("post = %q want %q", post, "POST-A\n\nPOST-B")
	}
}

func TestPipeline_TransformOutgoingUser_AppliesInOrder(t *testing.T) {
	t.Parallel()
	p := Pipeline{
		&fakeOutgoingTransformer{dummyPlugin{name: "a"}, "[A]"},
		&fakeOutgoingTransformer{dummyPlugin{name: "b"}, "[B]"},
	}
	got := p.TransformOutgoingUser("hi", nil)
	if got != "[B][A]hi" {
		t.Errorf("got %q want %q", got, "[B][A]hi")
	}
}

func TestPipeline_TransformHistoryMessage_AppliesInOrder(t *testing.T) {
	t.Parallel()
	p := Pipeline{
		// First marks anything at pos>=2 as "X".
		&fakeHistoryTransformer{dummyPlugin{name: "a"}, 2, "FIRST"},
		// Second always overwrites assistant content (uses pos>=0) — runs after the first.
		&fakeHistoryTransformer{dummyPlugin{name: "b"}, 0, "SECOND"},
	}
	msg := providers.WireMessage{Role: "assistant", Content: "orig"}
	got := p.TransformHistoryMessage(msg, HistoryPos{FromHead: 5})
	if got.Content != "SECOND" {
		t.Errorf("got %q want SECOND (last writer wins)", got.Content)
	}
	// And at pos < first.threshold, only the second should apply.
	got = p.TransformHistoryMessage(msg, HistoryPos{FromHead: 0})
	if got.Content != "SECOND" {
		t.Errorf("got %q want SECOND", got.Content)
	}
}

func TestPipeline_TransformForDisplay_AppliesInOrder(t *testing.T) {
	t.Parallel()
	p := Pipeline{
		&fakeDisplayTransformer{dummyPlugin{name: "a"}, "<a>", "</a>"},
		&fakeDisplayTransformer{dummyPlugin{name: "b"}, "<b>", "</b>"},
	}
	got := p.TransformForDisplay("x")
	if got != "<b><a>x</a></b>" {
		t.Errorf("got %q want %q", got, "<b><a>x</a></b>")
	}
}

func TestPipeline_PluginsWithoutCapabilityAreSkipped(t *testing.T) {
	t.Parallel()
	// Mix a SystemPrompter with a bare-Plugin — the bare one should be a no-op everywhere.
	p := Pipeline{
		&dummyPlugin{name: "bare"},
		&fakeSystemPrompter{dummyPlugin{name: "sp"}, "PRE", "POST"},
	}
	pre, post := p.SystemPrompts()
	if pre != "PRE" || post != "POST" {
		t.Errorf("got (%q, %q) want (PRE, POST)", pre, post)
	}
	// And TransformOutgoingUser is a no-op since neither plugin implements it.
	if got := p.TransformOutgoingUser("x", nil); got != "x" {
		t.Errorf("got %q want %q", got, "x")
	}
}

// --- Resolve ---

func TestResolve_BuildsByName(t *testing.T) {
	t.Parallel()
	specs := []Spec{
		{Name: LetteredChoicesName, Config: nil},
		{Name: LetteredChoicesName, Config: []byte(`{"keep_last_n": 3}`)},
	}
	p, err := Resolve(specs)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if len(p) != 2 {
		t.Fatalf("len = %d want 2", len(p))
	}
	if p[0].Name() != LetteredChoicesName {
		t.Errorf("p[0].Name = %q want %q", p[0].Name(), LetteredChoicesName)
	}
}

func TestResolve_UnknownPluginErrors(t *testing.T) {
	t.Parallel()
	_, err := Resolve([]Spec{{Name: "missing", Config: nil}})
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestResolve_BadConfigErrors(t *testing.T) {
	t.Parallel()
	_, err := Resolve([]Spec{{Name: LetteredChoicesName, Config: []byte(`{not json`)}})
	if err == nil {
		t.Fatal("expected error for bad config")
	}
}

func TestResolve_EmptyReturnsNil(t *testing.T) {
	t.Parallel()
	p, err := Resolve(nil)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if p != nil {
		t.Errorf("Resolve(nil) = %v want nil", p)
	}
}

// Ensure ErrUnknownPlugin is referenced (it's exported so callers can check;
// keeps the symbol live even though Build returns a wrapped error).
func TestErrUnknownPluginDeclared(t *testing.T) {
	t.Parallel()
	if !errors.Is(ErrUnknownPlugin, ErrUnknownPlugin) {
		t.Fatal("sanity")
	}
}
