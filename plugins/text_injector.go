package plugins

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jdpedrie/reeve/internal/providers"
)

// TextInjectorName is the registered name for the text-injector plugin.
const TextInjectorName = "text_injector"

// textInjector is a "configurable lettered_choices": every hook it
// supports is a free-form text field on the config form, so a user
// can mirror lettered_choices' tactical pieces (system instruction
// + per-turn user-message reminder) — or assemble entirely
// different prompt-shaping behaviour — without writing Go code.
//
// Hooks (each only fires when its field is non-empty):
//
//   - SystemPrompter prepend → `system_prefix`
//   - SystemPrompter append  → `system_suffix`
//   - HistoryTransformer on every user message:
//       * `user_prefix` prepended
//       * `user_suffix` appended
//   - HistoryTransformer on the head user message only:
//       * `user_head_reminder` appended
//
// Every user-side hook lives in HistoryTransformer (NOT
// OutgoingUserTransformer), so the additions ride on the wire
// prefix only and never get persisted to the messages table. The
// user's own history view shows their original text; future sends
// re-render the additions from the live config.
//
// All-blank config = no-op. The plugin is safe to attach + leave
// unconfigured while the user decides what to put in.
type textInjector struct {
	cfg textInjectorConfig
}

// textInjectorConfig is the per-instance config blob. All fields
// are optional; empty fields skip the corresponding hook.
type textInjectorConfig struct {
	// SystemPrefix is prepended to the resolved system message on
	// every send. Routed through SystemPrompter so it composes
	// with other plugins' system contributions in pipeline order.
	SystemPrefix string `json:"system_prefix"`

	// SystemSuffix is appended to the resolved system message on
	// every send.
	SystemSuffix string `json:"system_suffix"`

	// UserPrefix is prepended to every user message in the wire
	// prefix. NOT persisted — the user's saved message row is
	// untouched.
	UserPrefix string `json:"user_prefix"`

	// UserSuffix is appended to every user message in the wire
	// prefix. Same non-persisted semantics as UserPrefix.
	UserSuffix string `json:"user_suffix"`

	// UserHeadReminder is appended to ONLY the most recent user
	// message in the wire prefix. The lettered_choices "ground
	// the instruction near the head of attention" pattern; bloat-
	// free for older turns since they don't get the addition.
	UserHeadReminder string `json:"user_head_reminder"`
}

func newTextInjector(configBytes json.RawMessage) (Plugin, error) {
	var cfg textInjectorConfig
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("text_injector: parse config: %w", err)
		}
	}
	return &textInjector{cfg: cfg}, nil
}

func init() {
	Register(TextInjectorName, newTextInjector)
}

func (p *textInjector) Name() string        { return TextInjectorName }
func (p *textInjector) DisplayName() string { return "Text Injector" }

func (p *textInjector) Description() string {
	return "Hardcoded text added to the prompt at well-known positions: system prepend/append, " +
		"user prefix/suffix on every turn, and a 'head reminder' appended to just the most-recent " +
		"user message (the lettered_choices grounding pattern). All user-side additions live in the " +
		"wire prefix only — the messages table is untouched, so editing the config takes effect on " +
		"the next send without rewriting history."
}

// --- Configurable ---

func (p *textInjector) ConfigFields() []ConfigField {
	// Every field here is an additive string contribution: a child
	// profile or per-conversation override should ADD to whatever
	// the parent already says, not blow it away. Mark them with
	// `Merge: MergeAppendString` so the resolver concatenates
	// every non-empty layer's value (root → leaf, blank-line
	// separated) instead of taking only the leaf-most.
	return []ConfigField{
		{
			Name:        "system_prefix",
			Display:     "System prepend",
			Description: "Text prepended to the system message on every send. Composes with other plugins' system contributions.",
			Type:        ConfigFieldTextarea,
			Merge:       MergeAppendString,
		},
		{
			Name:        "system_suffix",
			Display:     "System append",
			Description: "Text appended to the system message on every send.",
			Type:        ConfigFieldTextarea,
			Merge:       MergeAppendString,
		},
		{
			Name:        "user_prefix",
			Display:     "User prefix (every turn)",
			Description: "Prepended to every user message in the wire prefix. NOT persisted — your own history view shows your original text.",
			Type:        ConfigFieldTextarea,
			Merge:       MergeAppendString,
		},
		{
			Name:        "user_suffix",
			Display:     "User suffix (every turn)",
			Description: "Appended to every user message in the wire prefix. Same non-persisted semantics as the prefix.",
			Type:        ConfigFieldTextarea,
			Merge:       MergeAppendString,
		},
		{
			Name:        "user_head_reminder",
			Display:     "User head reminder",
			Description: "Appended to ONLY the most recent user message in the wire prefix. Re-grounds an instruction near the head of attention without bloating older turns. The lettered_choices [system_reminder] trick, generalised.",
			Type:        ConfigFieldTextarea,
			Merge:       MergeAppendString,
		},
	}
}

// --- SystemPrompter ---

func (p *textInjector) PrependSystemMessage() string { return p.cfg.SystemPrefix }
func (p *textInjector) AppendSystemMessage() string  { return p.cfg.SystemSuffix }

// --- HistoryTransformer ---

// TransformHistoryMessage layers the configured user-side additions
// onto every user message in the wire prefix. Non-user roles pass
// through unchanged. Empty config fields skip cleanly so the plugin
// stays a no-op until configured.
//
// The output isn't persisted (HistoryTransformer runs at wire-build
// time on a per-send basis), so editing config affects only future
// sends — the messages table never sees these additions.
func (p *textInjector) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage {
	if msg.Role != "user" {
		return msg
	}
	// Skip allocation entirely when nothing applies.
	if p.cfg.UserPrefix == "" && p.cfg.UserSuffix == "" &&
		(p.cfg.UserHeadReminder == "" || pos.FromHeadSameRole != 0) {
		return msg
	}

	var b strings.Builder
	if p.cfg.UserPrefix != "" {
		b.WriteString(p.cfg.UserPrefix)
		b.WriteString("\n\n")
	}
	b.WriteString(msg.Content)
	if p.cfg.UserSuffix != "" {
		b.WriteString("\n\n")
		b.WriteString(p.cfg.UserSuffix)
	}
	if p.cfg.UserHeadReminder != "" && pos.FromHeadSameRole == 0 {
		b.WriteString("\n\n")
		b.WriteString(p.cfg.UserHeadReminder)
	}
	out := msg
	out.Content = b.String()
	return out
}
