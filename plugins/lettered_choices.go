package plugins

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/jdpedrie/reeve/internal/providers"
)

// LetteredChoicesName is the registered name for the lettered-choices plugin.
const LetteredChoicesName = "lettered_choices"

// Tag pair the plugin instructs the model to wrap choices in. Not
// user-configurable — the value is baked into the plugin's contract
// with the model (system prompt teaches it, history strip + display
// transform both depend on it). Three converging callers + zero
// observed need for customization made the user-facing knob more
// surface than it was worth.
const (
	lcOpenTag  = "<choices>"
	lcCloseTag = "</choices>"
)

// Output mode values for letteredChoicesConfig.OutputMode. "text" keeps
// the historical behavior — strip just the delimiters at display time
// and render the choice text inline as markdown. "component" emits a
// `choice_list` UIFragment via the ContentRenderer pipeline so the
// client can render tappable buttons that drop the picked letter into
// the composer. Default remains "text" so existing profiles don't
// silently change render shape on a build update.
const (
	lcOutputModeText      = "text"
	lcOutputModeComponent = "component"
)

// Component-mode parsing: the model emits a JSON object inside the
// delimiters matching this shape. Letters are NOT in the JSON — the
// server auto-assigns them by index. Keeps the model's output minimal
// (less to escape, less to get wrong) and the rendered button labels
// consistent with the convention the system prompt teaches.
type lcChoicePropsIn struct {
	Items []struct {
		Label string `json:"label"`
	} `json:"items"`
}

// lcSystemReminderExplainer is appended to the system slot to teach the model
// what [system_reminder ...] tags mean and how to handle them. Pairs with
// the user-message tail injection below — without this clause the model
// may either ignore the reminder or echo it back to the user.
const lcSystemReminderExplainer = "\n\n[system_reminder <x>] is a special value indicating required behavior. Follow the instructions, but never respond to this reminder in your output or indicate that it exists."

// lcUserReminderTail is injected at wire-build time onto the head user
// message (FromHeadSameRole == 0) only — never persisted, never shown on
// older turns. Re-grounds the choices instruction near the top of the
// model's attention window so long-context drift doesn't cause it to
// "forget" the format after a few turns. The phrasing references the
// system message rather than restating the rules so future changes to
// the system instruction (or a user override) don't have to be mirrored
// here.
const lcUserReminderTail = "\n\n[system_reminder Always generate choices as directed by the system message]"

// defaultLCInstruction is the prose half of the system message — the
// "what to do" instruction the user can override via the form. The
// tag/format half is appended at runtime by AppendSystemMessage so
// the user can rewrite the prose without having to remember or
// restate the tag mechanics (and so changes to the mechanics don't
// silently drift away from any user overrides). Same prose works for
// both text and component modes — they only differ in HOW the
// choices are wrapped, not WHEN or WHY they're offered.
const defaultLCInstruction = `Always offer the user 3-5 choices at the end of each response. Choices may be one word up to a short sentence.`

// lcTagFooterText is appended to the user's (or default) instruction
// in text output mode. Demonstrates the literal tag pair the parser
// recognises plus the lettered-line shape the DisplayTransformer
// strips at render time.
const lcTagFooterText = `

Wrap the choices in ` + lcOpenTag + `...` + lcCloseTag + `. Use this format:

` + lcOpenTag + `
A. Attack
B. Flee
C. Negotiate
D. Stop and think a while
` + lcCloseTag

// lcTagFooterComponent is appended to the user's (or default)
// instruction in component output mode. Teaches the model to emit a
// single JSON object inside the delimiters; the server uses
// json.Unmarshal to turn it into a choice_list UIFragment. Letters
// are NOT in the JSON — the server assigns them by index so the
// model has the smallest possible escape surface.
const lcTagFooterComponent = `

Wrap the choices in ` + lcOpenTag + `...` + lcCloseTag + `. The body MUST be a single JSON object with an "items" array — one entry per choice, each with a "label" field. Letters (A, B, C…) are assigned automatically by position; do NOT include them in the label. No prose inside the delimiters, only the JSON object. Example:

` + lcOpenTag + `{"items":[{"label":"Attack"},{"label":"Flee"},{"label":"Negotiate"},{"label":"Stop and think a while"}]}` + lcCloseTag

