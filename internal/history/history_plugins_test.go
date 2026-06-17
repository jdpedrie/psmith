package history

import (
	"context"
	"testing"

	"github.com/jdpedrie/spalt/internal/providers"
	"github.com/jdpedrie/spalt/plugins"
)

// --- Test plugins ----------------------------------------------------------
//
// Defined locally so we don't depend on a particular registered plugin.
// They're constructed directly (no registry round-trip) and slotted into
// Pipeline values for hand-controlled test inputs.

type prependSysPlugin struct{ pre, post string }

func (p *prependSysPlugin) Name() string                 { return "test-sysprompt" }
func (p *prependSysPlugin) DisplayName() string          { return "Test Sysprompt" }
func (p *prependSysPlugin) Description() string          { return "test" }
func (p *prependSysPlugin) PrependSystemMessage() string { return p.pre }
func (p *prependSysPlugin) AppendSystemMessage() string  { return p.post }

type stripAfterNPlugin struct {
	keepLast int
	open     string
	close    string
}

func (p *stripAfterNPlugin) Name() string        { return "test-strip-after-n" }
func (p *stripAfterNPlugin) DisplayName() string { return "Test Strip After N" }
func (p *stripAfterNPlugin) Description() string { return "test" }
func (p *stripAfterNPlugin) TransformHistoryMessage(msg providers.WireMessage, pos plugins.HistoryPos) providers.WireMessage {
	if msg.Role != "assistant" || pos.FromHeadSameRole < p.keepLast {
		return msg
	}
	// minimal in-place strip; leave it ugly to keep the test simple — the
	// real lettered_choices plugin has its own stripping tests.
	out := msg
	for {
		i := indexOf(out.Content, p.open)
		if i < 0 {
			break
		}
		j := indexOf(out.Content[i+len(p.open):], p.close)
		if j < 0 {
			break
		}
		end := i + len(p.open) + j + len(p.close)
		out.Content = out.Content[:i] + out.Content[end:]
	}
	return out
}

// indexOf is a tiny strings.Index alias to avoid importing strings just here.
func indexOf(s, sub string) int {
	if sub == "" {
		return 0
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

// --- HistoryTransformer integration ----------------------------------------

func TestBuild_HistoryTransformer_KeepsRecentStripsOlder(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	// Tree: system → user_1 → asst_1 → user_2 → asst_2 (head)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "you are helpful")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "user", "first")
	a1 := insertMessage(t, f.q, f.ctxRow.ID, &u1.ID, "assistant", "first reply <c>A) one</c>")
	u2 := insertMessage(t, f.q, f.ctxRow.ID, &a1.ID, "user", "second")
	a2 := insertMessage(t, f.q, f.ctxRow.ID, &u2.ID, "assistant", "second reply <c>X) alt</c>")

	pipeline := plugins.Pipeline{&stripAfterNPlugin{keepLast: 1, open: "<c>", close: "</c>"}}
	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &a2.ID,
		DestProviderType: "anthropic",
		Plugins:          pipeline,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 5 {
		t.Fatalf("len = %d want 5", len(wire))
	}
	// asst_1 (posFromHead=2) should be stripped; asst_2 (posFromHead=0) kept.
	if got := wire[2].Content; got != "first reply " {
		t.Errorf("asst_1 stripped = %q want %q", got, "first reply ")
	}
	if got := wire[4].Content; got != "second reply <c>X) alt</c>" {
		t.Errorf("asst_2 (head) should be unchanged; got %q", got)
	}
}

func TestBuild_HistoryTransformer_SkipsSystemAndContext(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)

	// system + role=context (snapshot) + user + assistant. The transformer
	// would gleefully strip from system/context content if it were given
	// the chance, so we put strippable text in those slots and verify
	// they're untouched.
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "system text <c>ZZZ</c>")
	cxm := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "context", "context text <c>YYY</c>")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &cxm.ID, "user", "u1")
	a1 := insertMessage(t, f.q, f.ctxRow.ID, &u1.ID, "assistant", "a1 <c>VISIBLE</c>")

	pipeline := plugins.Pipeline{&stripAfterNPlugin{keepLast: 0, open: "<c>", close: "</c>"}}
	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &a1.ID,
		DestProviderType: "anthropic",
		Plugins:          pipeline,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 4 {
		t.Fatalf("len = %d want 4", len(wire))
	}
	if wire[0].Content != "system text <c>ZZZ</c>" {
		t.Errorf("system content was modified: %q", wire[0].Content)
	}
	if wire[1].Content != "context text <c>YYY</c>" {
		t.Errorf("context content was modified: %q", wire[1].Content)
	}
	// User row content has no choices block; transformer is a no-op for users
	// regardless. Verify it's untouched too.
	if wire[2].Content != "u1" {
		t.Errorf("user content modified: %q", wire[2].Content)
	}
	// Assistant content with keepLast=0 should be stripped.
	if wire[3].Content != "a1 " {
		t.Errorf("assistant strip = %q want %q", wire[3].Content, "a1 ")
	}
}

