package plugins

import (
	"strings"
	"testing"

	"github.com/jdpedrie/clark/internal/providers"
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
	if got != "use ONLY uppercase letters" {
		t.Errorf("override not honored: got %q", got)
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

func TestLetteredChoices_HistoryTransformer_NonAssistantUntouched(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"keep_last_n": 0}`)
	msg := providers.WireMessage{
		Role:    "user",
		Content: "<choices>NOT MINE</choices>",
	}
	got := lc.TransformHistoryMessage(msg, HistoryPos{FromHead: 5, FromHeadSameRole: 5})
	if got.Content != msg.Content {
		t.Errorf("user message should be untouched; got %q", got.Content)
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

func TestLetteredChoices_ConfigSchemaIsValidJSON(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	schema := lc.ConfigSchema()
	if len(schema) == 0 {
		t.Fatal("ConfigSchema returned empty bytes")
	}
	// Sanity: schema mentions every config field by name.
	for _, want := range []string{"keep_last_n", "open_tag", "close_tag", "system_instruction_override"} {
		if !strings.Contains(string(schema), want) {
			t.Errorf("schema missing field %q", want)
		}
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
