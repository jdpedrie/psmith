package plugins

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"text/template"

	"github.com/jdpedrie/reeve/internal/providers"
)

// LetteredChoicesName is the registered name for the lettered-choices plugin.
const LetteredChoicesName = "lettered_choices"

// Default tag pair the plugin instructs the model to wrap choices in. Plugins
// can be configured to use different markers (e.g., a project's existing
// convention).
const (
	defaultLCOpenTag  = "<choices>"
	defaultLCCloseTag = "</choices>"
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

// lcChoiceLineRe matches one lettered-choice line inside a parsed
// choices block. Tolerant of the common delimiter styles the default
// template demonstrates ("A." / "A)" / "A:") and of an optional
// leading whitespace indent the model sometimes adds when it's been
// echoing markdown lists. Anything that isn't a letter line — section
// headers, blank lines, prose — is skipped silently.
var lcChoiceLineRe = regexp.MustCompile(`^\s*([A-Z])[.):]?\s+(.+\S)\s*$`)

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

// defaultLCSystemTemplate is the system instruction the plugin appends when
// no override is configured. Same Go-template shape as a user-supplied
// override — sharing the rendering path keeps the two consistent and lets
// us add new template variables without two divergent code branches.
const defaultLCSystemTemplate = `Always offer the user 3-5 lettered choices wrapped in the literal delimiters {{.OpenTag}} and {{.CloseTag}}. Choices may be one word up to a short sentence. Use the following format:

{{.OpenTag}}
### Choices
A. Attack
B. Flee
C. Negotiate
D. Stop and think a while
{{.CloseTag}}`

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

	// OpenTag/CloseTag delimit the choices block in assistant content.
	// Defaults to "<choices>" / "</choices>".
	OpenTag  string `json:"open_tag"`
	CloseTag string `json:"close_tag"`

	// SystemInstructionOverride replaces the default system instruction.
	// Empty = use the default.
	SystemInstructionOverride string `json:"system_instruction_override"`

	// OutputMode picks how the choice block surfaces to the user.
	// "text" (default): DisplayTransformer strips just the delimiters
	// and the choices render as inline markdown — works in any
	// markdown-capable view, no plugin renderer required.
	// "component": ContentRenderer parses the block and emits a
	// `choice_list` UIFragment with one item per lettered line, each
	// item wired to a `compose:<letter>` action so tapping types the
	// chosen letter into the composer. Clients that don't recognize
	// the component fall back to UnknownComponentRenderer (a small
	// JSON viewer), so opting in is forward-safe.
	OutputMode string `json:"output_mode"`
}