func TestBuild_NoPluginsBehavesIdenticallyToPreviousBuild(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "sys")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "user", "u1")
	a1 := insertMessage(t, f.q, f.ctxRow.ID, &u1.ID, "assistant", "a1")

	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &a1.ID,
		DestProviderType: "anthropic",
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 3 {
		t.Fatalf("len = %d want 3", len(wire))
	}
	if wire[0].Role != "system" || wire[1].Role != "user" || wire[2].Role != "assistant" {
		t.Errorf("roles wrong: %v %v %v", wire[0].Role, wire[1].Role, wire[2].Role)
	}
}

// --- SystemPrompter integration --------------------------------------------

func TestBuild_SystemPrompter_WrapsExistingSystem(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "STORED")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "user", "u1")

	pipeline := plugins.Pipeline{&prependSysPlugin{pre: "PRE", post: "POST"}}
	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &u1.ID,
		DestProviderType: "anthropic",
		Plugins:          pipeline,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 2 {
		t.Fatalf("len = %d want 2", len(wire))
	}
	if wire[0].Role != "system" {
		t.Fatalf("first role = %q want system", wire[0].Role)
	}
	want := "PRE\n\nSTORED\n\nPOST"
	if wire[0].Content != want {
		t.Errorf("system content = %q want %q", wire[0].Content, want)
	}
}

func TestBuild_SystemPrompter_InsertsWhenNoSystem(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	u1 := insertMessage(t, f.q, f.ctxRow.ID, nil, "user", "u1")

	pipeline := plugins.Pipeline{&prependSysPlugin{pre: "PRE", post: "POST"}}
	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &u1.ID,
		DestProviderType: "anthropic",
		Plugins:          pipeline,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(wire) != 2 {
		t.Fatalf("len = %d want 2", len(wire))
	}
	if wire[0].Role != "system" {
		t.Fatalf("first role = %q want system (inserted)", wire[0].Role)
	}
	if wire[0].Content != "PRE\n\nPOST" {
		t.Errorf("inserted system content = %q want %q", wire[0].Content, "PRE\n\nPOST")
	}
}

func TestBuild_SystemPrompter_OnlyPrependNoExisting(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	u1 := insertMessage(t, f.q, f.ctxRow.ID, nil, "user", "u1")

	pipeline := plugins.Pipeline{&prependSysPlugin{pre: "ONLY-PRE"}}
	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &u1.ID,
		DestProviderType: "anthropic",
		Plugins:          pipeline,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if wire[0].Content != "ONLY-PRE" {
		t.Errorf("system content = %q want %q", wire[0].Content, "ONLY-PRE")
	}
}

func TestBuild_SystemPrompter_NoContributionsLeavesSystemAlone(t *testing.T) {
	t.Parallel()
	f := seedConversation(t)
	sys := insertMessage(t, f.q, f.ctxRow.ID, nil, "system", "untouched")
	u1 := insertMessage(t, f.q, f.ctxRow.ID, &sys.ID, "user", "u1")

	// Plugin returning empty strings — should not wrap.
	pipeline := plugins.Pipeline{&prependSysPlugin{pre: "", post: ""}}
	wire, err := Build(context.Background(), f.q, Params{
		Conversation:     f.conv,
		LeafMessageID:    &u1.ID,
		DestProviderType: "anthropic",
		Plugins:          pipeline,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if wire[0].Content != "untouched" {
		t.Errorf("system content = %q want %q", wire[0].Content, "untouched")
	}
}