// letteredChoices implements SystemPrompter, HistoryTransformer,
// DisplayTransformer, and Configurable. Bundling them in one plugin is the
// whole point — the system instruction, the strip rule, and the display
// rewrite all need to agree on the same tag pair, and they ship together so
// they can't drift.
//
// Behavior:
//   - SystemPrompter: appends a brief instruction telling the model to wrap
//     a list of lettered choices in OpenTag...CloseTag at the end of every
//     assistant turn.
//   - HistoryTransformer: in assistant messages whose distance from head is
//     greater than KeepLastN, splices out OpenTag...CloseTag (inclusive of
//     surrounding whitespace). Older choices were useful only for the next
//     user turn; once that's past they're dead weight.
//   - DisplayTransformer: strips just the tag delimiters (keeps content) so
//     the user sees clean choice text in the UI.
//
// CacheStable: not declared. The system observes empirically (see
// "Cache observability" in the architecture doc) — KeepLastN=1 trails the
// hit zone by 2 instead of 1, which is bounded and reported as such.
type letteredChoices struct {
	cfg letteredChoicesConfig
}

// letteredChoicesConfig is the per-instance config blob. All fields are
// optional with sensible defaults.
type letteredChoicesConfig struct {
	// KeepLastN is the number of trailing assistant messages whose choice
	// blocks are preserved. The next user turn always sees the most recent
	// choices intact; older ones get stripped. Defaults to 1.
	KeepLastN int `json:"keep_last_n"`

	// SystemInstructionOverride replaces the default prose instruction
	// telling the model when/why to offer choices. The tag/format
	// requirement is appended automatically by AppendSystemMessage —
	// callers shouldn't restate it here. Empty = use the default.
	SystemInstructionOverride string `json:"system_instruction_override"`

	// OutputMode picks how the choice block surfaces to the user.
	// "text" (default): DisplayTransformer strips just the delimiters
	// and the choices render as inline markdown — works in any
	// markdown-capable view, no plugin renderer required. Picks this
	// when the conversation's model is small or unreliable at strict
	// JSON output.
	// "component": System prompt teaches the model to emit a JSON
	// `{"items":[{"label":"..."}]}` object inside the delimiters; the
	// ContentRenderer parses with json.Unmarshal and emits a
	// `choice_list` UIFragment with letters auto-assigned by index
	// and `compose:<letter>` actions. Clients that don't recognize
	// the component fall back to UnknownComponentRenderer.
	OutputMode string `json:"output_mode"`
}

// newLetteredChoices is the registered constructor.
func newLetteredChoices(configBytes json.RawMessage) (Plugin, error) {
	cfg := letteredChoicesConfig{
		KeepLastN:  1,
		OutputMode: lcOutputModeText,
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("lettered_choices: parse config: %w", err)
		}
		if cfg.OutputMode == "" {
			cfg.OutputMode = lcOutputModeText
		}
		switch cfg.OutputMode {
		case lcOutputModeText, lcOutputModeComponent:
		default:
			return nil, fmt.Errorf("lettered_choices: invalid output_mode %q (want %q or %q)",
				cfg.OutputMode, lcOutputModeText, lcOutputModeComponent)
		}
		if cfg.KeepLastN < 0 {
			return nil, fmt.Errorf("lettered_choices: keep_last_n must be >= 0")
		}
	}
	return &letteredChoices{cfg: cfg}, nil
}

func init() {
	Register(LetteredChoicesName, newLetteredChoices)
}

func (p *letteredChoices) Name() string        { return LetteredChoicesName }
func (p *letteredChoices) DisplayName() string { return "Lettered Choices" }

