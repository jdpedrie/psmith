package openai

import (
	"encoding/json"
	"strings"
)

// RenderThinkingToText converts a stored thinking JSON blob to plain text
// for cross-provider injection.
//
// The accepted shapes (in order of preference) match what we might write
// to the messages.thinking column for an openai-compatible turn:
//
//  1. A Responses-API reasoning item:
//     {"id":"rs_...","type":"reasoning","summary":[
//     {"type":"summary_text","text":"..."},
//     {"type":"summary_text","text":"..."}]}
//
//  2. A bare list of summary strings (forward-compat):
//     ["thought one","thought two"]
//
//  3. A bare list of summary-text objects (alternate writers):
//     [{"text":"..."},{"text":"..."}]
//
//  4. A single object with a top-level "text" field.
//
// Anything else (nil, empty, malformed, or an unrecognized shape) returns
// the empty string. No panics for any input.
func (d *Driver) RenderThinkingToText(thinking json.RawMessage) string {
	return RenderThinkingToText(thinking)
}

// RenderThinkingToText is the package-level implementation, exposed so
// tests can exercise it without constructing a Driver.
func RenderThinkingToText(thinking json.RawMessage) string {
	if len(thinking) == 0 {
		return ""
	}

	// Shape 1: full reasoning item.
	var reasoning struct {
		Type    string `json:"type"`
		Summary []struct {
			Text string `json:"text"`
			Type string `json:"type"`
		} `json:"summary"`
	}
	if err := json.Unmarshal(thinking, &reasoning); err == nil && reasoning.Type == "reasoning" {
		return joinSummary(reasoning.Summary)
	}

	// Shape 2 & 3: array.
	var arr []json.RawMessage
	if err := json.Unmarshal(thinking, &arr); err == nil {
		var parts []string
		for _, raw := range arr {
			// Try string first.
			var s string
			if err := json.Unmarshal(raw, &s); err == nil {
				if s = strings.TrimSpace(s); s != "" {
					parts = append(parts, s)
				}
				continue
			}
			// Then object with text.
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

	// Shape 4: object with bare text.
	var single struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(thinking, &single); err == nil {
		return strings.TrimSpace(single.Text)
	}

	return ""
}

func joinSummary(parts []struct {
	Text string `json:"text"`
	Type string `json:"type"`
}) string {
	var out []string
	for _, p := range parts {
		if t := strings.TrimSpace(p.Text); t != "" {
			out = append(out, t)
		}
	}
	return strings.Join(out, "\n\n")
}
