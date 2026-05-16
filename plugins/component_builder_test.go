package plugins

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jdpedrie/reeve/internal/providers"
)

func buildComponentBuilder(t *testing.T, configJSON string) *componentBuilder {
	t.Helper()
	pl, err := newComponentBuilder([]byte(configJSON))
	if err != nil {
		t.Fatalf("newComponentBuilder: %v", err)
	}
	cb, ok := pl.(*componentBuilder)
	if !ok {
		t.Fatalf("expected *componentBuilder, got %T", pl)
	}
	return cb
}

func TestComponentBuilder_EmptyConfigIsNoOp(t *testing.T) {
	t.Parallel()
	cb := buildComponentBuilder(t, "")
	if got := cb.AppendSystemMessage(); got != "" {
		t.Errorf("empty config should produce empty system message; got %q", got)
	}
	in := providers.WireMessage{Role: "user", Content: "hi"}
	if got := cb.TransformHistoryMessage(in, HistoryPos{FromHeadSameRole: 0}); got.Content != "hi" {
		t.Errorf("empty config should leave user message untouched; got %q", got.Content)
	}
	parts := cb.RenderContent([]ContentPart{NewTextPart("hello")}, "assistant")
	if len(parts) != 1 || parts[0].Text != "hello" {
		t.Errorf("empty config should pass parts through; got %#v", parts)
	}
}

func TestComponentBuilder_RejectsInvalidConfig(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"missing name":         `{"components":[{"component":"choice_list","open_tag":"<a>","close_tag":"</a>"}]}`,
		"missing component":    `{"components":[{"name":"x","open_tag":"<a>","close_tag":"</a>"}]}`,
		"missing open":         `{"components":[{"name":"x","component":"choice_list","close_tag":"</a>"}]}`,
		"missing close":        `{"components":[{"name":"x","component":"choice_list","open_tag":"<a>"}]}`,
		"identical tags":       `{"components":[{"name":"x","component":"choice_list","open_tag":"X","close_tag":"X"}]}`,
		"duplicate names":      `{"components":[{"name":"x","component":"choice_list","open_tag":"<a>","close_tag":"</a>"},{"name":"x","component":"key_value","open_tag":"<b>","close_tag":"</b>"}]}`,
		"bad reminder mode":    `{"components":[{"name":"x","component":"choice_list","open_tag":"<a>","close_tag":"</a>","reminder_mode":"sometimes"}]}`,
		"bad json":             `{not json`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := newComponentBuilder([]byte(body)); err == nil {
				t.Errorf("expected error for %s", name)
			}
		})
	}
}

func TestComponentBuilder_SystemMessageIncludesEachDefinition(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[
		{"name":"combat_choices","component":"choice_list","open_tag":"<choices>","close_tag":"</choices>","position":"end","instructions":"Use this when offering choices."},
		{"name":"weather_stats","component":"key_value","open_tag":"<stats>","close_tag":"</stats>","position":"start","instructions":"Use this for stats."}
	]}`
	cb := buildComponentBuilder(t, cfg)
	got := cb.AppendSystemMessage()
	for _, want := range []string{
		"## combat_choices (choice_list)", "<choices>", "</choices>", "END of your response",
		"## weather_stats (key_value)", "<stats>", "</stats>", "START of your response",
		"Use this when offering choices.", "Use this for stats.",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("system message missing %q\n--- got ---\n%s", want, got)
		}
	}
}

func TestComponentBuilder_ReminderHeadOnlyAndModes(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[
		{"name":"combat_choices","component":"choice_list","open_tag":"<a>","close_tag":"</a>","reminder_mode":"always"},
		{"name":"weather_stats","component":"key_value","open_tag":"<b>","close_tag":"</b>","reminder_mode":"none"},
		{"name":"search_results","component":"card_list","open_tag":"<c>","close_tag":"</c>","reminder_mode":"when_appropriate"}
	]}`
	cb := buildComponentBuilder(t, cfg)
	// Head: always + when_appropriate reminders fire; none is skipped.
	head := cb.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "ok"},
		HistoryPos{FromHeadSameRole: 0},
	)
	if !strings.Contains(head.Content, "[system_reminder Always generate the combat_choices component.]") {
		t.Errorf("always-mode reminder missing; got %q", head.Content)
	}
	if !strings.Contains(head.Content, "[system_reminder Generate the search_results component when appropriate.]") {
		t.Errorf("when_appropriate-mode reminder missing; got %q", head.Content)
	}
	if strings.Contains(head.Content, "weather_stats") {
		t.Errorf("none-mode reminder leaked into head; got %q", head.Content)
	}
	// Older user message: untouched.
	older := cb.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "ok"},
		HistoryPos{FromHeadSameRole: 2},
	)
	if older.Content != "ok" {
		t.Errorf("older user message should not get reminders; got %q", older.Content)
	}
}

