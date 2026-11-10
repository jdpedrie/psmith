package pluginapi

import (
	"context"
	"testing"
)

type splitRenderer struct{ name string }

func (r splitRenderer) Name() string        { return r.name }
func (r splitRenderer) DisplayName() string { return r.name }
func (r splitRenderer) Description() string { return "" }
func (r splitRenderer) RenderContent(parts []ContentPart, _ string) []ContentPart {
	return append(parts, NewFragmentPart("choice_list", []byte(`{"items":[]}`), r.name))
}

type withPanel struct{ splitRenderer }

func (withPanel) Panel() PanelDescriptor                             { return PanelDescriptor{} }
func (withPanel) RenderPanel(context.Context) ([]ContentPart, error) { return nil, nil }

// Each fragment records the plugin that added it, and a later renderer
// doesn't take credit for an earlier one's.
func TestRenderContent_StampsTheAuthor(t *testing.T) {
	parts := Pipeline{splitRenderer{"first"}, splitRenderer{"second"}}.RenderContent("hi", "assistant")
	var got []string
	for _, p := range parts {
		if p.Fragment != nil {
			got = append(got, p.Fragment.Plugin)
		}
	}
	if len(got) != 2 || got[0] != "first" || got[1] != "second" {
		t.Errorf("fragment authors = %v", got)
	}
}

func TestHasPanel(t *testing.T) {
	p := Pipeline{splitRenderer{"plain"}, withPanel{splitRenderer{"paneled"}}}
	if p.HasPanel("plain") || !p.HasPanel("paneled") || p.HasPanel("absent") {
		t.Error("HasPanel answered wrong")
	}
}
