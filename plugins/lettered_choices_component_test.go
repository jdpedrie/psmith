package plugins

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestLetteredChoices_OutputModeDefaultsToText(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	if lc.cfg.OutputMode != lcOutputModeText {
		t.Errorf("OutputMode default = %q want %q", lc.cfg.OutputMode, lcOutputModeText)
	}
}

func TestLetteredChoices_InvalidOutputModeRejected(t *testing.T) {
	t.Parallel()
	if _, err := newLetteredChoices([]byte(`{"output_mode": "bogus"}`)); err == nil {
		t.Fatal("expected error for invalid output_mode")
	}
}

func TestLetteredChoices_ComponentMode_DisplayTransformerNoOp(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	body := "Pick one:\n<choices>\nA. Attack\nB. Flee\n</choices>"
	if got := lc.TransformForDisplay(body); got != body {
		t.Errorf("DisplayTransformer should be a no-op in component mode; got %q want %q", got, body)
	}
}

func TestLetteredChoices_TextMode_DisplayTransformerStripsDelimiters(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	body := "Pick one:\n<choices>\nA. Attack\nB. Flee\n</choices>"
	got := lc.TransformForDisplay(body)
	if strings.Contains(got, "<choices>") || strings.Contains(got, "</choices>") {
		t.Errorf("text mode should strip delimiters; got %q", got)
	}
}

func TestLetteredChoices_ComponentMode_EmitsChoiceListFragment(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	body := "Here are some options:\n<choices>{\"items\":[{\"label\":\"Attack\"},{\"label\":\"Flee\"},{\"label\":\"Negotiate\"}]}</choices>\nWhat's it gonna be?"
	parts := lc.RenderContent([]ContentPart{{Text: body}}, "assistant")
	if len(parts) != 3 {
		t.Fatalf("expected 3 parts (pre-text, fragment, post-text); got %d: %+v", len(parts), parts)
	}
	if !parts[0].IsText() || parts[0].Text != "Here are some options:" {
		t.Errorf("first part: %+v", parts[0])
	}
	if parts[1].Fragment == nil || parts[1].Fragment.Component != "choice_list" {
		t.Fatalf("middle part must be choice_list fragment; got %+v", parts[1])
	}
	if !parts[2].IsText() || parts[2].Text != "What's it gonna be?" {
		t.Errorf("trailing part: %+v", parts[2])
	}

	var props struct {
		Items []map[string]string `json:"items"`
	}
	if err := json.Unmarshal(parts[1].Fragment.Props, &props); err != nil {
		t.Fatalf("props decode: %v", err)
	}
	if len(props.Items) != 3 {
		t.Fatalf("expected 3 items; got %d: %+v", len(props.Items), props.Items)
	}
	want := []struct{ label, value, action string }{
		{"A. Attack", "A", "send:A"},
		{"B. Flee", "B", "send:B"},
		{"C. Negotiate", "C", "send:C"},
	}
	for i, w := range want {
		if props.Items[i]["label"] != w.label {
			t.Errorf("item[%d].label = %q want %q", i, props.Items[i]["label"], w.label)
		}
		if props.Items[i]["value"] != w.value {
			t.Errorf("item[%d].value = %q want %q", i, props.Items[i]["value"], w.value)
		}
		if props.Items[i]["action"] != w.action {
			t.Errorf("item[%d].action = %q want %q", i, props.Items[i]["action"], w.action)
		}
	}
}

func TestLetteredChoices_ComponentMode_TextBodyFallsBackToTextPart(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	// Common case: profile flipped from text mode to component mode,
	// historical messages still carry lettered-text bodies. Don't
	// hide them — render the body as a text part so the message
	// stays visible. Not interactive, but readable.
	body := "Prose. <choices>\nA. Attack\nB. Flee\n</choices> tail"
	parts := lc.RenderContent([]ContentPart{{Text: body}}, "assistant")
	for _, p := range parts {
		if p.Fragment != nil {
			t.Errorf("text-format body should not produce a fragment; got %+v", p.Fragment)
		}
	}
	// Body content should appear somewhere in the rendered parts.
	var combined string
	for _, p := range parts {
		if p.IsText() {
			combined += p.Text
		}
	}
	if !strings.Contains(combined, "A. Attack") || !strings.Contains(combined, "B. Flee") {
		t.Errorf("text-format body content missing from rendered parts; got %q", combined)
	}
}

