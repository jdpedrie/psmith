package web

import (
	"context"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

func TestFragmentOf(t *testing.T) {
	cards := fragmentOf("card_list", []byte(`{"items":[{"title":"A","url":"https://example.com/x","badges":["b"]},{"title":"Bad","url":"javascript:alert(1)"}]}`))
	if cards.Kind != "card_list" || len(cards.Cards) != 2 || cards.Cards[0].Host != "example.com" || cards.Cards[1].URL != "" {
		t.Errorf("cards = %+v", cards)
	}
	ch := fragmentOf("choice_list", []byte(`{"items":[{"label":"A. Go left","value":"A","action":"send:A"},{"label":"Stay","action":"external:https://x"},{"label":"Write","value":"long value","action":"compose:Write it"}]}`))
	if len(ch.Choices) != 3 {
		t.Fatalf("choices = %+v", ch.Choices)
	}
	if c := ch.Choices[0]; c.Letter != "A" || c.Label != "Go left" || c.Payload != "A" {
		t.Errorf("first = %+v", c)
	}
	if c := ch.Choices[1]; c.Letter != "B" || c.Action != "" {
		t.Errorf("unsupported action kept: %+v", c)
	}
	if c := ch.Choices[2]; c.Letter != "C" || c.Payload != "Write it" {
		t.Errorf("third = %+v", c)
	}
	if kv := fragmentOf("key_value", []byte(`{"pairs":[{"key":"Rows","value":"412"}]}`)); len(kv.Pairs) != 1 || kv.Pairs[0].Value != "412" {
		t.Errorf("kv = %+v", kv)
	}
	if tx := fragmentOf("text", []byte(`{"text":"**hi**"}`)); !strings.Contains(tx.HTML, "<strong>hi</strong>") {
		t.Errorf("text = %q", tx.HTML)
	}
	if im := fragmentOf("image", []byte(`{"url":"https://e.com/a.png","alt":"a"}`)); len(im.Images) != 1 {
		t.Errorf("image = %+v", im)
	}
	if e := fragmentOf("error", []byte(`{"message":"rate limited","code":"429"}`)); e.Message != "rate limited" || e.Code != "429" {
		t.Errorf("error = %+v", e)
	}
	if u := fragmentOf("mystery", []byte(`{"a":1}`)); u.Kind != "json" || !strings.Contains(u.HTML, `"a": 1`) {
		t.Errorf("unknown = %+v", u)
	}
	if bad := fragmentOf("key_value", []byte(`not json`)); bad.Kind != "json" {
		t.Errorf("malformed = %+v", bad)
	}
}

func TestNewestLeaf(t *testing.T) {
	tree := map[string][]string{"": {"u"}, "u": {"a1", "a2"}, "a1": {"u2"}, "u2": {"x", "y"}}
	if got := newestLeaf(tree, "a1"); got != "y" {
		t.Errorf("newestLeaf(a1) = %s", got)
	}
	if got := newestLeaf(tree, "a2"); got != "a2" {
		t.Errorf("newestLeaf(a2) = %s", got)
	}
	if !inTree(tree, "x") || inTree(tree, "zz") {
		t.Error("inTree")
	}
}

func TestFinishItems(t *testing.T) {
	items := []msgItem{
		{Role: "assistant", Persona: "Skeptic"},
		{Role: "assistant", Persona: "Optimist"},
		{Role: "assistant", Persona: "Economist", Parts: []fragVM{{Kind: "choice_list", Choices: []choiceVM{{Letter: "A", Payload: "A"}, {Letter: "B", Payload: "B"}}}}},
		{Role: "user", Text: "B"},
	}
	finishItems(items)
	if !items[0].HideActions || !items[1].HideActions || items[2].HideActions {
		t.Errorf("only the last voice keeps actions: %v %v %v", items[0].HideActions, items[1].HideActions, items[2].HideActions)
	}
	if items[2].Parts[0].Choices[0].Chosen || !items[2].Parts[0].Choices[1].Chosen {
		t.Error("the sent choice reads as chosen")
	}
	if got := personasOf(items); got != "Skeptic, Optimist, Economist" {
		t.Errorf("personas = %q", got)
	}
}

func TestUsageOfDetail(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	i := func(v int32) *int32 { return &v }
	m := &psmithv1.Message{ModelId: ptr("claude-opus-4-7"), FinishReason: ptr("end_turn"), CreatedAt: timestamppb.Now(), Usage: &psmithv1.MessageUsage{
		InputTokens: i(2882), OutputTokens: i(1284), CacheReadTokens: i(77210), CacheWriteTokens: i(2048), ReasoningTokens: i(312),
		InputCostUsd: f(0.01441), OutputCostUsd: f(0.0321), CacheReadCostUsd: f(0.0386), CacheWriteCostUsd: f(0.0128), TotalCostUsd: f(0.0979),
	}}
	u := usageOf(m)
	if u.Model != "Opus 4.7" || u.Cached != "94% cached" || u.Total != "$0.0979" || u.Stop != "end_turn" || u.CacheR != "77,210" {
		t.Errorf("usage = %+v", u)
	}
	if u.Saved == "" || !strings.HasPrefix(u.Saved, "$0.34") {
		t.Errorf("saved = %q", u.Saved)
	}
	if dollars4(nil) != "—" {
		t.Error("missing cost reads as a dash")
	}
}

func ptr[T any](v T) *T { return &v }

func TestKindLabelAndSentWhen(t *testing.T) {
	for _, c := range []struct{ mime, name, want string }{
		{"application/pdf", "a.pdf", "PDF"}, {"text/plain", "a.txt", "Text"}, {"application/zip", "b.zip", "ZIP"}, {"application/x-thing", "noext", "X-THING"},
	} {
		if got := kindLabel(c.mime, c.name); got != c.want {
			t.Errorf("kindLabel(%q,%q) = %q", c.mime, c.name, got)
		}
	}
	now := time.Now()
	if !strings.HasPrefix(sentWhen(now), "today at ") || !strings.HasPrefix(sentWhen(now.AddDate(0, 0, -1)), "yesterday at ") || !strings.HasPrefix(sentWhen(now.AddDate(0, 0, -9)), "on ") {
		t.Error("sentWhen buckets")
	}
}

func TestLiveChips(t *testing.T) {
	start := time.Now().Add(-2 * time.Second)
	s := &liveState{thinkStart: &start}
	s.tools = append(s.tools, liveTool{name: "grep", started: start, input: []byte(`{"pattern":"CompressionSummaryCard"}`)})
	s.tools[0].summary = toolSummary(s.tools[0].input)
	chips := s.chips()
	if len(chips) != 2 || !chips[0].Thinking || chips[0].Since == "" || chips[1].Label != "CompressionSummaryCard · running" || !chips[1].Live {
		t.Fatalf("chips = %+v", chips)
	}
	s.thinkDur = 4100 * time.Millisecond
	s.tools[0].done, s.tools[0].elapsed = true, 800*time.Millisecond
	chips = s.chips()
	if chips[0].Label != "Thought for 4.1s" || chips[1].Label != "CompressionSummaryCard · 0.8s" || chips[1].Live {
		t.Errorf("done chips = %+v", chips)
	}
	s.tools[0].err = "boom"
	if got := s.chips()[1].Label; got != "failed · 0.8s" {
		t.Errorf("failed chip = %q", got)
	}
}

// The board fixtures render, so every template branch they reach is exercised
// even when the probe is skipped.
func TestConvTemplatesRender(t *testing.T) {
	ctx := context.Background()
	for name, c := range map[string]convVM{
		"Main": boardConv(), "Streaming": boardStreaming(), "Thinking": boardThinking(), "MessageMenu": boardMessageMenu(),
		"MessageStates": boardMessageStates(), "MessageUsage": boardMessageUsage(), "Branches": boardBranches(),
		"Attachments": boardAttachments(), "ComposerAttach": boardComposerAttach(), "Council": boardCouncil(),
		"SystemStrip": boardSystemStrip(), "Harness": boardHarness(), "RenameTitle": boardRenameTitle(),
		"Fragments": boardFragments(), "Phone": boardPhone(),
	} {
		if out := renderComp(ctx, conversationScreen(boardList(), c)); !strings.Contains(out, `id="composer"`) && c.Slot == "" {
			t.Errorf("%s: no composer", name)
		}
	}
	checks := map[string]string{
		"Council":   "Continue the discussion",
		"Harness":   "system prompt fixed · no attachments",
		"Fragments": `class="choice chosen"`,
		"Thinking":  "Succeeded",
	}
	for name, want := range checks {
		var c convVM
		switch name {
		case "Council":
			c = boardCouncil()
		case "Harness":
			c = boardHarness()
		case "Fragments":
			c = boardFragments()
		case "Thinking":
			c = boardThinking()
		}
		if out := renderComp(ctx, conversationScreen(boardList(), c)); !strings.Contains(out, want) {
			t.Errorf("%s: missing %q", name, want)
		}
	}
	if out := renderComp(ctx, imagePage(boardImageViewer())); !strings.Contains(out, "Shown fit to the window.") {
		t.Error("image page")
	}
}
