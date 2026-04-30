package google

import (
	"encoding/json"
	"strings"
)

// RenderThinkingToText converts a stored Gemini thinking JSON blob to
// deterministic plain text.
//
// Stored shape (mirrors what Send writes to the messages.thinking column):
// a JSON array of part-shaped objects, each with a `text` field. We accept
// the same loose set of shapes the openai driver does so cross-provider
// migrations and hand-edits stay forgiving:
//
//  1. [{"type":"text","text":"..."}, ...]   (canonical)
//  2. [{"text":"..."}, ...]                  (no type discriminator)
//  3. ["a","b"]                              (bare strings)
//  4. {"text":"alone"}                       (single object)
//
// Returns the empty string for nil/empty/malformed input — never panics.
func (d *Driver) RenderThinkingToText(thinking json.RawMessage) string {
	return RenderThinkingToText(thinking)
}

// RenderThinkingToText is the package-level implementation, exposed so tests
// can exercise it without constructing a Driver.
func RenderThinkingToText(thinking json.RawMessage) string {
	if len(thinking) == 0 {
		return ""
	}

	// Array shapes (1, 2, 3).
	var arr []json.RawMessage
	if err := json.Unmarshal(thinking, &arr); err == nil {
		var parts []string
		for _, raw := range arr {
			// String first.
			var s string
			if err := json.Unmarshal(raw, &s); err == nil {
				if s = strings.TrimSpace(s); s != "" {
					parts = append(parts, s)
				}
				continue
			}
			// Object with text.
			var obj struct {
				Text string `json:"text"`
			}
			if err := json.Unmarshal(raw, &obj); err == nil {
				if t := strings.TrimSpace(obj.Text); t != "" {
					parts = append(parts, t)
				}
			}
		}
		return strings.Join(parts, "\n\n")
	}

	// Single-object shape (4).
	var single struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(thinking, &single); err == nil {
		return strings.TrimSpace(single.Text)
	}
	return ""
}