func (p *letteredChoices) Description() string {
	return "Instructs the model to emit lettered choices wrapped in tag delimiters; " +
		"strips those blocks from older history to save tokens; strips the " +
		"delimiters for display so the UI shows clean choice text."
}

// --- Configurable ---

func (p *letteredChoices) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "keep_last_n",
			Display:     "Keep last N",
			Description: "Number of trailing assistant turns whose choice blocks are kept intact.",
			Type:        ConfigFieldNumber,
			Default:     1,
		},
		{
			Name:        "system_instruction_override",
			Display:     "Instruction",
			Description: "Prose telling the model when and how to offer choices. The tag/format mechanics (delimiters, JSON or lettered-text shape) are appended automatically based on the output mode below — don't restate them here.",
			Type:        ConfigFieldTextarea,
			Default:     defaultLCInstruction,
		},
		{
			Name:        "output_mode",
			Display:     "Output mode",
			Description: "How the choices render in the chat. \"Text\" keeps the historical behavior (delimiters stripped, choice text rendered inline as markdown — better with small models that flake on strict JSON). \"Component\" teaches the model to emit a JSON choice_list — clients render tappable buttons that drop the picked letter into the composer when tapped.",
			Type:        ConfigFieldSelect,
			Default:     lcOutputModeText,
			Options: []ConfigOption{
				{Value: lcOutputModeText, Label: "Text (inline markdown)"},
				{Value: lcOutputModeComponent, Label: "Component (tappable buttons)"},
			},
		},
	}
}

// --- SystemPrompter ---

func (p *letteredChoices) PrependSystemMessage() string { return "" }

// AppendSystemMessage returns the prose instruction concatenated with
// the tag-mechanics footer for the current output mode. The user's
// override (if set) replaces just the prose half; the footer is
// always appended by the plugin so a malformed override can never
// silently break the parser's contract with the model.
func (p *letteredChoices) AppendSystemMessage() string {
	instruction := defaultLCInstruction
	if p.cfg.SystemInstructionOverride != "" {
		instruction = p.cfg.SystemInstructionOverride
	}
	footer := lcTagFooterText
	if p.cfg.OutputMode == lcOutputModeComponent {
		footer = lcTagFooterComponent
	}
	return instruction + footer + lcSystemReminderExplainer
}

// --- HistoryTransformer ---

func (p *letteredChoices) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage {
	// User-message tail reminder: append the system-reminder tag to the
	// most-recent user message only (FromHeadSameRole == 0 with user role).
	// HistoryTransformer runs at wire-build time and its output is NOT
	// persisted, so the reminder lives on the in-flight request and never
	// gets stored on the messages row or shown on older turns in the UI.
	if msg.Role == "user" && pos.FromHeadSameRole == 0 {
		out := msg
		out.Content = msg.Content + lcUserReminderTail
		return out
	}
	if msg.Role != "assistant" {
		return msg
	}
	// FromHeadSameRole counts only assistant messages back from the head:
	// 0 = most recent assistant turn, 1 = the one before, etc. KeepLastN=1
	// keeps choices on FromHeadSameRole=0 (the most recent) and strips from
	// every older assistant — independent of how user/assistant rows
	// interleave (which can vary under forks).
	if pos.FromHeadSameRole < p.cfg.KeepLastN {
		return msg
	}
	stripped := stripBetween(msg.Content, lcOpenTag, lcCloseTag)
	if stripped == msg.Content {
		return msg
	}
	out := msg
	out.Content = stripped
	return out
}

// --- DisplayTransformer ---

