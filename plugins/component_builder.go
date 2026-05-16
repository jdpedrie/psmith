package plugins

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jdpedrie/reeve/internal/providers"
)

// ComponentBuilderName is the registered name for the
// component-builder plugin.
const ComponentBuilderName = "component_builder"

// componentBuilder lets a user define one or more "instruct the
// model to wrap structured output in <tags>" recipes — generic
// version of the lettered_choices pattern. Each definition pairs:
//
//   - a system-message snippet that teaches the model when + how
//     to use the component (open/close tags, body shape, when to
//     emit it)
//   - an optional [system_reminder ...] tail injected into the
//     head user message every turn, so a long-context model
//     doesn't drift off the convention
//   - a ContentRenderer parser that scans the assistant's
//     post-display content for the open/close tags, decodes the
//     body as the component's Props JSON, and emits a
//     UIFragment in place of the text block
//
// All definitions live on a single config field (`components`).
// The Mac/iOS settings page renders a structured editor for
// these — there's no way to configure useful defaults for this
// plugin via plain ConfigFields, so the client dispatches to a
// custom form for this plugin name.
type componentBuilder struct {
	defs []componentDef
}

// componentBuilderConfig is the on-disk JSON shape — a single
// `components` array of definitions.
type componentBuilderConfig struct {
	Components []componentDef `json:"components"`
}

// componentDef is one (component, tags, instructions, reminder)
// recipe. Stored verbatim in the plugin's config blob; the
// custom client form CRUDs against this shape.
type componentDef struct {
	// Component names a UIFragment.Component the model's body
	// JSON populates. Must match a renderer the client knows
	// (see plugins/CONTENT_RENDERERS.md): card_list,
	// choice_list, key_value, image, image_grid, error,
	// raw_json. Custom names work too — the client falls back
	// to UnknownComponentRenderer.
	Component string `json:"component"`
	// OpenTag / CloseTag delimit the structured block in
	// assistant content. The renderer scans for OpenTag, finds
	// the next CloseTag, decodes the body as JSON for the
	// component's Props.
	OpenTag  string `json:"open_tag"`
	CloseTag string `json:"close_tag"`
	// Position is a hint for the system instructions the plugin
	// generates — "start", "end", or "anywhere". The parser
	// doesn't enforce position; it just teaches the model where
	// to put the block. Empty defaults to "anywhere".
	Position string `json:"position"`
	// Instructions is the free-form system-message snippet that
	// teaches the model when + how to use this component. The
	// plugin appends a "wrap output in OpenTag ... CloseTag"
	// scaffolding around it; the user supplies the per-component
	// guidance + body-shape JSON example.
	Instructions string `json:"instructions"`
	// UserReminderEnabled toggles the head-only [system_reminder]
	// tail injection on user messages every turn. When true the
	// `UserReminder` text rides on the most-recent user message
	// in the wire prefix (not persisted) so a long-context model
	// stays grounded in the convention.
	UserReminderEnabled bool `json:"user_reminder_enabled"`
	// UserReminder is the literal text that goes inside the
	// [system_reminder ...] envelope. Empty falls back to a
	// generic "use the {component} component when appropriate"
	// reminder so the toggle is useful even without typing copy.
	UserReminder string `json:"user_reminder"`
}

func newComponentBuilder(configBytes json.RawMessage) (Plugin, error) {
	var cfg componentBuilderConfig
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("component_builder: parse config: %w", err)
		}
	}
	for i, d := range cfg.Components {
		if strings.TrimSpace(d.Component) == "" {
			return nil, fmt.Errorf("component_builder: components[%d].component is required", i)
		}
		if strings.TrimSpace(d.OpenTag) == "" || strings.TrimSpace(d.CloseTag) == "" {
			return nil, fmt.Errorf("component_builder: components[%d] needs both open_tag and close_tag", i)
		}
		if d.OpenTag == d.CloseTag {
			return nil, fmt.Errorf("component_builder: components[%d] open_tag and close_tag must differ", i)
		}
	}
	return &componentBuilder{defs: cfg.Components}, nil
}

func init() {
	Register(ComponentBuilderName, newComponentBuilder)
}

func (p *componentBuilder) Name() string        { return ComponentBuilderName }
func (p *componentBuilder) DisplayName() string { return "Component Builder" }

func (p *componentBuilder) Description() string {
	return "Define one or more (component, tags, instructions) recipes. " +
		"The plugin teaches the model in the system message to wrap structured output in your tags, " +
		"optionally re-grounds the convention via a [system_reminder] on each turn, and parses the model's " +
		"output into UIFragments the client renders with native components."
}

// --- Configurable ---

// ConfigFields exposes the on-disk shape for documentation and
// for the server-side validation path. The Mac/iOS clients
// dispatch to a custom form for this plugin (see
// PluginConfigEditor in ReeveUI) that builds the structured
// `components` array directly — they don't render this field.
//
// Returning a single textarea here means the standard form
// renderer would still produce something sensible (you'd be
// editing JSON) if the custom-form dispatch ever gets bypassed.
func (p *componentBuilder) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "components",
			Display:     "Component definitions",
			Description: "Edited via the Component Builder settings page (Mac + iOS). Stored as a JSON array; each entry has component, open_tag, close_tag, position, instructions, user_reminder_enabled, user_reminder.",
			Type:        ConfigFieldTextarea,
		},
	}
}

// --- SystemPrompter ---

