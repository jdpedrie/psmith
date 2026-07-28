// Package plugins implements Psmith's chat-plugin system. A chat plugin is a
// compiled-in unit that can contribute to the system prompt, transform
// outgoing user messages, mutate stored history at prefix-build time, process
// inbound chunk streams, transform stored content for display, and provide
// tools the model can call.
//
// The required Plugin interface is intentionally tiny — name + display name + description.
// Every behavior is a separate opt-in interface, detected by type assertion
// at the call sites that care. A plugin implements as many sub-interfaces
// as it needs.
//
// See docs/design/plugins.md for the full design.
package pluginapi

import (
	"encoding/json"
)

// ---------------------------------------------------------------------------
// Required core interface.
// ---------------------------------------------------------------------------

// ConfigFieldType is the small enumeration of input shapes supported by the
// UI form-builder. The plugin's constructor remains the authoritative
// validator at runtime; ConfigFields is only a hint to render a form.
type ConfigFieldType string

const (
	ConfigFieldNumber      ConfigFieldType = "number"
	ConfigFieldText        ConfigFieldType = "text"
	ConfigFieldTextarea    ConfigFieldType = "textarea"
	ConfigFieldBoolean     ConfigFieldType = "boolean"
	ConfigFieldSelect      ConfigFieldType = "select"
	ConfigFieldModelPicker ConfigFieldType = "model_picker"
)

// ConfigFieldMerge picks how a field's value combines across the
// resolver's layered config view (root profile → leaf profile →
// conversation override). The default is "replace" (leaf wins, the
// pre-existing behaviour). Plugins opt into accumulation for fields
// where every layer's contribution adds value rather than supersedes —
// e.g. text_injector's prefixes/suffixes, where a child profile or
// per-conversation override should add to the parent's text rather
// than blow it away.
type ConfigFieldMerge string

const (
	// MergeReplace — leaf-most layer with a value wins, every earlier
	// layer is ignored for this field. Default for any field that
	// doesn't set Merge explicitly.
	MergeReplace ConfigFieldMerge = ""

	// MergeAppendString — string fields concatenate every non-empty
	// layer in root-to-leaf order, joined with a blank line. Use for
	// prompts / reminders / additive instructions.
	MergeAppendString ConfigFieldMerge = "append_string"
)

// ConfigField describes one entry in a plugin's per-instance config shape.
// The list is flat — there's no nesting. Default is JSON-marshaled when
// shipped over the wire; nil means "no default."
type ConfigField struct {
	Name        string
	Display     string
	Description string
	Type        ConfigFieldType
	Default     any            // JSON-marshaled when sent over the wire; nil = no default
	Options     []ConfigOption // only when Type==ConfigFieldSelect
	// ModelPickerFilter constrains which user_models the
	// chooser surfaces. Only consulted when Type==ConfigFieldModelPicker.
	// Any flag set to true is a hard requirement; flags AND.
	ModelPickerFilter ModelPickerFilter
	// Required is a hint for the UI: a plugin can't be considered ready
	// until this field has a non-empty value (or, for booleans/numbers,
	// an explicit value chosen). The plugin's constructor remains the
	// authoritative validator — Required is purely a UX signal so the
	// form can disable Save and surface inline errors before the user
	// hits the server-side rejection.
	Required bool
	// Global marks the field as living at user scope rather than
	// profile scope. Use it for credentials and other values the user
	// only wants to enter once (e.g. brave_search's api_key). At
	// pipeline-build time the server merges the user's stored global
	// value into the per-profile config blob handed to the plugin
	// constructor; profile-scoped config can still override on a
	// per-key basis. UIs render global fields on a separate "Plugin
	// settings" surface, NOT in the per-profile plugin form.
	Global bool
	// Secret marks the field as credential-bearing: it must never leave
	// the deployment. Profile export strips it.
	//
	// Distinct from Global, which is about scope, not sensitivity. They
	// often coincide (brave_search's api_key is both) but not always:
	// mcp's `env` and `headers` are per-instance profile config, so not
	// Global, while holding exactly the API keys and bearer tokens the
	// user would be horrified to share. Without a separate flag, export
	// would have to hardcode knowledge of individual plugins' config
	// shapes, which is the coupling this package exists to prevent.
	//
	// Global implies non-exportable too (a user-scoped value is not the
	// profile's to give away), so export skips a key when either is set.
	Secret bool

	// Merge picks how this field combines across the resolver's
	// root-to-leaf layered view. Unset = MergeReplace (leaf wins).
	// Set to MergeAppendString on string/textarea fields where each
	// layer's contribution adds to the parent rather than supersedes
	// it (text_injector's prefix/suffix/reminder fields).
	Merge ConfigFieldMerge
	// Category lets a plugin group related fields under a shared
	// section header in the UI. Empty = ungrouped (rendered with
	// the other top-level fields). Used today by app_tools and
	// obsidian to bundle their per-tool toggles by capability
	// ("Calendar", "Reminders", "Obsidian"); previously every
	// field rendered as a flat list which got noisy past ~5
	// entries. Stable strings — adding a new category is a
	// runtime concern, not a schema change.
	Category string
}