// newLetteredChoices is the registered constructor.
func newLetteredChoices(configBytes json.RawMessage) (Plugin, error) {
	cfg := letteredChoicesConfig{
		KeepLastN:  1,
		OpenTag:    defaultLCOpenTag,
		CloseTag:   defaultLCCloseTag,
		OutputMode: lcOutputModeText,
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("lettered_choices: parse config: %w", err)
		}
		// Re-apply defaults for any fields that JSON left zero.
		if cfg.OpenTag == "" {
			cfg.OpenTag = defaultLCOpenTag
		}
		if cfg.CloseTag == "" {
			cfg.CloseTag = defaultLCCloseTag
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
	// Eager template validation — surface a malformed override at
	// config-save time rather than silently falling through to literal
	// text on every send. The default template is parsed for free here
	// so an init-time edit that breaks it is caught the same way.
	src := defaultLCSystemTemplate
	if cfg.SystemInstructionOverride != "" {
		src = cfg.SystemInstructionOverride
	}
	if _, err := template.New("system").Parse(src); err != nil {
		return nil, fmt.Errorf("lettered_choices: parse system_instruction_override template: %w", err)
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
			Name:        "open_tag",
			Display:     "Open tag",
			Description: "Opening delimiter for the choices block.",
			Type:        ConfigFieldText,
			Default:     defaultLCOpenTag,
		},
		{
			Name:        "close_tag",
			Display:     "Close tag",
			Description: "Closing delimiter for the choices block.",
			Type:        ConfigFieldText,
			Default:     defaultLCCloseTag,
		},
		{
			Name:    "system_instruction_override",
			Display: "System instruction override",
			Description: "If set, replaces the default system-message instruction. " +
				"Rendered as a Go text/template (https://pkg.go.dev/text/template) so the open/close tags stay in sync with the other settings. " +
				"Available variables: " +
				"{{.OpenTag}} (the configured Open tag), " +
				"{{.CloseTag}} (the configured Close tag). " +
				"Save fails if the template doesn't parse.",
			Type: ConfigFieldTextarea,
		},
		{
			Name:        "output_mode",
			Display:     "Output mode",
			Description: "How the choices render in the chat. \"Text\" keeps the historical behavior (delimiters stripped, choice text rendered inline as markdown). \"Component\" emits a structured choice_list fragment — clients render tappable buttons that drop the picked letter into the composer when tapped.",
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

func (p *letteredChoices) AppendSystemMessage() string {
	src := defaultLCSystemTemplate
	if p.cfg.SystemInstructionOverride != "" {
		src = p.cfg.SystemInstructionOverride
	}
	// Re-parse on every call. Cheap (templates are small + simple)
	// and lets future hot-reload of plugin config Just Work without
	// a separate cache. Errors here would have been caught at
	// constructor time; if somehow they slip through, fall back to
	// the literal source rather than emitting an empty system slot.
	tmpl, err := template.New("system").Parse(src)
	if err != nil {
		return src + lcSystemReminderExplainer
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, lcTemplateVars{
		OpenTag:  p.cfg.OpenTag,
		CloseTag: p.cfg.CloseTag,
	}); err != nil {
		return src + lcSystemReminderExplainer
	}
	return buf.String() + lcSystemReminderExplainer
}

// lcTemplateVars is the data passed to the system-instruction template.
// Field names are the variables the user references with {{.Name}};
// keep in sync with the description on the system_instruction_override
// ConfigField.
type lcTemplateVars struct {
	OpenTag  string
	CloseTag string
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
	stripped := stripBetween(msg.Content, p.cfg.OpenTag, p.cfg.CloseTag)
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
	out := strings.ReplaceAll(content, p.cfg.OpenTag, "")
	out = strings.ReplaceAll(out, p.cfg.CloseTag, "")
	return out
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
		open := strings.Index(rest, p.cfg.OpenTag)
		if open < 0 {
			if rest != "" {
				out = append(out, ContentPart{Text: rest})
			}
			return out
		}
		closeRel := strings.Index(rest[open+len(p.cfg.OpenTag):], p.cfg.CloseTag)
		if closeRel < 0 {
			// Malformed — preserve the rest as text and stop.
			if rest != "" {
				out = append(out, ContentPart{Text: rest})
			}
			return out
		}
		blockStart := open + len(p.cfg.OpenTag)
		blockEnd := blockStart + closeRel
		afterClose := blockEnd + len(p.cfg.CloseTag)

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
		}

		// Continue after the close tag, trimming leading whitespace
		// so prose flows back into the next part without an
		// orphan blank line.
		rest = strings.TrimLeft(rest[afterClose:], " \t\n\r")
	}
}

// parseChoiceItems scans a block body for lettered lines like "A. Attack"
// and returns one fragment item per match. Labels carry the letter
// prefix ("A. Attack") so the rendered button matches what the model
// emitted; the action is `compose:<letter>` so tapping types the
// chosen letter into the composer — the user sees one tap, the model
// sees a single-letter user message it can interpret as a choice
// selection per its own system prompt.
func (p *letteredChoices) parseChoiceItems(body string) []map[string]string {
	var items []map[string]string
	for _, line := range strings.Split(body, "\n") {
		m := lcChoiceLineRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		letter, label := m[1], m[2]
		items = append(items, map[string]string{
			"label":  letter + ". " + label,
			"value":  letter,
			"action": "compose:" + letter,
		})
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