func TestComponentBuilder_RendererSkipsNonAssistant(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[{"name":"x","component":"choice_list","open_tag":"<c>","close_tag":"</c>"}]}`
	cb := buildComponentBuilder(t, cfg)
	in := []ContentPart{NewTextPart(`<c>{"items":[]}</c>`)}
	out := cb.RenderContent(in, "user")
	if len(out) != 1 || !out[0].IsText() {
		t.Errorf("non-assistant role should pass through; got %#v", out)
	}
}

func TestComponentBuilder_RendererExtractsTaggedBlock(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[{"name":"x","component":"choice_list","open_tag":"<choices>","close_tag":"</choices>"}]}`
	cb := buildComponentBuilder(t, cfg)
	body := `Pick one:
<choices>{"items":[{"label":"A"},{"label":"B"}]}</choices>
Or pick again later.`
	out := cb.RenderContent([]ContentPart{NewTextPart(body)}, "assistant")
	if len(out) != 3 {
		t.Fatalf("expected 3 parts (text, fragment, text); got %d (%#v)", len(out), out)
	}
	if !out[0].IsText() || !strings.HasPrefix(out[0].Text, "Pick one:") {
		t.Errorf("part 0 wrong: %#v", out[0])
	}
	if out[1].IsText() || out[1].Fragment.Component != "choice_list" {
		t.Errorf("part 1 should be the choice_list fragment; got %#v", out[1])
	}
	var props struct {
		Items []struct {
			Label string `json:"label"`
		} `json:"items"`
	}
	if err := json.Unmarshal(out[1].Fragment.Props, &props); err != nil {
		t.Fatalf("fragment props don't parse: %v", err)
	}
	if len(props.Items) != 2 || props.Items[0].Label != "A" {
		t.Errorf("fragment props body wrong: %#v", props)
	}
	if !out[2].IsText() || !strings.Contains(out[2].Text, "later") {
		t.Errorf("part 2 wrong: %#v", out[2])
	}
}

func TestComponentBuilder_PreservesMalformedJSONAsText(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[{"name":"x","component":"choice_list","open_tag":"<c>","close_tag":"</c>"}]}`
	cb := buildComponentBuilder(t, cfg)
	body := `before <c>{not json</c> after`
	out := cb.RenderContent([]ContentPart{NewTextPart(body)}, "assistant")
	if len(out) != 3 {
		t.Fatalf("expected 3 parts; got %d (%#v)", len(out), out)
	}
	// Middle part should be the literal tag block, NOT a fragment.
	if !out[1].IsText() {
		t.Errorf("malformed JSON should fall back to text; got fragment %#v", out[1].Fragment)
	}
	if !strings.Contains(out[1].Text, "<c>{not json</c>") {
		t.Errorf("malformed body not preserved verbatim; got %q", out[1].Text)
	}
}

func TestComponentBuilder_MultipleDefinitionsApplyInConfigOrder(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[
		{"name":"x","component":"choice_list","open_tag":"<choices>","close_tag":"</choices>"},
		{"name":"y","component":"key_value","open_tag":"<stats>","close_tag":"</stats>"}
	]}`
	cb := buildComponentBuilder(t, cfg)
	body := `<stats>{"pairs":[{"key":"k","value":"v"}]}</stats>
Some text.
<choices>{"items":[{"label":"X"}]}</choices>`
	out := cb.RenderContent([]ContentPart{NewTextPart(body)}, "assistant")
	// Expect: Fragment(key_value), Text("\nSome text.\n"), Fragment(choice_list)
	if len(out) != 3 {
		t.Fatalf("expected 3 parts; got %d (%#v)", len(out), out)
	}
	componentOf := func(p ContentPart) string {
		if p.IsText() { return "text" }
		return p.Fragment.Component
	}
	if componentOf(out[0]) != "key_value" {
		t.Errorf("part 0 should be key_value fragment; got %s", componentOf(out[0]))
	}
	if !out[1].IsText() {
		t.Errorf("part 1 should be the prose between blocks; got %#v", out[1])
	}
	if componentOf(out[2]) != "choice_list" {
		t.Errorf("part 2 should be choice_list fragment; got %s", componentOf(out[2]))
	}
}

func TestComponentBuilder_RegisteredAtInit(t *testing.T) {
	t.Parallel()
	pl, err := Build(ComponentBuilderName, []byte(`{"components":[]}`))
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if _, ok := pl.(SystemPrompter); !ok {
		t.Error("must implement SystemPrompter")
	}
	if _, ok := pl.(HistoryTransformer); !ok {
		t.Error("must implement HistoryTransformer")
	}
	if _, ok := pl.(ContentRenderer); !ok {
		t.Error("must implement ContentRenderer")
	}
	if _, ok := pl.(Configurable); !ok {
		t.Error("must implement Configurable")
	}
}
