package profiles

import (
	"fmt"
	"strings"
)

// SeedDoc is one parsed system-profile template file. The format is a
// minimal YAML-flavored frontmatter header (between `---` delimiters)
// followed by a Markdown body. The body becomes the system message; the
// header carries every other field.
//
// Example:
//
//	---
//	welcome_message: |
//	  Hello! I'm your personal assistant. What can I help with today?
//	---
//	# System message body here
//	You are a personal assistant...
//
// Files with no frontmatter (legacy single-field shape) are treated as
// a pure system message — backward compatibility for the original
// seed format.
type SeedDoc struct {
	SystemMessage  string
	WelcomeMessage string
}

// parseSeed parses a seed file. The minimal subset of YAML supported:
//   - `key: value` — single-line scalar
//   - `key: |` followed by 2-space-indented lines — block scalar (newlines preserved)
//
// Anything else in the header is silently ignored (the validation that
// matters happens at the profile-create call site).
//
// Errors are returned only for unparseable shapes (e.g. opening `---`
// with no close) — a typo'd key falls through.
func parseSeed(raw string) (SeedDoc, error) {
	raw = strings.TrimLeft(raw, "\r\n")
	var doc SeedDoc
	if !strings.HasPrefix(raw, "---\n") {
		// No frontmatter — entire file is the system message.
		doc.SystemMessage = strings.TrimRight(raw, "\n\r ")
		return doc, nil
	}
	rest := raw[len("---\n"):]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return doc, fmt.Errorf("seed: missing frontmatter close delimiter")
	}
	header := rest[:end]
	body := rest[end+len("\n---"):]
	body = strings.TrimLeft(body, "\n\r ")
	doc.SystemMessage = strings.TrimRight(body, "\n\r ")

	lines := strings.Split(header, "\n")
	i := 0
	for i < len(lines) {
		line := lines[i]
		i++
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		colon := strings.Index(line, ":")
		if colon < 0 {
			return doc, fmt.Errorf("seed: malformed header line %q", line)
		}
		key := strings.TrimSpace(line[:colon])
		val := strings.TrimSpace(line[colon+1:])

		// Block scalar (`|`) — consume subsequent 2-space-indented lines.
		// Blank lines inside the block are preserved verbatim.
		if val == "|" {
			var sb strings.Builder
			for i < len(lines) {
				next := lines[i]
				if next == "" {
					sb.WriteByte('\n')
					i++
					continue
				}
				if !strings.HasPrefix(next, "  ") {
					break
				}
				// Always insert a newline before content (except the
				// first emitted line). Blank lines above already
				// inserted their own newline; this one separates the
				// new content from whatever came before.
				if sb.Len() > 0 {
					sb.WriteByte('\n')
				}
				sb.WriteString(strings.TrimPrefix(next, "  "))
				i++
			}
			val = strings.TrimRight(sb.String(), "\n\r ")
		}

		switch key {
		case "welcome_message":
			doc.WelcomeMessage = val
		case "system_message":
			// Allowed for completeness, but the body is usually the system
			// message — `system_message:` in frontmatter wins if both present.
			doc.SystemMessage = val
		default:
			// Unknown keys are silently ignored. Future fields just add
			// cases above; old seed files keep working.
		}
	}
	return doc, nil
}

// mustParseSeed is a panic-on-error variant for build-time embeds.
// Used in package-level var initializers where a parse error means
// the binary should never start in the first place.
func mustParseSeed(raw string) SeedDoc {
	doc, err := parseSeed(raw)
	if err != nil {
		panic("profiles: invalid seed file: " + err.Error())
	}
	return doc
}
