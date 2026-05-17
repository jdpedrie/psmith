package plugins

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestComponentBuilder_SceneHeaderRepro mirrors the user-reported
// shape: component "key_value", tags "<scene_header>" / "</scene_header>",
// body is a multi-line JSON object with the same key set the user is
// emitting in production. If this passes but the user still sees raw
// text in the bubble, the bug is downstream (read path / persistence
// / client decode); if it fails, the bug is in the renderer.
func TestComponentBuilder_SceneHeaderRepro(t *testing.T) {
	t.Parallel()
	cfg := `{"components":[{"name":"Scene Header","component":"key_value","open_tag":"<scene_header>","close_tag":"</scene_header>","instructions":"Output the scene orientation as key-value pairs."}]}`
	cb := buildComponentBuilder(t, cfg)

	body := "<scene_header>\n{\n  \"Location\": \"Langley, Virginia — CIA Headquarters, Room 6B-14\",\n  \"Interaction Level\": \"/4\",\n  \"Time\": \"Tuesday, October 12, 2024 — 14:00\",\n  \"Atmosphere\": \"Flat fluorescent lighting, cold air circulating from a humming HVAC vent, the smell of stale coffee.\",\n  \"Present\": \"Paige Fuller (MC, POV), Section Chief David Hayes, Arthur Caldwell (Unidentified)\",\n  \"Surface State\": \"Hayes: resting both hands flat on a closed manila folder; Caldwell: leaning back in his chair, watching Paige's face.\"\n}\n</scene_header>\n\nThe HVAC vent above the table produces a steady, tuneless hum."

	out := cb.RenderContent([]ContentPart{NewTextPart(body)}, "assistant")
	t.Logf("part count: %d", len(out))
	for i, p := range out {
		if p.IsText() {
			t.Logf("part[%d] TEXT (%d chars): %.80q", i, len(p.Text), p.Text)
		} else if p.Fragment != nil {
			t.Logf("part[%d] FRAGMENT component=%q props=%.120q", i, p.Fragment.Component, string(p.Fragment.Props))
		}
	}

	// Expect: optional empty leading text (dropped), then a key_value
	// fragment, then trailing prose text.
	var sawKeyValue bool
	for _, p := range out {
		if p.Fragment != nil && p.Fragment.Component == "key_value" {
			sawKeyValue = true
			// Confirm props parse and carry the keys we emitted.
			var props map[string]any
			if err := json.Unmarshal(p.Fragment.Props, &props); err != nil {
				t.Errorf("fragment props don't parse as JSON: %v\nraw: %s", err, string(p.Fragment.Props))
				continue
			}
			if _, ok := props["Location"]; !ok {
				t.Errorf("fragment props missing 'Location' key: %v", props)
			}
		}
	}
	if !sawKeyValue {
		t.Errorf("no key_value fragment emitted — body fell into the keep-as-text path. Parts: %d", len(out))
	}

	// And confirm trailing prose survived.
	var sawProse bool
	for _, p := range out {
		if p.IsText() && strings.Contains(p.Text, "HVAC vent above") {
			sawProse = true
			break
		}
	}
	if !sawProse {
		t.Errorf("trailing prose missing from output parts")
	}
}
