package conversations

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"connectrpc.com/connect"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/modelmeta"
)

// validateModelCapabilities checks the resolved model can drive every
// plugin in the turn's pipeline: the profile chain plus the
// conversation's own plugin rows, as the send will actually run them.
// Returns a FailedPrecondition error naming the missing capabilities
// when a shortfall exists; nil when the model is sufficient or the
// pipeline requires nothing.
//
// It reads the built pipeline rather than re-walking the profile chain,
// so the gate can't disagree with what runs: a tool plugin attached to
// one conversation is checked, and one a conversation turned off isn't.
func validateModelCapabilities(pipeline pluginapi.Pipeline, modelID string, modelCapsBytes []byte) error {
	required := requiredCapabilities(pipeline)
	if required.Empty() {
		return nil
	}
	var actual modelmeta.Capabilities
	if len(modelCapsBytes) > 0 {
		// Best-effort decode — a malformed snapshot shouldn't block the
		// send. Empty struct == no capabilities supported, which still
		// produces the right shortfall result below.
		_ = json.Unmarshal(modelCapsBytes, &actual)
	}
	missing := capabilityShortfall(required, actual)
	if missing.Empty() {
		return nil
	}
	return connect.NewError(connect.CodeFailedPrecondition,
		errors.New("model "+quote(modelID)+" lacks capabilities required by this conversation's plugins: "+strings.Join(missing.Names(), ", ")))
}

// requiredCapabilities unions what each plugin in the pipeline declares.
// A name the registry doesn't know contributes nothing; building the
// pipeline already refused unknown plugins.
func requiredCapabilities(pipeline pluginapi.Pipeline) pluginapi.ModelCapabilityRequirements {
	var caps pluginapi.ModelCapabilityRequirements
	for _, p := range pipeline {
		d, err := pluginapi.Describe(p.Name())
		if err != nil {
			continue
		}
		caps = caps.Combine(d.RequiredModelCapabilities)
	}
	return caps
}

// capabilityShortfall returns the requirements not met by `actual`. The
// result is Empty() iff actual satisfies every requirement.
func capabilityShortfall(req pluginapi.ModelCapabilityRequirements, actual modelmeta.Capabilities) pluginapi.ModelCapabilityRequirements {
	return pluginapi.ModelCapabilityRequirements{
		Streaming:       req.Streaming && !actual.Streaming,
		Thinking:        req.Thinking && !actual.Thinking,
		ToolUse:         req.ToolUse && !actual.ToolUse,
		Vision:          req.Vision && !actual.Vision,
		PromptCaching:   req.PromptCaching && !actual.PromptCaching,
		GeneratesImages: req.GeneratesImages && !actual.GeneratesImages,
	}
}

// quote returns s wrapped in double quotes, escaping any embedded
// quotes. Used for human-facing error messages where fmt.Sprintf("%q",…)
// would do more work than we need.
func quote(s string) string {
	return fmt.Sprintf("%q", s)
}
