package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/plugins"
)

// validateModelCapabilities checks the conversation's resolved model can
// drive every plugin in the profile's effective pipeline. Returns a
// FailedPrecondition error naming the missing capabilities when a
// shortfall exists; nil when the model is sufficient or the profile
// requires nothing.
//
// Capability resolution itself is best-effort: a transient error walking
// the profile chain logs and proceeds (the model's own constructor still
// catches genuinely unsupported settings at upstream-call time). The hard
// error is only emitted on a clear "the user attached a tool-providing
// plugin to a profile pointing at a non-tool-using model" case.
func (s *Service) validateModelCapabilities(
	ctx context.Context,
	profileID uuid.UUID,
	modelID string,
	modelCapsBytes []byte,
) error {
	required, err := profiles.ResolveRequiredModelCapabilities(ctx, s.queries, profileID)
	if err != nil {
		s.logger.Warn("capability validation: resolve required failed; allowing send",
			"err", err, "profile_id", profileID)
		return nil
	}
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
	names := missing.Names()
	return connect.NewError(connect.CodeFailedPrecondition,
		errors.New("model "+quote(modelID)+" lacks capabilities required by this profile's plugin pipeline: "+strings.Join(names, ", ")))
}

// capabilityShortfall returns the requirements not met by `actual`. The
// result is Empty() iff actual satisfies every requirement.
func capabilityShortfall(req plugins.ModelCapabilityRequirements, actual modelmeta.Capabilities) plugins.ModelCapabilityRequirements {
	return plugins.ModelCapabilityRequirements{
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