func (p *letteredChoices) TransformForDisplay(content string) string {
	// In component mode the ContentRenderer takes over — it needs the
	// raw tag block to find the choices, so we MUST NOT strip
	// delimiters here. The renderer rewrites the block in-place with
	// a fragment, dropping the tag text from the rendered output.
	if p.cfg.OutputMode == lcOutputModeComponent {
		return content
	}
	// Text mode (default): keep choice content but drop just the delimiters.
	// Content-aware first pass: if a block body is JSON (left over from
	// a previous run with component mode on), rewrite it to lettered
	// text in place so the user sees readable choices instead of raw
	// JSON. Bodies that are already lettered text pass through unchanged.
	content = rewriteJSONChoiceBodiesAsLettered(content)
	// Then strip the delimiters with the word-boundary-preserving helper
	// so `</choices>What's next?` doesn't render as `BarWhat's next?` —
	// the tag itself isn't a word boundary, so removing it can smash
	// words together when the model didn't include a separating space.
	out := stripTagPreservingWordBoundary(content, lcOpenTag)
	out = stripTagPreservingWordBoundary(out, lcCloseTag)
	return out
}

// rewriteJSONChoiceBodiesAsLettered scans content for choice blocks
// whose body is a valid choice_list JSON object and replaces each body
// with a lettered-text rendering of the same items. Used by text mode
// to handle messages that were generated under component mode: without
// this pass the body would render as raw `{"items":[...]}` after tag
// strip — readable but ugly. Bodies that aren't JSON (or don't match
// the expected shape) are left alone; this is a pure progressive-
// enhancement pass.
func rewriteJSONChoiceBodiesAsLettered(content string) string {
	if !strings.Contains(content, lcOpenTag) {
		return content
	}
	var b strings.Builder
	b.Grow(len(content))
	rest := content
	for {
		open := strings.Index(rest, lcOpenTag)
		if open < 0 {
			b.WriteString(rest)
			return b.String()
		}
		bodyStart := open + len(lcOpenTag)
		closeRel := strings.Index(rest[bodyStart:], lcCloseTag)
		if closeRel < 0 {
			b.WriteString(rest)
			return b.String()
		}
		bodyEnd := bodyStart + closeRel
		blockEnd := bodyEnd + len(lcCloseTag)
		b.WriteString(rest[:bodyStart])
		body := rest[bodyStart:bodyEnd]
		if rendered := renderLetteredFromJSONBody(body); rendered != "" {
			// Sandwich with newlines so the lettered list reads as
			// its own paragraph after tag strip, rather than
			// collapsing into surrounding prose.
			b.WriteString("\n")
			b.WriteString(rendered)
			b.WriteString("\n")
		} else {
			b.WriteString(body)
		}
		b.WriteString(lcCloseTag)
		rest = rest[blockEnd:]
	}
}

// renderLetteredFromJSONBody parses a choice-block body as a
// choice_list JSON object and returns "A. label\nB. label\n…" lettered
// text. Returns "" when the body isn't valid JSON or has no items —
// callers fall back to the body verbatim in that case.
func renderLetteredFromJSONBody(body string) string {
	body = strings.TrimSpace(body)
	if body == "" {
		return ""
	}
	var in lcChoicePropsIn
	if err := json.Unmarshal([]byte(body), &in); err != nil {
		return ""
	}
	if len(in.Items) == 0 {
		return ""
	}
	var b strings.Builder
	for i, it := range in.Items {
		label := strings.TrimSpace(it.Label)
		if label == "" {
			continue
		}
		letter := "Z"
		if i < 26 {
			letter = string(rune('A' + i))
		}
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(letter)
		b.WriteString(". ")
		b.WriteString(label)
	}
	return b.String()
}

