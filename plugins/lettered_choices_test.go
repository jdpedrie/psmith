package plugins

import (
	"strings"
	"testing"

	"github.com/jdpedrie/reeve/internal/providers"
)

// buildLetteredChoices is a helper that constructs the registered plugin and
// returns it as the concrete type for direct method testing. This avoids
// rebuilding it in every test.
func buildLetteredChoices(t *testing.T, configJSON string) *letteredChoices {
	t.Helper()
	pl, err := newLetteredChoices([]byte(configJSON))
	if err != nil {
		t.Fatalf("newLetteredChoices: %v", err)
	}
	lc, ok := pl.(*letteredChoices)
	if !ok {
		t.Fatalf("expected *letteredChoices, got %T", pl)
	}
	return lc
}

// --- Constructor / config ---

func TestLetteredChoices_Defaults(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	if lc.cfg.KeepLastN != 1 {
		t.Errorf("KeepLastN default = %d want 1", lc.cfg.KeepLastN)
	}
	if lc.cfg.OpenTag != defaultLCOpenTag {
		t.Errorf("OpenTag default = %q want %q", lc.cfg.OpenTag, defaultLCOpenTag)
	}
	if lc.cfg.CloseTag != defaultLCCloseTag {
		t.Errorf("CloseTag default = %q want %q", lc.cfg.CloseTag, defaultLCCloseTag)
	}
}

func TestLetteredChoices_PartialConfigRetainsDefaults(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 3}`)
	if lc.cfg.KeepLastN != 3 {
		t.Errorf("KeepLastN = %d want 3", lc.cfg.KeepLastN)
	}
	if lc.cfg.OpenTag != defaultLCOpenTag {
		t.Errorf("OpenTag should fall back to default when omitted; got %q", lc.cfg.OpenTag)
	}
}

func TestLetteredChoices_NegativeKeepRejected(t *testing.T) {
	t.Parallel()
	if _, err := newLetteredChoices([]byte(`{"keep_last_n": -1}`)); err == nil {
		t.Fatal("expected error for negative keep_last_n")
	}
}

func TestLetteredChoices_InvalidJSONRejected(t *testing.T) {
	t.Parallel()
	if _, err := newLetteredChoices([]byte(`{not json`)); err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

// --- SystemPrompter ---

func TestLetteredChoices_AppendSystemMessageDefault(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	got := lc.AppendSystemMessage()
	if !strings.Contains(got, defaultLCOpenTag) || !strings.Contains(got, defaultLCCloseTag) {
		t.Errorf("system message should reference both delimiters; got %q", got)
	}
}

func TestLetteredChoices_AppendSystemMessageOverride(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"system_instruction_override": "use ONLY uppercase letters"}`)
	got := lc.AppendSystemMessage()
	if !strings.HasPrefix(got, "use ONLY uppercase letters") {
		t.Errorf("override not honored: got %q", got)
	}
	if !strings.Contains(got, "[system_reminder") {
		t.Errorf("system_reminder explainer missing: got %q", got)
	}
}

func TestLetteredChoices_AppendSystemMessageOverrideTemplateInterpolation(t *testing.T) {
	t.Parallel()
	cfg := `{
		"open_tag": "[opts]",
		"close_tag": "[/opts]",
		"system_instruction_override": "Wrap choices with {{.OpenTag}} and {{.CloseTag}} please."
	}`
	lc := buildLetteredChoices(t, cfg)
	got := lc.AppendSystemMessage()
	wantPrefix := "Wrap choices with [opts] and [/opts] please."
	if !strings.HasPrefix(got, wantPrefix) {
		t.Errorf("template not interpolated:\n  got:  %q\n  want prefix: %q", got, wantPrefix)
	}
}

func TestLetteredChoices_AppendSystemMessageDefaultUsesTemplate(t *testing.T) {
	t.Parallel()
	// Custom tags must propagate through the default template.
	cfg := `{"open_tag": "<<", "close_tag": ">>"}`
	lc := buildLetteredChoices(t, cfg)
	got := lc.AppendSystemMessage()
	if !strings.Contains(got, "<<") || !strings.Contains(got, ">>") {
		t.Errorf("custom delimiters didn't reach the default template; got %q", got)
	}
	// And the original {{.OpenTag}} placeholder should NOT appear
	// literally — that'd mean the template wasn't executed.
	if strings.Contains(got, "{{.OpenTag}}") {
		t.Errorf("template not executed; got literal placeholder: %q", got)
	}
}

func TestLetteredChoices_MalformedOverrideRejectedAtConstruction(t *testing.T) {
	t.Parallel()
	bad := `{"system_instruction_override": "{{ .NotClosed "}`
	if _, err := newLetteredChoices([]byte(bad)); err == nil {
		t.Error("malformed Go template in override should be rejected at constructor time")
	}
}

func TestLetteredChoices_PrependSystemMessageEmpty(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	if got := lc.PrependSystemMessage(); got != "" {
		t.Errorf("PrependSystemMessage should be empty; got %q", got)
	}
}

