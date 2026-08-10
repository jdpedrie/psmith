package componentbuilder

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/providers"
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
	if got := onlyMsg(t, cb.TransformHistoryMessage(in, pluginapi.HistoryPos{FromHeadSameRole: 0})); got.Content != "hi" {
		t.Errorf("empty config should leave user message untouched; got %q", got.Content)
	}
	parts := cb.RenderContent([]pluginapi.ContentPart{pluginapi.NewTextPart("hello")}, "assistant")
	if len(parts) != 1 || parts[0].Text != "hello" {
		t.Errorf("empty config should pass parts through; got %#v", parts)
	}
}

func TestComponentBuilder_RejectsInvalidConfig(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"missing name":      `{"components":[{"component":"choice_list","open_tag":"<a>","close_tag":"</a>"}]}`,
		"missing component": `{"components":[{"name":"x","open_tag":"<a>","close_tag":"</a>"}]}`,
		"missing open":      `{"components":[{"name":"x","component":"choice_list","close_tag":"</a>"}]}`,
		"missing close":     `{"components":[{"name":"x","component":"choice_list","open_tag":"<a>"}]}`,
		"identical tags":    `{"components":[{"name":"x","component":"choice_list","open_tag":"X","close_tag":"X"}]}`,
		"duplicate names":   `{"components":[{"name":"x","component":"choice_list","open_tag":"<a>","close_tag":"</a>"},{"name":"x","component":"key_value","open_tag":"<b>","close_tag":"</b>"}]}`,
		"bad reminder mode": `{"components":[{"name":"x","component":"choice_list","open_tag":"<a>","close_tag":"</a>","reminder_mode":"sometimes"}]}`,
		"bad json":          `{not json`,
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
	head := onlyMsg(t, cb.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "ok"},
		pluginapi.HistoryPos{FromHeadSameRole: 0},
	))
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
	older := onlyMsg(t, cb.TransformHistoryMessage(
		providers.WireMessage{Role: "user", Content: "ok"},
		pluginapi.HistoryPos{FromHeadSameRole: 2},
	))
	if older.Content != "ok" {
		t.Errorf("older user message should not get reminders; got %q", older.Content)
	}
}

func TestComponentBuilder_RendererSkipsNonAssistant(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[{"name":"x","component":"choice_list","open_tag":"<c>","close_tag":"</c>"}]}`
	cb := buildComponentBuilder(t, cfg)
	in := []pluginapi.ContentPart{pluginapi.NewTextPart(`<c>{"items":[]}</c>`)}
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
	out := cb.RenderContent([]pluginapi.ContentPart{pluginapi.NewTextPart(body)}, "assistant")
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
	out := cb.RenderContent([]pluginapi.ContentPart{pluginapi.NewTextPart(body)}, "assistant")
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
	out := cb.RenderContent([]pluginapi.ContentPart{pluginapi.NewTextPart(body)}, "assistant")
	// Expect: Fragment(key_value), Text("\nSome text.\n"), Fragment(choice_list)
	if len(out) != 3 {
		t.Fatalf("expected 3 parts; got %d (%#v)", len(out), out)
	}
	componentOf := func(p pluginapi.ContentPart) string {
		if p.IsText() {
			return "text"
		}
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
	pl, err := pluginapi.Build(Name, []byte(`{"components":[]}`))
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if _, ok := pl.(pluginapi.SystemPrompter); !ok {
		t.Error("must implement pluginapi.SystemPrompter")
	}
	if _, ok := pl.(pluginapi.HistoryTransformer); !ok {
		t.Error("must implement pluginapi.HistoryTransformer")
	}
	if _, ok := pl.(pluginapi.ContentRenderer); !ok {
		t.Error("must implement pluginapi.ContentRenderer")
	}
	if _, ok := pl.(pluginapi.Configurable); !ok {
		t.Error("must implement pluginapi.Configurable")
	}
}

// The components field is what every client renders. It was a JSON textarea
// with a hand-written form compiled into each app; the form is gone, so if
// this stops being a list with an element schema the plugin becomes
// unconfigurable rather than merely ugly.
func TestConfigFields_ComponentsIsAnEditableList(t *testing.T) {
	t.Parallel()
	d, err := pluginapi.Describe(Name)
	if err != nil {
		t.Fatalf("Describe: %v", err)
	}

	var components *pluginapi.ConfigField
	for i := range d.ConfigFields {
		if d.ConfigFields[i].Name == "components" {
			components = &d.ConfigFields[i]
		}
	}
	if components == nil {
		t.Fatal("no components field")
	}
	if components.Type != pluginapi.ConfigFieldList {
		t.Fatalf("components should be a list, got %q", components.Type)
	}

	byName := map[string]pluginapi.ConfigField{}
	for _, f := range components.ItemFields {
		byName[f.Name] = f
	}
	// These names are the stored JSON keys. Renaming one silently orphans
	// every existing definition, because the plugin decodes by tag.
	for _, want := range []string{"name", "component", "open_tag", "close_tag", "position", "instructions", "reminder_mode"} {
		if _, ok := byName[want]; !ok {
			t.Errorf("element schema is missing %q", want)
		}
	}

	// The enumerated fields must offer exactly the values the plugin accepts,
	// or the form can produce a config its own parser rejects.
	assertOptions := func(field string, want ...string) {
		t.Helper()
		got := map[string]bool{}
		for _, o := range byName[field].Options {
			got[o.Value] = true
		}
		for _, w := range want {
			if !got[w] {
				t.Errorf("%s is missing option %q", field, w)
			}
		}
		if len(got) != len(want) {
			t.Errorf("%s offers %d options, plugin accepts %d", field, len(got), len(want))
		}
	}
	assertOptions("reminder_mode", reminderModeNone, reminderModeAlways, reminderModeWhenAppropriate)
	assertOptions("position", "anywhere", "start", "end")
}

// Switching the field type must not orphan definitions written under the old
// textarea: the stored shape is the same array of objects either way.
func TestConfig_ExistingDefinitionsStillParse(t *testing.T) {
	t.Parallel()
	const legacy = `{"components":[{"name":"choices","component":"choice_list",` +
		`"open_tag":"<choices>","close_tag":"</choices>","position":"end",` +
		`"instructions":"Offer options.","reminder_mode":"always"}]}`
	p, err := newComponentBuilder([]byte(legacy))
	if err != nil {
		t.Fatalf("a config written before the list field must still parse: %v", err)
	}
	cb := p.(*componentBuilder)
	if len(cb.defs) != 1 || cb.defs[0].Name != "choices" {
		t.Errorf("definition did not survive: %+v", cb.defs)
	}
}

// onlyMsg unwraps a HistoryTransformer result that is expected to be a single
// message. The interface returns a slice so a transform can expand one stored
// message into several; every transform here rewrites in place.
func onlyMsg(t *testing.T, got []providers.WireMessage) providers.WireMessage {
	t.Helper()
	if len(got) != 1 {
		t.Fatalf("expected exactly 1 message, got %d", len(got))
	}
	return got[0]
}