// stripTagPreservingWordBoundary removes every occurrence of `tag` from
// `s`. When the character immediately before AND immediately after the
// tag are both non-whitespace, a single space is inserted in the tag's
// place so adjacent words don't smash together. When either side is
// already whitespace (or the tag sits at a string boundary), no padding
// is added — the existing whitespace is the word boundary.
//
// Motivating example: an assistant message like
//
//	"You can <choices>A. Read B. Write</choices>What sounds good?"
//
// naive strip produces `"You can A. Read B. WriteWhat sounds good?"`.
// This helper produces `"You can A. Read B. Write What sounds good?"`.
func stripTagPreservingWordBoundary(s, tag string) string {
	if tag == "" || !strings.Contains(s, tag) {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	rest := s
	for {
		i := strings.Index(rest, tag)
		if i < 0 {
			b.WriteString(rest)
			return b.String()
		}
		b.WriteString(rest[:i])
		end := i + len(tag)
		// Look one rune in each direction. utf8.DecodeLastRune /
		// DecodeRune handle multi-byte cleanly; ASCII fast-paths
		// the common case.
		var prev, next rune
		if i > 0 {
			prev, _ = utf8.DecodeLastRuneInString(rest[:i])
		}
		if end < len(rest) {
			next, _ = utf8.DecodeRuneInString(rest[end:])
		}
		// Only insert a space when BOTH sides have non-whitespace
		// content. Tag at boundary, or already-whitespace on either
		// side, falls through unchanged so we don't pad existing
		// whitespace into a double space.
		if prev != 0 && next != 0 && !unicode.IsSpace(prev) && !unicode.IsSpace(next) {
			b.WriteByte(' ')
		}
		rest = rest[end:]
	}
}

// --- StreamingTagProvider ---

// StreamingTags surfaces the `<choices>` tag when this instance is
// in component mode so the client can render completed choice blocks
// as a choice_list inline during streaming. Text mode contributes
// nothing — its blocks become plain markdown via DisplayTransformer,
// not a structured component.
func (p *letteredChoices) StreamingTags() []StreamingTag {
	if p.cfg.OutputMode != lcOutputModeComponent {
		return nil
	}
	return []StreamingTag{{Tag: "choices", Component: "choice_list"}}
}

// --- ContentRenderer ---

// RenderContent finds every choices block in assistant content and
// replaces it with a `choice_list` UIFragment. The text before/after
// the block is preserved as text ContentParts so prose framing
// renders normally. Only fires in component mode + on assistant
// messages — user / system / context turns fall through unchanged.
func (p *letteredChoices) RenderContent(parts []ContentPart, role string) []ContentPart {
	if p.cfg.OutputMode != lcOutputModeComponent {
		return parts
	}
	if role != "assistant" {
		return parts
	}
	return WalkText(parts, func(text string) []ContentPart {
		return p.splitChoiceBlocks(text)
	})
}

// splitChoiceBlocks scans text for `OpenTag…CloseTag` regions and
// converts each into a `choice_list` UIFragment. Surrounding prose
// becomes text ContentParts. Unmatched OpenTag (no close found) is
// left in place — surfacing a malformed message beats silently
// truncating, matching the HistoryTransformer behavior above.
func (p *letteredChoices) splitChoiceBlocks(text string) []ContentPart {
	var out []ContentPart
	rest := text
	for {
		open := strings.Index(rest, lcOpenTag)
		if open < 0 {
			if rest != "" {
				out = append(out, ContentPart{Text: rest})
			}
			return out
		}
		closeRel := strings.Index(rest[open+len(lcOpenTag):], lcCloseTag)
		if closeRel < 0 {
			// Malformed — preserve the rest as text and stop.
			if rest != "" {
				out = append(out, ContentPart{Text: rest})
			}
			return out
		}
		blockStart := open + len(lcOpenTag)
		blockEnd := blockStart + closeRel
		afterClose := blockEnd + len(lcCloseTag)

		// Preserve prose before the block, trimmed of trailing
		// whitespace so the block visually anchors flush to the
		// preceding paragraph rather than carrying a dangling
		// blank line.
		if pre := strings.TrimRight(rest[:open], " \t\n\r"); pre != "" {
			out = append(out, ContentPart{Text: pre})
		}

		body := rest[blockStart:blockEnd]
		items := p.parseChoiceItems(body)
		if len(items) > 0 {
			// Empty key — choice_list rows don't need stable
			// identity across re-renders (no internal state like
			// expansion or selection that survives a content
			// change).
			props, err := json.Marshal(map[string]any{"items": items})
			if err == nil {
				out = append(out, ContentPart{Fragment: &UIFragment{
					Component: "choice_list",
					Props:     props,
				}})
			}
			// If marshal failed (shouldn't — items are plain
			// strings), silently drop the block. The text body is
			// already out of the parts list; an error here would
			// be worse than a missing fragment.
		} else if trimmed := strings.TrimSpace(body); trimmed != "" {
			// Body didn't parse as choice_list JSON — most likely an
			// old message generated under text mode (lettered lines
			// like "A. Foo\nB. Bar") that predates this profile's
			// switch to component mode. Render the body as a plain
			// text part so the message stays visible. Not interactive,
			// but readable — better than the alternative of dropping
			// the block entirely.
			out = append(out, ContentPart{Text: trimmed})
		}

		// Continue after the close tag, trimming leading whitespace
		// so prose flows back into the next part without an
		// orphan blank line.
		rest = strings.TrimLeft(rest[afterClose:], " \t\n\r")
	}
}

// parseChoiceItems decodes the JSON body of a `<choices>…</choices>`
// block emitted in component mode and produces the fragment items the
// `choice_list` renderer expects. Letters (A, B, C…) are auto-assigned
// by index so the model's JSON only carries labels — minimal escape
// surface, no merged-line failure modes from free-form text. Returns
// nil when the body is empty, isn't JSON, or has no items; the caller
// drops the block silently in that case so a malformed turn shows the
// raw choices block as text rather than a broken fragment.
func (p *letteredChoices) parseChoiceItems(body string) []map[string]string {
	body = strings.TrimSpace(body)
	if body == "" {
		return nil
	}
	var in lcChoicePropsIn
	if err := json.Unmarshal([]byte(body), &in); err != nil {
		return nil
	}
	if len(in.Items) == 0 {
		return nil
	}
	items := make([]map[string]string, 0, len(in.Items))
	for i, it := range in.Items {
		label := strings.TrimSpace(it.Label)
		if label == "" {
			continue
		}
		// Auto-assign letters A-Z; degrade gracefully past 26 by
		// repeating the last letter rather than wrapping to a
		// non-letter. Models that emit more than 26 choices have
		// other problems.
		letter := "Z"
		if i < 26 {
			letter = string(rune('A' + i))
		}
		items = append(items, map[string]string{
			"label":  letter + ". " + label,
			"value":  letter,
			"action": "send:" + letter,
		})
	}
	if len(items) == 0 {
		return nil
	}
	return items
}

// stripBetween removes every span starting at openTag and ending at the next
// closeTag (inclusive of both). Surrounding whitespace is collapsed: when
// the strip leaves non-empty content on both sides, they're rejoined with a
// single blank-line separator ("\n\n"); when one side is empty, the other
// is returned with its trailing/leading whitespace trimmed.
//
// This avoids two over-eager corner cases: (1) leaving a stack of consecutive
// blank lines where a block was, and (2) eating ALL whitespace between two
// adjacent stripped blocks, smashing the surrounding bodies together.
//
// Unmatched openTag (no closeTag found after it) is left in place — better
// to surface a malformed message than silently truncate to end-of-string.
func stripBetween(s, openTag, closeTag string) string {
	if openTag == "" || closeTag == "" {
		return s
	}
	var b strings.Builder
	for {
		i := strings.Index(s, openTag)
		if i < 0 {
			b.WriteString(s)
			return b.String()
		}
		j := strings.Index(s[i+len(openTag):], closeTag)
		if j < 0 {
			b.WriteString(s)
			return b.String()
		}
		end := i + len(openTag) + j + len(closeTag)
		pre := strings.TrimRight(s[:i], " \t\n\r")
		post := strings.TrimLeft(s[end:], " \t\n\r")
		switch {
		case pre != "" && post != "":
			b.WriteString(pre)
			b.WriteString("\n\n")
			s = post
		case pre != "":
			b.WriteString(pre)
			s = post // empty
		default:
			s = post
		}
	}
}
