package plugins

import (
	"encoding/json"
	"fmt"
	"strings"

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
}

// newLetteredChoices is the registered constructor.
func newLetteredChoices(configBytes json.RawMessage) (Plugin, error) {
	cfg := letteredChoicesConfig{
		KeepLastN: 1,
		OpenTag:   defaultLCOpenTag,
		CloseTag:  defaultLCCloseTag,
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
		if cfg.KeepLastN < 0 {
			return nil, fmt.Errorf("lettered_choices: keep_last_n must be >= 0")
		}
	}
	return &letteredChoices{cfg: cfg}, nil
}

func init() {
	Register(LetteredChoicesName, newLetteredChoices)
}

func (p *letteredChoices) Name() string { return LetteredChoicesName }

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
			Name:        "system_instruction_override",
			Display:     "System instruction override",
			Description: "If set, replaces the default system-message instruction.",
			Type:        ConfigFieldTextarea,
		},
	}
}

// --- SystemPrompter ---

func (p *letteredChoices) PrependSystemMessage() string { return "" }

func (p *letteredChoices) AppendSystemMessage() string {
	if p.cfg.SystemInstructionOverride != "" {
		return p.cfg.SystemInstructionOverride
	}
	return fmt.Sprintf(
		"When you offer the user a discrete choice between options, list them "+
			"as lettered choices wrapped in the literal delimiters %s and %s. "+
			"Example:\n%sA) Attack\nB) Flee\nC) Negotiate%s\n"+
			"Place the wrapped block at the end of your reply. The user will "+
			"respond with just a letter.",
		p.cfg.OpenTag, p.cfg.CloseTag, p.cfg.OpenTag, p.cfg.CloseTag,
	)
}

// --- HistoryTransformer ---

func (p *letteredChoices) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage {
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
	// For display we keep the choice content but drop just the delimiters.
	out := strings.ReplaceAll(content, p.cfg.OpenTag, "")
	out = strings.ReplaceAll(out, p.cfg.CloseTag, "")
	return out
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
