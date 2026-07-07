package anthropic

import (
	"strings"

	sdk "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"

	"github.com/jdpedrie/psmith/internal/modelmeta"
)

// Anthropic split its extended-thinking API: older models take
// `thinking: {type: "enabled", budget_tokens: N}`, while newer ones
// (the Fable 5 / Opus 4.8 / Sonnet 4.6 era onward) reject that with a
// 400 — "thinking_type.enabled is not supported for this model. use
// thinking_type.adaptive and output_config.effort to control thinking
// behavior" — and vice versa for older models given the new shape.
//
// The prefix table below picks the first attempt per model. It is an
// optimization, not a source of truth: a wrong guess costs one doomed
// request, because Send retries once with the flipped shape when the
// 400 names a thinking-shape mismatch (and only before any output has
// streamed). New models Anthropic ships after this table was written
// therefore still work without a code change.
var adaptiveThinkingPrefixes = []string{
	"claude-fable-",
	"claude-opus-4-7",
	"claude-opus-4-8",
	"claude-opus-4-9",
	"claude-opus-5",
	"claude-sonnet-4-6",
	"claude-sonnet-4-7",
	"claude-sonnet-5",
	"claude-haiku-5",
}

// requiresAdaptiveThinking reports whether the model is expected to take
// the adaptive thinking shape. Mismatches self-heal via the Send retry.
func requiresAdaptiveThinking(modelID string) bool {
	for _, p := range adaptiveThinkingPrefixes {
		if strings.HasPrefix(modelID, p) {
			return true
		}
	}
	return false
}

// effortForBudget maps the legacy budget_tokens knob onto the adaptive
// API's effort levels, so a user's existing thinking-budget setting
// keeps meaning something on models that no longer accept a budget.
func effortForBudget(budgetTokens int) string {
	switch {
	case budgetTokens <= 0:
		return "" // unset — let the API pick its default
	case budgetTokens < 8192:
		return "low"
	case budgetTokens < 32768:
		return "medium"
	default:
		return "high"
	}
}

// isThinkingShapeError reports whether an API error is the 400 telling
// us we sent the wrong thinking shape for this model — in either
// direction. New models name "thinking_type."; old models rejecting the
// new shape complain about the "adaptive" tag or the unknown
// "output_config" field. Matched loosely: the retry this gates fires at
// most once and only before any output has streamed.
func isThinkingShapeError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "thinking_type.") {
		return true
	}
	if strings.Contains(msg, "output_config") {
		return true
	}
	return strings.Contains(msg, "thinking") && strings.Contains(msg, "adaptive")
}

// temperatureLocked reports whether the constraints table locks this
// model's temperature (the adaptive-thinking generation 400s on any
// value but 1.0). Same single-source-of-truth pattern as the openai
// driver's locksSampling — the table also drives the clients' locked
// slider rendering, so driver and UI can't drift apart.
func temperatureLocked(modelID string) bool {
	c := modelmeta.ConstraintsFor("anthropic", modelID)
	return c.Temperature != nil && c.Temperature.LockedAt != nil
}

// isSamplingConstraintError reports whether an API error is a rejection
// of an explicit sampling parameter (temperature / top_p / top_k) — the
// adaptive-generation models 400 on temperature ≠ 1. Gates a one-shot
// retry with the sampling knobs stripped, for models the constraints
// table doesn't know yet.
func isSamplingConstraintError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	names := strings.Contains(msg, "temperature") ||
		strings.Contains(msg, "top_p") ||
		strings.Contains(msg, "top_k")
	if !names {
		return false
	}
	rejection := strings.Contains(msg, "not supported") ||
		strings.Contains(msg, "unsupported") ||
		strings.Contains(msg, "may only be set") ||
		strings.Contains(msg, "must be") ||
		strings.Contains(msg, "invalid")
	return rejection
}

// thinkingRequestConfig applies the chosen thinking shape to the outgoing
// request: the legacy shape via the SDK's typed param, the adaptive shape
// via raw JSON overrides (the pinned SDK predates it). Returns the extra
// request options to pass alongside params.
func thinkingRequestConfig(params *sdk.MessageNewParams, adaptive bool, budgetTokens int) []option.RequestOption {
	if !adaptive {
		params.Thinking = sdk.ThinkingConfigParamOfEnabled(int64(budgetTokens))
		return nil
	}
	params.Thinking = sdk.ThinkingConfigParamUnion{} // omit the typed field entirely
	opts := []option.RequestOption{
		option.WithJSONSet("thinking", map[string]string{"type": "adaptive"}),
	}
	if effort := effortForBudget(budgetTokens); effort != "" {
		opts = append(opts, option.WithJSONSet("output_config", map[string]any{"effort": effort}))
	}
	return opts
}