// --- HistoryTransformer ---

func TestLetteredChoices_HistoryTransformer_KeepRecent(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 1}`)

	msg := providers.WireMessage{
		Role:    "assistant",
		Content: "Body text.\n\n<choices>\nA) Yes\nB) No\n</choices>",
	}
	// FromHeadSameRole=0 = most recent assistant; KeepLastN=1 keeps it.
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 1, FromHeadSameRole: 0})
	if got.Content != msg.Content {
		t.Errorf("most-recent assistant should be untouched; got %q", got.Content)
	}
}

func TestLetteredChoices_HistoryTransformer_StripOlder(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 1}`)

	msg := providers.WireMessage{
		Role:    "assistant",
		Content: "Body text.\n\n<choices>\nA) Yes\nB) No\n</choices>",
	}
	// FromHeadSameRole=1 = the assistant turn before the most recent;
	// KeepLastN=1 strips it.
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 3, FromHeadSameRole: 1})
	want := "Body text."
	if got.Content != want {
		t.Errorf("older assistant strip = %q want %q", got.Content, want)
	}
}

func TestLetteredChoices_HistoryTransformer_KeepLastN_2KeepsTwo(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 2}`)
	msg := providers.WireMessage{
		Role:    "assistant",
		Content: "Body.\n\n<choices>A) X</choices>",
	}
	// FromHeadSameRole 0 and 1 are kept; 2 is stripped.
	for _, sr := range []int{0, 1} {
		got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 99, FromHeadSameRole: sr})
		if got.Content != msg.Content {
			t.Errorf("FromHeadSameRole=%d should be kept; got %q", sr, got.Content)
		}
	}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 99, FromHeadSameRole: 2})
	if got.Content != "Body." {
		t.Errorf("FromHeadSameRole=2 strip = %q want %q", got.Content, "Body.")
	}
}

func TestLetteredChoices_HistoryTransformer_OlderUserUntouched(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 0}`)
	msg := providers.WireMessage{
		Role:    "user",
		Content: "<choices>NOT MINE</choices>",
	}
	// User at FromHeadSameRole=5 is NOT the head user; choices-strip
	// logic only touches assistants, and the system-reminder tail only
	// goes on the head user — so older users are pass-through.
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 5, FromHeadSameRole: 5})
	if got.Content != msg.Content {
		t.Errorf("older user message should be untouched; got %q", got.Content)
	}
}

func TestLetteredChoices_HistoryTransformer_HeadUserGetsReminder(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, ``)
	msg := providers.WireMessage{Role: "user", Content: "what should I do?"}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 0, FromHeadSameRole: 0})
	if !strings.HasPrefix(got.Content, "what should I do?") {
		t.Errorf("original content must be preserved as the prefix; got %q", got.Content)
	}
	if !strings.Contains(got.Content, "[system_reminder Always generate choices") {
		t.Errorf("reminder tail missing on head user; got %q", got.Content)
	}
}

func TestLetteredChoices_HistoryTransformer_SecondUserNoReminder(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, ``)
	msg := providers.WireMessage{Role: "user", Content: "earlier turn"}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 2, FromHeadSameRole: 1})
	if got.Content != msg.Content {
		t.Errorf("non-head user must not receive the reminder; got %q", got.Content)
	}
}

func TestLetteredChoices_HistoryTransformer_NoTagsIsNoOp(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 0}`)
	msg := providers.WireMessage{Role: "assistant", Content: "Just narrative, no choices."}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 5, FromHeadSameRole: 5})
	if got.Content != msg.Content {
		t.Errorf("no-tags message should be unchanged; got %q", got.Content)
	}
}

func TestLetteredChoices_HistoryTransformer_UnmatchedOpenLeftAlone(t *testing.T) {
	t.Parallel()
	// If the model emitted an open tag but never closed it, strip nothing
	// rather than truncating to the end of the message.
	lc := buildLetteredChoices(t, `{"keep_last_n": 0}`)
	msg := providers.WireMessage{
		Role:    "assistant",
		Content: "Body. <choices>A) X (no close tag)",
	}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 5, FromHeadSameRole: 5})
	if got.Content != msg.Content {
		t.Errorf("unmatched open should be left alone; got %q", got.Content)
	}
}

func TestLetteredChoices_HistoryTransformer_MultipleBlocksAllStripped(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 0}`)
	msg := providers.WireMessage{
		Role: "assistant",
		Content: "Intro.\n\n<choices>A) one\nB) two</choices>\n\n" +
			"More body.\n\n<choices>X) alt\nY) other</choices>",
	}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 5, FromHeadSameRole: 5})
	want := "Intro.\n\nMore body."
	if got.Content != want {
		t.Errorf("multi-block strip = %q want %q", got.Content, want)
	}
}

