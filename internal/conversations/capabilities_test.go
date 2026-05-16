package conversations

import (
	"testing"

	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/plugins"
)

func TestCapabilityShortfall_AllSatisfied(t *testing.T) {
	req := plugins.ModelCapabilityRequirements{ToolUse: true, Vision: true}
	actual := modelmeta.Capabilities{ToolUse: true, Vision: true, Streaming: true}
	got := capabilityShortfall(req, actual)
	if !got.Empty() {
		t.Errorf("expected empty shortfall; got %+v", got)
	}
}

func TestCapabilityShortfall_PartiallySatisfied(t *testing.T) {
	req := plugins.ModelCapabilityRequirements{ToolUse: true, Vision: true, Thinking: true}
	actual := modelmeta.Capabilities{ToolUse: true} // missing Vision + Thinking
	got := capabilityShortfall(req, actual)
	if !got.Vision {
		t.Error("expected Vision in shortfall")
	}
	if !got.Thinking {
		t.Error("expected Thinking in shortfall")
	}
	if got.ToolUse {
		t.Error("ToolUse satisfied; should NOT be in shortfall")
	}
}

func TestCapabilityShortfall_NoRequirements(t *testing.T) {
	req := plugins.ModelCapabilityRequirements{}
	actual := modelmeta.Capabilities{} // empty model is fine when nothing is required
	got := capabilityShortfall(req, actual)
	if !got.Empty() {
		t.Errorf("expected empty shortfall; got %+v", got)
	}
}

func TestCapabilityShortfall_ModelMissingEverything(t *testing.T) {
	req := plugins.ModelCapabilityRequirements{
		ToolUse: true, Vision: true, Thinking: true, GeneratesImages: true,
	}
	actual := modelmeta.Capabilities{} // model supports nothing
	got := capabilityShortfall(req, actual)
	if got != req {
		t.Errorf("expected shortfall == req; got %+v want %+v", got, req)
	}
}
