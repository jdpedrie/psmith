package plugins

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestModelCapabilityRequirements_Combine(t *testing.T) {
	a := ModelCapabilityRequirements{ToolUse: true, Vision: true}
	b := ModelCapabilityRequirements{Thinking: true, Vision: true}
	got := a.Combine(b)
	want := ModelCapabilityRequirements{ToolUse: true, Vision: true, Thinking: true}
	if got != want {
		t.Errorf("Combine: got %+v want %+v", got, want)
	}
}

func TestModelCapabilityRequirements_Empty(t *testing.T) {
	if !(ModelCapabilityRequirements{}).Empty() {
		t.Error("zero value should be Empty")
	}
	if (ModelCapabilityRequirements{ToolUse: true}).Empty() {
		t.Error("ToolUse=true should not be Empty")
	}
}

func TestModelCapabilityRequirements_Names(t *testing.T) {
	r := ModelCapabilityRequirements{ToolUse: true, Vision: true, GeneratesImages: true}
	got := r.Names()
	want := []string{"tool_use", "vision", "generates_images"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Names: got %v want %v", got, want)
	}
}

// TestDescribe_AutoDerivesToolUseFromToolProvider checks every tool-providing
// plugin in the registry has tool_use auto-derived. Catches regressions if
// someone removes the auto-derive in Describe.
func TestDescribe_AutoDerivesToolUseFromToolProvider(t *testing.T) {
	for _, name := range ListRegistered() {
		desc, err := Describe(name)
		if err != nil {
			t.Fatalf("describe %q: %v", name, err)
		}
		if desc.Capabilities.ToolProvider && !desc.RequiredModelCapabilities.ToolUse {
			t.Errorf("plugin %q is a ToolProvider but doesn't require tool_use", name)
		}
	}
}

// fakeRequirer / fakeProvider aren't real plugins but exercise Describe's
// CapabilityRequirer + ToolProvider detection without depending on the
// (slow / DB-touching) registered ones.
type fakeRequirer struct{}

func (fakeRequirer) Name() string        { return "fake_requirer" }
func (fakeRequirer) DisplayName() string { return "Fake Requirer" }
func (fakeRequirer) Description() string { return "Test fixture for CapabilityRequirer." }
func (fakeRequirer) RequiredModelCapabilities() ModelCapabilityRequirements {
	return ModelCapabilityRequirements{Vision: true, GeneratesImages: true}
}

func TestDescribe_CapabilityRequirerSurfacesAllFields(t *testing.T) {
	Register("test_fake_requirer", Constructor(func(_ json.RawMessage) (Plugin, error) {
		return fakeRequirer{}, nil
	}))
	t.Cleanup(func() { unregister("test_fake_requirer") })

	desc, err := Describe("test_fake_requirer")
	if err != nil {
		t.Fatalf("describe: %v", err)
	}
	if !desc.RequiredModelCapabilities.Vision {
		t.Error("expected Vision requirement")
	}
	if !desc.RequiredModelCapabilities.GeneratesImages {
		t.Error("expected GeneratesImages requirement")
	}
}

// unregister removes a name from the in-package registry. Not part of
// the public API (production never deregisters); used in tests to avoid
// registration leaks across runs.
func unregister(name string) {
	regMu.Lock()
	defer regMu.Unlock()
	delete(reg, name)
}
