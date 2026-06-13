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
	if lc.cfg.OutputMode != lcOutputModeText {
		t.Errorf("OutputMode default = %q want %q", lc.cfg.OutputMode, lcOutputModeText)
	}
}

func TestLetteredChoices_PartialConfigRetainsDefaults(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 3}`)
	if lc.cfg.KeepLastN != 3 {
		t.Errorf("KeepLastN = %d want 3", lc.cfg.KeepLastN)
	}
	if lc.cfg.OutputMode != lcOutputModeText {
		t.Errorf("OutputMode should fall back to default when omitted; got %q", lc.cfg.OutputMode)
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
	if !strings.Contains(got, lcOpenTag) || !strings.Contains(got, lcCloseTag) {
		t.Errorf("system message should reference both delimiters; got %q", got)
	}
	if !strings.HasPrefix(got, defaultLCInstruction) {
		t.Errorf("default instruction prose should lead the message; got %q", got)
	}
}

func TestLetteredChoices_AppendSystemMessageOverride(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"system_instruction_override": "use ONLY uppercase letters"}`)
	got := lc.AppendSystemMessage()
	if !strings.HasPrefix(got, "use ONLY uppercase letters") {
		t.Errorf("override not honored: got %q", got)
	}
	// Tag mechanics footer must still be appended after the user's prose.
	if !strings.Contains(got, lcOpenTag) {
		t.Errorf("tag footer should still be appended after override; got %q", got)
	}
	if !strings.Contains(got, "[system_reminder") {
		t.Errorf("system_reminder explainer missing: got %q", got)
	}
}

func TestLetteredChoices_AppendSystemMessage_ComponentModeUsesJSONFooter(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode":"component"}`)
	got := lc.AppendSystemMessage()
	if !strings.Contains(got, `"items"`) {
		t.Errorf("component-mode footer should teach the JSON shape; got %q", got)
	}
	if !strings.Contains(got, `"label"`) {
		t.Errorf("component-mode footer should mention label field; got %q", got)
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

func TestLetteredChoices_HistoryTransformer_AnthropicNeverStrips(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 1}`)

	msg := providers.WireMessage{
		Role:    "assistant",
		Content: "Body text.\n\n<choices>\nA) Yes\nB) No\n</choices>",
	}
	// An older assistant turn that would normally be stripped — but on
	// Anthropic the choice block is kept intact so the prompt-cache
	// prefix stays byte-stable.
	got := lc.TransformHistoryMessage(msg, HistoryPos{
		FromHead:         3,
		FromHeadSameRole: 1,
		DestProviderType: "anthropic",
	})
	if got.Content != msg.Content {
		t.Errorf("Anthropic should never strip; got %q want unchanged", got.Content)
	}

	// Same position on a non-Anthropic provider still strips.
	got = lc.TransformHistoryMessage(msg, HistoryPos{
		FromHead:         3,
		FromHeadSameRole: 1,
		DestProviderType: "openai-compatible",
	})
	if got.Content != "Body text." {
		t.Errorf("non-Anthropic strip = %q want %q", got.Content, "Body text.")
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

// Text mode encountering an old message that was generated under
// component mode (JSON body) should render lettered text inline
// instead of raw JSON.
func TestLetteredChoices_DisplayRewritesJSONBodyAsLettered(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	in := `Pick:<choices>{"items":[{"label":"Read"},{"label":"Write"},{"label":"Code"}]}</choices>`
	got := lc.TransformForDisplay(in)
	if strings.Contains(got, `"items"`) {
		t.Errorf("raw JSON should be replaced with lettered text; got %q", got)
	}
	for _, want := range []string{"A. Read", "B. Write", "C. Code"} {
		if !strings.Contains(got, want) {
			t.Errorf("lettered output missing %q in: %q", want, got)
		}
	}
}

func TestLetteredChoices_DisplayLeavesLetteredBodyAlone(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	in := "Pick:\n<choices>\nA. Read\nB. Write\n</choices>"
	got := lc.TransformForDisplay(in)
	for _, want := range []string{"A. Read", "B. Write"} {
		if !strings.Contains(got, want) {
			t.Errorf("lettered body should pass through unchanged; missing %q in: %q", want, got)
		}
	}
}

// --- Configurable ---

func TestLetteredChoices_ConfigFieldsCoverConfigShape(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	fields := lc.ConfigFields()
	if len(fields) != 3 {
		t.Fatalf("ConfigFields len = %d want 3", len(fields))
	}
	byName := map[string]ConfigField{}
	for _, f := range fields {
		byName[f.Name] = f
	}
	for _, want := range []string{"keep_last_n", "system_instruction_override", "output_mode"} {
		if _, ok := byName[want]; !ok {
			t.Errorf("ConfigFields missing %q", want)
		}
	}
	// Tag fields should NOT be configurable any more.
	for _, gone := range []string{"open_tag", "close_tag"} {
		if _, ok := byName[gone]; ok {
			t.Errorf("ConfigFields still exposes removed field %q", gone)
		}
	}
	if byName["keep_last_n"].Type != ConfigFieldNumber {
		t.Errorf("keep_last_n type = %q want %q", byName["keep_last_n"].Type, ConfigFieldNumber)
	}
	if byName["system_instruction_override"].Type != ConfigFieldTextarea {
		t.Errorf("system_instruction_override type = %q want %q", byName["system_instruction_override"].Type, ConfigFieldTextarea)
	}
	// Pre-populated with the default prose so the form is editable
	// from a starting point rather than blank.
	if byName["system_instruction_override"].Default != defaultLCInstruction {
		t.Errorf("system_instruction_override default = %v want %q", byName["system_instruction_override"].Default, defaultLCInstruction)
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