// ConfigOption is one entry in a select field's options list.
type ConfigOption struct {
	Value string
	Label string
}

// ModelPickerFilter constrains which user_models a MODEL_PICKER
// field surfaces. Mirror of `psmith.v1.ModelPickerFilter`. Any
// flag set to true is required; flags AND. Empty = no filter.
type ModelPickerFilter struct {
	RequiresStreaming       bool
	RequiresThinking        bool
	RequiresToolUse         bool
	RequiresVision          bool
	RequiresPromptCaching   bool
	RequiresGeneratesImages bool
}

// Configurable lets the system introspect the plugin's per-instance config
// shape. Plugins without configuration don't implement this.
type Configurable interface {
	// ConfigFields returns a flat list of typed fields describing the config
	// blob the constructor accepts. Used by UIs to render config forms; the
	// constructor remains the source of truth for runtime validation.
	ConfigFields() []ConfigField
}

// MergeLayeredConfigs combines a plugin's config bytes from each layer
// of the resolver chain (root profile → leaf profile → conversation
// override) into a single config blob the plugin constructor will see.
// Each field's merge strategy is read from the plugin's TypeDescriptor:
//
//   - MergeReplace (default): the leaf-most layer with a value for that
//     field wins. Every earlier layer is ignored for the field.
//   - MergeAppendString: every non-empty string contribution
//     concatenates in root-to-leaf order, joined with "\n\n".
//
// Layers must be valid JSON objects (or empty / nil = "{}"). Returns
// the merged config as JSON bytes. Plugins without a registered
// type descriptor fall back to "last layer wins" — same effect as the
// pre-merge implementation.
func MergeLayeredConfigs(name string, layers [][]byte) ([]byte, error) {
	if len(layers) == 0 {
		return []byte("{}"), nil
	}
	if len(layers) == 1 {
		// Single layer — short-circuit, no field-strategy work needed.
		if len(layers[0]) == 0 {
			return []byte("{}"), nil
		}
		return layers[0], nil
	}

	desc, err := Describe(name)
	if err != nil {
		// No descriptor — fall back to the legacy "leaf wins" shape.
		// Plugins that aren't introspectable can't declare append
		// strategies anyway.
		last := layers[len(layers)-1]
		if len(last) == 0 {
			return []byte("{}"), nil
		}
		return last, nil
	}

	// Build a field metadata map for quick strategy lookup.
	strategy := make(map[string]ConfigFieldMerge, len(desc.ConfigFields))
	for _, f := range desc.ConfigFields {
		strategy[f.Name] = f.Merge
	}

	// Decode each layer to a generic map. Unknown / unparseable
	// layers are skipped — same lenient handling as the constructor.
	decoded := make([]map[string]any, 0, len(layers))
	for _, raw := range layers {
		if len(raw) == 0 {
			decoded = append(decoded, map[string]any{})
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			// Tolerate by skipping — drivers will surface the real
			// error if the leaf layer is malformed.
			decoded = append(decoded, map[string]any{})
			continue
		}
		if m == nil {
			m = map[string]any{}
		}
		decoded = append(decoded, m)
	}

	// Accumulator built in root-to-leaf order: for replace fields the
	// later layer overwrites; for append-string fields we collect each
	// layer's non-empty contribution then join at the end.
	out := map[string]any{}
	appendBuf := map[string][]string{}

	for _, layer := range decoded {
		for k, v := range layer {
			switch strategy[k] {
			case MergeAppendString:
				if s, ok := v.(string); ok && s != "" {
					appendBuf[k] = append(appendBuf[k], s)
				}
			default:
				// MergeReplace (or unknown field name — preserve
				// it via replace so downstream constructors still
				// see whatever the leaf wrote).
				out[k] = v
			}
		}
	}
	for k, parts := range appendBuf {
		out[k] = joinNonEmpty(parts, "\n\n")
	}

	return json.Marshal(out)
}