func TestLetteredChoices_ComponentMode_EmptyItemsArrayDropped(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	body := `<choices>{"items":[]}</choices>`
	parts := lc.RenderContent([]ContentPart{{Text: body}}, "assistant")
	for _, p := range parts {
		if p.Fragment != nil {
			t.Errorf("expected no fragment for empty items; got %+v", p.Fragment)
		}
	}
}

func TestLetteredChoices_ComponentMode_AutoAssignsLettersByIndex(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	body := `<choices>{"items":[{"label":"first"},{"label":"second"},{"label":"third"},{"label":"fourth"}]}</choices>`
	parts := lc.RenderContent([]ContentPart{{Text: body}}, "assistant")
	if parts[0].Fragment == nil {
		t.Fatalf("expected fragment; got %+v", parts)
	}
	var props struct {
		Items []map[string]string `json:"items"`
	}
	mustDecodeJSON(t, parts[0].Fragment.Props, &props)
	for i, want := range []string{"A", "B", "C", "D"} {
		if props.Items[i]["value"] != want {
			t.Errorf("item[%d] letter: got %q want %q", i, props.Items[i]["value"], want)
		}
	}
}

func TestLetteredChoices_ComponentMode_SkipsNonAssistantRoles(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	parts := []ContentPart{{Text: "<choices>\nA. nope\n</choices>"}}
	for _, role := range []string{"user", "system", "context"} {
		got := lc.RenderContent(parts, role)
		if len(got) != 1 || got[0].Fragment != nil {
			t.Errorf("role %q should pass through unchanged; got %+v", role, got)
		}
	}
}

func TestLetteredChoices_TextMode_NoRenderer(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, "")
	body := "<choices>\nA. one\n</choices>"
	got := lc.RenderContent([]ContentPart{{Text: body}}, "assistant")
	if len(got) != 1 || got[0].Fragment != nil {
		t.Errorf("text mode should pass parts through unchanged; got %+v", got)
	}
}

func TestLetteredChoices_ComponentMode_UnmatchedOpenLeftInPlace(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	body := "Prose <choices>\nA. lonely open with no close"
	parts := lc.RenderContent([]ContentPart{{Text: body}}, "assistant")
	if len(parts) != 1 || !parts[0].IsText() {
		t.Fatalf("unmatched open should leave content as text; got %+v", parts)
	}
	if !strings.Contains(parts[0].Text, "<choices>") {
		t.Errorf("expected dangling open tag to remain in text; got %q", parts[0].Text)
	}
}

func mustDecodeJSON(t *testing.T, raw []byte, out any) {
	t.Helper()
	if err := json.Unmarshal(raw, out); err != nil {
		t.Fatalf("json decode: %v", err)
	}
}

func TestLetteredChoices_ComponentMode_MultipleBlocks(t *testing.T) {
	t.Parallel()
	lc := buildLetteredChoices(t, `{"output_mode": "component"}`)
	body := `first:
<choices>{"items":[{"label":"one"},{"label":"two"}]}</choices>
middle
<choices>{"items":[{"label":"three"}]}</choices>
tail`
	parts := lc.RenderContent([]ContentPart{{Text: body}}, "assistant")
	// Expect: [text "first:"] [frag] [text "middle"] [frag] [text "tail"]
	if len(parts) != 5 {
		t.Fatalf("expected 5 parts; got %d: %+v", len(parts), parts)
	}
	if parts[1].Fragment == nil || parts[3].Fragment == nil {
		t.Errorf("expected fragments at indices 1 + 3; got %+v", parts)
	}
}

// Describe-side: confirm component mode doesn't break the
// capability auto-derive (ContentRenderer interface presence) or
// the requirement-derivation path.
func TestLetteredChoices_ComponentMode_DescribeReportsContentRenderer(t *testing.T) {
	t.Parallel()
	// Build via Describe with nil config — that path uses the default
	// (text) mode. Component mode still implements ContentRenderer on
	// the same struct so the capability flag is true either way.
	desc, err := Describe(LetteredChoicesName)
	if err != nil {
		t.Fatalf("describe: %v", err)
	}
	if !desc.Capabilities.ContentRenderer {
		t.Error("expected ContentRenderer capability to be true (lettered_choices now implements it)")
	}
}
