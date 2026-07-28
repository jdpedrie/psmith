package web

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// Plugins declare their settings as ConfigField descriptors; the client builds
// a form from them (mirrors the iOS PluginConfigForm). Only non-global fields
// are edited per profile/conversation — global fields live on a separate
// surface. Plugins whose config shape doesn't fit a flat field list (or that
// declare no fields) fall back to a raw JSON editor.

// configOptVM is one <select> option.
type configOptVM struct {
	Value string
	Label string
}

// configFieldVM is one rendered form field, prefilled from the current config
// (or the field's declared default).
type configFieldVM struct {
	Name        string
	Display     string
	Description string
	Type        string // text | textarea | number | boolean | select | model
	Category    string
	Required    bool
	Value       string // current value (model: "providerID|modelID")
	Checked     bool   // boolean fields
	Options     []configOptVM
}

// customFormPlugins render their own editor on the native clients; on the web
// we fall back to the raw JSON editor for them rather than a wrong flat form.
var customFormPlugins = map[string]bool{"component_builder": true}

// pluginConfigForm holds everything the config editor templ needs.
type pluginConfigForm struct {
	Fields  []configFieldVM
	HasForm bool   // false → render the raw JSON fallback
	RawJSON string // current config, pretty-printed (fallback editor)
}

// buildPluginForm turns a plugin type's non-global config fields into form view
// models, prefilled from currentConfig. models supplies the choices for
// model-picker fields.
func (h *Handler) buildPluginForm(ctx context.Context, t *psmithv1.PluginType, currentConfig []byte, models []modelVM) pluginConfigForm {
	form := pluginConfigForm{RawJSON: prettyJSON(currentConfig)}
	if form.RawJSON == "" {
		form.RawJSON = "{}"
	}
	if t == nil || customFormPlugins[t.GetName()] {
		return form
	}
	var cur map[string]json.RawMessage
	_ = json.Unmarshal(currentConfig, &cur)

	for _, f := range t.GetConfigFields() {
		if f.GetGlobal() {
			continue // global fields live on the dedicated plugin-settings surface
		}
		vm := configFieldVM{
			Name:        f.GetName(),
			Display:     orName(f.GetDisplay(), f.GetName()),
			Description: f.GetDescription(),
			Type:        fieldTypeName(f.GetType()),
			Category:    f.GetCategory(),
			Required:    f.GetRequired(),
		}
		raw, ok := cur[f.GetName()]
		switch vm.Type {
		case "boolean":
			vm.Checked = boolValue(raw, ok, f.GetDefaultJson())
		case "model":
			vm.Value = modelRefValue(raw, ok)
			vm.Options = append([]configOptVM{{Value: "", Label: "(none)"}}, modelOptions(models)...)
		case "select":
			vm.Value = scalarValue(raw, ok, f.GetDefaultJson())
			for _, o := range f.GetOptions() {
				vm.Options = append(vm.Options, configOptVM{Value: o.GetValue(), Label: orName(o.GetLabel(), o.GetValue())})
			}
		default:
			vm.Value = scalarValue(raw, ok, f.GetDefaultJson())
		}
		form.Fields = append(form.Fields, vm)
	}
	form.HasForm = len(form.Fields) > 0
	return form
}

// displayName is the plugin's display name, nil-safe.
func displayName(t *psmithv1.PluginType) string {
	if t == nil {
		return ""
	}
	return t.GetDisplayName()
}

// pluginHasForm reports whether a plugin has editable non-global fields and
// isn't a custom-form plugin (so the generated form applies rather than the
// raw JSON fallback).
func pluginHasForm(t *psmithv1.PluginType) bool {
	if t == nil || customFormPlugins[t.GetName()] {
		return false
	}
	for _, f := range t.GetConfigFields() {
		if !f.GetGlobal() {
			return true
		}
	}
	return false
}