func TestLetteredChoices_HistoryTransformer_CustomTags(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 0, "open_tag": "[[", "close_tag": "]]"}`)
	msg := providers.WireMessage{
		Role:    "assistant",
		Content: "Body.\n\n[[A) Yes\nB) No]]",
	}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 5, FromHeadSameRole: 5})
	want := "Body."
	if got.Content != want {
		t.Errorf("custom-tag strip = %q want %q", got.Content, want)
	}
}

// --- DisplayTransformer ---

func TestLetteredChoices_DisplayStripsTagsKeepsContent(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	got := lc.TransformForDisplay("Body.\n\n<choices>\nA) one\nB) two\n</choices>")
	want := "Body.\n\n\nA) one\nB) two\n"
	if got != want {
		t.Errorf("display strip = %q want %q", got, want)
	}
}

func TestLetteredChoices_DisplayCustomTags(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"open_tag": "[[", "close_tag": "]]"}`)
	got := lc.TransformForDisplay("Body. [[A) one]]")
	if got != "Body. A) one" {
		t.Errorf("display custom-tag strip = %q want %q", got, "Body. A) one")
	}
}

// --- Configurable ---

func TestLetteredChoices_ConfigFieldsCoverConfigShape(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	fields := lc.ConfigFields()
	if len(fields) != 5 {
		t.Fatalf("ConfigFields len = %d want 5", len(fields))
	}
	byName := map[string]ConfigField{}
	for _, f := range fields {
		byName[f.Name] = f
	}
	for _, want := range []string{"keep_last_n", "open_tag", "close_tag", "system_instruction_override", "output_mode"} {
		if _, ok := byName[want]; !ok {
			t.Errorf("ConfigFields missing %q", want)
		}
	}
	if byName["keep_last_n"].Type != ConfigFieldNumber {
		t.Errorf("keep_last_n type = %q want %q", byName["keep_last_n"].Type, ConfigFieldNumber)
	}
	if byName["system_instruction_override"].Type != ConfigFieldTextarea {
		t.Errorf("system_instruction_override type = %q want %q", byName["system_instruction_override"].Type, ConfigFieldTextarea)
	}
	if byName["system_instruction_override"].Default != nil {
		t.Errorf("system_instruction_override default = %v want nil", byName["system_instruction_override"].Default)
	}
	if byName["output_mode"].Type != ConfigFieldSelect {
		t.Errorf("output_mode type = %q want %q", byName["output_mode"].Type, ConfigFieldSelect)
	}
	if byName["output_mode"].Default != lcOutputModeText {
		t.Errorf("output_mode default = %v want %q", byName["output_mode"].Default, lcOutputModeText)
	}
}

// --- DisplayTransformer word-boundary preservation ---

func TestLetteredChoices_DisplayPreservesWordBoundaryAfterCloseTag(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	// Real-world regression: model emits choices block then resumes
	// prose without a separating space. Naive ReplaceAll would smash
	// the close tag into the next word.
	in := "You can <choices>A. Read B. Write</choices>What sounds good?"
	want := "You can A. Read B. Write What sounds good?"
	if got := lc.TransformForDisplay(in); got != want {
		t.Errorf("TransformForDisplay smashed word boundary\n got: %q\nwant: %q", got, want)
	}
}

func TestLetteredChoices_DisplayPreservesWordBoundaryBeforeOpenTag(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	in := "Sure thing<choices>A. one</choices> done"
	want := "Sure thing A. one done"
	if got := lc.TransformForDisplay(in); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestLetteredChoices_DisplayDoesNotPadExistingWhitespace(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	// When the model puts a space before/after tags, we shouldn't
	// promote it to a double space.
	in := "Prose. <choices>A. one</choices> more prose."
	want := "Prose. A. one more prose."
	if got := lc.TransformForDisplay(in); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestLetteredChoices_DisplayHandlesNewlineAdjacency(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	in := "Prose.\n<choices>\nA. one\n</choices>\nMore prose."
	want := "Prose.\n\nA. one\n\nMore prose."
	if got := lc.TransformForDisplay(in); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestLetteredChoices_DisplayHandlesTagAtBoundary(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	// Tag at start of string — no preceding char to pair with.
	in := "<choices>A. one</choices>tail"
	want := "A. one tail"
	if got := lc.TransformForDisplay(in); got != want {
		t.Errorf("start-boundary: got %q want %q", got, want)
	}
	// Tag at end of string — no following char to pair with.
	in2 := "head<choices>A. one</choices>"
	want2 := "head A. one"
	if got := lc.TransformForDisplay(in2); got != want2 {
		t.Errorf("end-boundary: got %q want %q", got, want2)
	}
}

// --- Registration ---

func TestLetteredChoices_RegisteredByDefault(t *testing.T) {
	t.Parallel()
	pl, err := Build(LetteredChoicesName, nil)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if pl.Name() != LetteredChoicesName {
		t.Errorf("name=%q want %q", pl.Name(), LetteredChoicesName)
	}
}
