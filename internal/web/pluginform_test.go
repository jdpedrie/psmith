package web

import (
	"encoding/json"
	"testing"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
)

func sampleType() *spaltv1.PluginType {
	return &spaltv1.PluginType{
		Name: "demo",
		ConfigFields: []*spaltv1.ConfigField{
			{Name: "label", Display: "Label", Type: spaltv1.ConfigField_TEXT, DefaultJson: `"hi"`},
			{Name: "count", Display: "Count", Type: spaltv1.ConfigField_NUMBER, DefaultJson: `5`},
			{Name: "on", Display: "On", Type: spaltv1.ConfigField_BOOLEAN, DefaultJson: `true`},
			{Name: "mode", Display: "Mode", Type: spaltv1.ConfigField_SELECT, Options: []*spaltv1.ConfigOption{{Value: "a", Label: "A"}, {Value: "b", Label: "B"}}},
			{Name: "secret", Display: "Secret", Type: spaltv1.ConfigField_TEXT, Global: true},
		},
	}
}

func TestBuildPluginForm_FieldsAndDefaults(t *testing.T) {
	t.Parallel()
	h := New(Deps{})
	cur := []byte(`{"label":"hello","count":9}`)
	form := h.buildPluginForm(t.Context(), sampleType(), cur, nil)
	if !form.HasForm {
		t.Fatal("expected HasForm")
	}
	// global field excluded; 4 editable fields remain.
	if len(form.Fields) != 4 {
		t.Fatalf("fields=%d want 4: %+v", len(form.Fields), form.Fields)
	}
	by := map[string]configFieldVM{}
	for _, f := range form.Fields {
		by[f.Name] = f
	}
	if by["label"].Value != "hello" {
		t.Errorf("label value=%q want hello (from config)", by["label"].Value)
	}
	if by["count"].Value != "9" {
		t.Errorf("count value=%q want 9 (from config)", by["count"].Value)
	}
	if !by["on"].Checked {
		t.Errorf("on should default to checked (default true)")
	}
	if by["mode"].Type != "select" || len(by["mode"].Options) != 2 {
		t.Errorf("mode field wrong: %+v", by["mode"])
	}
}

func TestAssemblePluginConfig_Coercion(t *testing.T) {
	t.Parallel()
	values := map[string]string{
		"cfg_label": "world",
		"cfg_count": "12",
		"cfg_on":    "", // unchecked
		"cfg_mode":  "b",
	}
	cur := []byte(`{"keepme":42}`)
	out, err := assemblePluginConfig(sampleType(), cur, func(field string) string { return values["cfg_"+field] })
	if err != nil {
		t.Fatalf("assemble: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("unmarshal: %v\n%s", err, out)
	}
	if got["label"] != "world" {
		t.Errorf("label=%v want world", got["label"])
	}
	if got["count"].(float64) != 12 {
		t.Errorf("count=%v want 12 (number)", got["count"])
	}
	if got["on"] != false {
		t.Errorf("on=%v want false (bool)", got["on"])
	}
	if got["mode"] != "b" {
		t.Errorf("mode=%v want b", got["mode"])
	}
	if got["keepme"].(float64) != 42 {
		t.Errorf("unknown key keepme not preserved: %v", got["keepme"])
	}
}

func TestPluginHasForm(t *testing.T) {
	t.Parallel()
	if !pluginHasForm(sampleType()) {
		t.Error("sample type should have a form")
	}
	if pluginHasForm(&spaltv1.PluginType{Name: "component_builder", ConfigFields: sampleType().ConfigFields}) {
		t.Error("custom-form plugin should fall back to raw JSON")
	}
	allGlobal := &spaltv1.PluginType{Name: "x", ConfigFields: []*spaltv1.ConfigField{{Name: "g", Global: true}}}
	if pluginHasForm(allGlobal) {
		t.Error("all-global plugin has no editable form")
	}
}