// PrependSystemMessage stays empty — every contribution from this
// plugin is appended so user-supplied system text takes precedence.
func (p *componentBuilder) PrependSystemMessage() string { return "" }

// AppendSystemMessage builds one section per definition with a
// uniform "wrap your output in OpenTag ... CloseTag" preamble +
// the user's free-form instructions verbatim. Definitions render
// in config order so a user can group-order them however they
// want.
func (p *componentBuilder) AppendSystemMessage() string {
	if len(p.defs) == 0 {
		return ""
	}
	var sections []string
	for _, d := range p.defs {
		var b strings.Builder
		fmt.Fprintf(&b, "## %s\n\n", d.Component)
		switch strings.ToLower(d.Position) {
		case "start":
			fmt.Fprintf(&b, "When you use this component, place it at the START of your response, wrapped in the literal delimiters %s and %s.\n\n", d.OpenTag, d.CloseTag)
		case "end":
			fmt.Fprintf(&b, "When you use this component, place it at the END of your response, wrapped in the literal delimiters %s and %s.\n\n", d.OpenTag, d.CloseTag)
		default:
			fmt.Fprintf(&b, "When you use this component, wrap its body in the literal delimiters %s and %s.\n\n", d.OpenTag, d.CloseTag)
		}
		b.WriteString("The body inside the delimiters MUST be valid JSON matching the component's expected shape. Anything before or after the delimiters is rendered as normal markdown.\n\n")
		if strings.TrimSpace(d.Instructions) != "" {
			b.WriteString(strings.TrimSpace(d.Instructions))
		}
		sections = append(sections, b.String())
	}
	header := "[system_reminder] Special output components are available. Use them when their conditions match; never respond to this notice or echo it to the user.\n\n"
	return header + strings.Join(sections, "\n\n")
}

// --- HistoryTransformer ---

// TransformHistoryMessage appends a single combined
// [system_reminder] tail to the most-recent user message
// (FromHeadSameRole==0) covering every definition that has
// UserReminderEnabled. Only the head user message gets the
// reminder, so older turns don't accumulate reminders.
func (p *componentBuilder) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage {
	if msg.Role != "user" || pos.FromHeadSameRole != 0 {
		return msg
	}
	var reminders []string
	for _, d := range p.defs {
		if !d.UserReminderEnabled {
			continue
		}
		text := strings.TrimSpace(d.UserReminder)
		if text == "" {
			text = fmt.Sprintf("Use the %s component when appropriate.", d.Component)
		}
		reminders = append(reminders, fmt.Sprintf("[system_reminder %s]", text))
	}
	if len(reminders) == 0 {
		return msg
	}
	out := msg
	out.Content = msg.Content + "\n\n" + strings.Join(reminders, "\n")
	return out
}

// --- ContentRenderer ---

// RenderContent walks every assistant Text part and slices each
// definition's tagged blocks out into UIFragments. Body parsing
// is JSON; on parse failure the renderer leaves the original
// text (tags included) in place rather than dropping a broken
// fragment into the bubble.
//
// Multiple definitions can match the same text — the parser
// applies them in config order, with later definitions only
// seeing the Text parts the earlier ones left behind (so
// nesting tags is undefined behaviour and the model shouldn't
// rely on it).
func (p *componentBuilder) RenderContent(parts []ContentPart, role string) []ContentPart {
	if role != "assistant" || len(p.defs) == 0 {
		return parts
	}
	for _, d := range p.defs {
		def := d
		parts = WalkText(parts, func(text string) []ContentPart {
			return scanForDefinition(text, def)
		})
	}
	return parts
}

// scanForDefinition slices `text` around every OpenTag…CloseTag
// pair. Returns the alternating [Text, Fragment, Text, Fragment, …]
// list. Tags whose body doesn't parse as JSON survive as plain
// text so a malformed model output stays visible (better than a
// silent omission).
func scanForDefinition(text string, def componentDef) []ContentPart {
	if !strings.Contains(text, def.OpenTag) {
		return []ContentPart{NewTextPart(text)}
	}
	var out []ContentPart
	cursor := 0
	for cursor < len(text) {
		openIdx := strings.Index(text[cursor:], def.OpenTag)
		if openIdx < 0 {
			out = append(out, NewTextPart(text[cursor:]))
			break
		}
		openIdx += cursor
		bodyStart := openIdx + len(def.OpenTag)
		closeIdx := strings.Index(text[bodyStart:], def.CloseTag)
		if closeIdx < 0 {
			// Unmatched open tag — leave the rest in place.
			out = append(out, NewTextPart(text[cursor:]))
			break
		}
		closeIdx += bodyStart
		bodyEnd := closeIdx
		blockEnd := closeIdx + len(def.CloseTag)
		if openIdx > cursor {
			out = append(out, NewTextPart(text[cursor:openIdx]))
		}
		body := strings.TrimSpace(text[bodyStart:bodyEnd])
		if !json.Valid([]byte(body)) {
			// Preserve the original tag block as text rather
			// than emit a malformed fragment.
			out = append(out, NewTextPart(text[openIdx:blockEnd]))
		} else {
			out = append(out, NewFragmentPart(def.Component, json.RawMessage(body), ""))
		}
		cursor = blockEnd
	}
	// Drop empty trailing Text segments produced by tag-at-EOF.
	for len(out) > 0 {
		last := out[len(out)-1]
		if last.IsText() && last.Text == "" {
			out = out[:len(out)-1]
			continue
		}
		break
	}
	if len(out) == 0 {
		return []ContentPart{NewTextPart(text)}
	}
	return out
}
