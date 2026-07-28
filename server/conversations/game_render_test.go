package conversations

import (
	"strings"
	"testing"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/pluginapi"
	gamemaster "github.com/jdpedrie/psmith/plugins/game_master"
)

// A plugin that both strips a block for the flat fallback and renders it as
// components must get both. Feeding the renderer the already-stripped text
// meant game_master's choices were removed from DisplayContent and no
// fragment replaced them: the block was simply invisible.
func TestApplyDisplay_RendererSeesBlockStrippedFromDisplayContent(t *testing.T) {
	t.Parallel()

	gm, err := pluginapi.Build(gamemaster.Name, []byte(`{"show_odds":true}`))
	if err != nil {
		t.Fatalf("build game_master: %v", err)
	}
	pipeline := pluginapi.Pipeline{gm}

	// Matches gameBlock: flat, choices at the top level, situation a string.
	const block = `{"turn":3,"situation":"The Muster",` +
		`"stats":[{"label":"Treasury","value":800}],` +
		`"choices":[{"id":"A","label":"Send envoys","favorable":62,"disaster":9},` +
		`{"id":"B","label":"Call the levy","favorable":31,"disaster":22}],` +
		`"show_odds":true}`
	msg := &psmithv1.Message{
		Role:    psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT,
		Content: "The north stirs.\n\n<psmith_game>" + block + "</psmith_game>",
	}

	applyDisplay(msg, pipeline)

	if strings.Contains(msg.DisplayContent, "psmith_game") {
		t.Errorf("the raw block must not survive into DisplayContent: %q", msg.DisplayContent)
	}
	if !strings.Contains(msg.DisplayContent, "The north stirs.") {
		t.Errorf("prose must survive: %q", msg.DisplayContent)
	}

	var components []string
	for _, f := range msg.UiFragments {
		components = append(components, f.Component)
	}
	found := false
	for _, c := range components {
		if c == "choice_list" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a choice_list fragment so the choices are visible; got %v", components)
	}
}
