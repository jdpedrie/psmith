package conversations

import (
	"strings"
	"testing"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/pluginapi"
	basicgrounding "github.com/jdpedrie/psmith/plugins/basic_grounding"
	letteredchoices "github.com/jdpedrie/psmith/plugins/lettered_choices"
)

func buildPluginForDisplay(t *testing.T, name, cfg string) pluginapi.Plugin {
	t.Helper()
	var raw []byte
	if cfg != "" {
		raw = []byte(cfg)
	}
	p, err := pluginapi.Build(name, raw)
	if err != nil {
		t.Fatalf("build %s: %v", name, err)
	}
	return p
}

// lettered_choices implements ContentRenderer whatever its mode, so the
// pipeline seeds a parts list even in text mode, where the renderer leaves
// the text untouched. That text carried the raw <choices> tags, clients
// prefer ui_fragments over display_content whenever it is set, and the
// delimiters the display transform had stripped were back on screen.
func TestApplyDisplay_TextModeChoicesStayOutOfFragments(t *testing.T) {
	t.Parallel()
	pipeline := pluginapi.Pipeline{buildPluginForDisplay(t, letteredchoices.Name, "")}
	msg := &psmithv1.Message{
		Role:    psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT,
		Content: "Pick one.\n\n<choices>\nA. Attack\nB. Flee\n</choices>",
	}

	applyDisplay(msg, pipeline)

	if strings.Contains(msg.DisplayContent, "choices>") {
		t.Errorf("delimiters must be stripped from DisplayContent: %q", msg.DisplayContent)
	}
	if !strings.Contains(msg.DisplayContent, "A. Attack") {
		t.Errorf("choice text must survive: %q", msg.DisplayContent)
	}
	if len(msg.UiFragments) != 0 {
		t.Errorf("no renderer produced a component, so ui_fragments must stay empty for the markdown fallback; got %v", msg.UiFragments)
	}
}

// Renderers read the original content, so the prose they hand back between
// fragments still carries whatever another plugin's DisplayTransformer
// strips from the fallback. The fragment view has to match the fallback.
func TestApplyDisplay_TextPartsGetDisplayTransforms(t *testing.T) {
	t.Parallel()
	pipeline := pluginapi.Pipeline{
		buildPluginForDisplay(t, basicgrounding.Name, ""),
		buildPluginForDisplay(t, letteredchoices.Name, `{"output_mode":"component"}`),
	}
	msg := &psmithv1.Message{
		Role: psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT,
		Content: "<grounding>\nDate: 2026-09-22\n</grounding>Pick one.\n" +
			`<choices>{"items":[{"label":"Attack"},{"label":"Flee"}]}</choices>`,
	}

	applyDisplay(msg, pipeline)

	if strings.Contains(msg.DisplayContent, "grounding>") || strings.Contains(msg.DisplayContent, "choices>") {
		t.Errorf("fallback must strip both plugins' tags: %q", msg.DisplayContent)
	}
	if !strings.Contains(msg.DisplayContent, "A. Attack") {
		t.Errorf("component-mode fallback must render the choices as lettered text: %q", msg.DisplayContent)
	}

	sawChoices := false
	for _, f := range msg.UiFragments {
		switch f.Component {
		case "choice_list":
			sawChoices = true
		case "text":
			if strings.Contains(string(f.Props), "grounding>") {
				t.Errorf("text fragment must get the same strip as the fallback: %s", f.Props)
			}
		}
	}
	if !sawChoices {
		t.Errorf("expected a choice_list fragment; got %v", msg.UiFragments)
	}
}