func fieldTypeName(t psmithv1.ConfigField_Type) string {
	switch t {
	case psmithv1.ConfigField_TEXTAREA:
		return "textarea"
	case psmithv1.ConfigField_NUMBER:
		return "number"
	case psmithv1.ConfigField_BOOLEAN:
		return "boolean"
	case psmithv1.ConfigField_SELECT:
		return "select"
	case psmithv1.ConfigField_MODEL_PICKER:
		return "model"
	default:
		return "text"
	}
}

// scalarValue renders a string/number value as a display string, falling back
// to the field's JSON default when unset.
func scalarValue(raw json.RawMessage, ok bool, defJSON string) string {
	if ok {
		return jsonScalarString(raw)
	}
	if defJSON != "" {
		return jsonScalarString(json.RawMessage(defJSON))
	}
	return ""
}

func boolValue(raw json.RawMessage, ok bool, defJSON string) bool {
	if ok {
		var b bool
		if json.Unmarshal(raw, &b) == nil {
			return b
		}
	}
	if defJSON != "" {
		var b bool
		if json.Unmarshal([]byte(defJSON), &b) == nil {
			return b
		}
	}
	return false
}

func modelRefValue(raw json.RawMessage, ok bool) string {
	if !ok {
		return ""
	}
	var ref struct {
		ProviderID string `json:"provider_id"`
		ModelID    string `json:"model_id"`
	}
	if json.Unmarshal(raw, &ref) == nil && ref.ProviderID != "" && ref.ModelID != "" {
		return modelValue(ref.ProviderID, ref.ModelID)
	}
	return ""
}

// jsonScalarString unwraps a JSON string/number/bool to its plain text.
func jsonScalarString(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return strings.TrimSpace(string(raw))
}

func modelOptions(models []modelVM) []configOptVM {
	out := make([]configOptVM, 0, len(models))
	for _, m := range models {
		out = append(out, configOptVM{Value: m.Value, Label: m.Label})
	}
	return out
}

// assemblePluginConfig builds the config JSON for a plugin from posted form
// values. It starts from the current config (so global/unknown keys survive)
// and overwrites each non-global field, coercing by type. get returns the
// posted value for a field's input (already prefix-resolved by the caller).
func assemblePluginConfig(t *psmithv1.PluginType, current []byte, get func(field string) string) ([]byte, error) {
	out := map[string]json.RawMessage{}
	_ = json.Unmarshal(current, &out)
	if t == nil {
		return current, nil
	}
	for _, f := range t.GetConfigFields() {
		if f.GetGlobal() {
			continue
		}
		name := f.GetName()
		v := strings.TrimSpace(get(name))
		switch fieldTypeName(f.GetType()) {
		case "boolean":
			out[name] = json.RawMessage(strconv.FormatBool(v == "true"))
		case "number":
			if v == "" {
				delete(out, name)
				continue
			}
			if _, err := strconv.ParseFloat(v, 64); err != nil {
				delete(out, name)
				continue
			}
			out[name] = json.RawMessage(v)
		case "model":
			pid, mid, ok := splitModelValue(v)
			if !ok {
				delete(out, name)
				continue
			}
			ref, _ := json.Marshal(map[string]string{"provider_id": pid, "model_id": mid})
			out[name] = ref
		default: // text, textarea, select
			if v == "" {
				delete(out, name)
				continue
			}
			s, _ := json.Marshal(v)
			out[name] = s
		}
	}
	return json.Marshal(out)
}

// pluginTypesByName loads the plugin catalog keyed by machine name.
func (h *Handler) pluginTypesByName(ctx context.Context) map[string]*psmithv1.PluginType {
	out := map[string]*psmithv1.PluginType{}
	if h.profiles == nil {
		return out
	}
	resp, err := h.profiles.ListPluginTypes(ctx, connect.NewRequest(&psmithv1.ListPluginTypesRequest{}))
	if err != nil {
		return out
	}
	for _, t := range resp.Msg.GetPluginTypes() {
		out[t.GetName()] = t
	}
	return out
}
