package anthropic

import (
	"encoding/json"
	"strings"
)

// RenderThinkingToText converts the stored Anthropic thinking JSON blob
// into a deterministic plain-text rendering for cross-provider injection.
//
// Returns the empty string for nil/empty/malformed input — this function
// is called on the inbound persistence path and on every cross-provider
// history-build, and must never panic.
//
// Only "thinking" blocks contribute text. "redacted_thinking" entries are
// skipped because their payload is opaque/encrypted and has no plaintext.
func (d *Driver) RenderThinkingToText(thinking json.RawMessage) string {
	if len(thinking) == 0 {
		return ""
	}
	var parsed []thinkingPersisted
	if err := json.Unmarshal(thinking, &parsed); err != nil {
		return ""
	}
	var parts []string
	for _, t := range parsed {
		if t.Type == "thinking" && t.Thinking != "" {
			parts = append(parts, t.Thinking)
		}
	}
	return strings.Join(parts, "\n")
}
