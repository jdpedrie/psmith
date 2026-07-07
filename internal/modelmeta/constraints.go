package modelmeta

import "strings"

// Constraints describes per-model limits on the CallSettings the UI
// can offer. Empirically discovered via cmd/discover-constraints (see
// internal/modelmeta/constraint_probes/) and supplemented with
// documented per-provider rules. Sparse: any field left nil/empty
// means "no known constraint" — the UI offers the full range and we
// reactively render any upstream rejection inline.
//
// Temperature is the only ranged field surfaced today; add others
// (TopP, TopK, MaxOutputTokens) here as constraints are discovered.
//
// Unsupported is a list of dotted field paths under CallSettings the
// model is known to reject ("openai.response_format" for Z.AI glm-5.1,
// for example). UIs hide controls for any path in this list.
type Constraints struct {
	Temperature *Range
	// Unsupported is a list of dotted CallSettings field paths the
	// model is known to reject. Examples:
	//   - "openai.response_format"
	//   - "openai.logit_bias"
	//   - "thinking"
	// UI clients hide or disable controls for paths in this list.
	Unsupported []string
}

// Range is the supported interval for a numeric setting. Min and Max
// inclusive; LockedAt overrides both — when set, the only valid value
// is exactly LockedAt (e.g. OpenAI's o-series + gpt-5 family lock
// temperature at 1.0).
type Range struct {
	Min      *float64
	Max      *float64
	LockedAt *float64
}

func ptrFloat(v float64) *float64 { return &v }

// ConstraintsFor returns the known constraints for a (providerType,
// modelID) pair. Returns the zero value when nothing is known — the
// UI then offers the full range.
//
// Resolution order:
//
//  1. Exact (providerType, modelID) match — most specific.
//  2. (providerType, model-id-prefix) match — for families like
//     "gpt-5*" or "o3*" that share constraints.
//  3. providerType default — applies to any model under that driver
//     when no per-model entry overrides.
//  4. Zero value — no known constraints.
//
// The constraint table below is hand-maintained. When a probe run
// surfaces a new rejection, add a row here keyed on the smallest
// scope that captures it. Don't add docs-only rules unless the
// rejection has been observed empirically — every entry costs UI
// surface area and "I think Anthropic doesn't support X" is wrong
// often enough that we should require evidence.
func ConstraintsFor(providerType, modelID string) Constraints {
	if c, ok := exactConstraints[providerKey{providerType, modelID}]; ok {
		return c
	}
	for _, e := range prefixConstraints {
		if e.ProviderType == providerType && strings.HasPrefix(modelID, e.ModelIDPrefix) {
			return e.Constraints
		}
	}
	if c, ok := providerTypeDefaults[providerType]; ok {
		return c
	}
	return Constraints{}
}

type providerKey struct {
	ProviderType string
	ModelID      string
}

// exactConstraints is the most specific tier — keyed on (providerType,
// modelID). Use only when the constraint is genuinely model-specific
// rather than a family-wide rule.
var exactConstraints = map[providerKey]Constraints{
	// gemini-3.1-pro-preview rejects temperature ≥ 2.0; other Gemini
	// variants accept the full [0, 2] range. Discovered 2026-05-15;
	// see constraint_probes/20260515-195251.json.
	{"google", "gemini-3.1-pro-preview"}: {
		Temperature: &Range{Min: ptrFloat(0), Max: ptrFloat(1.5)},
	},
}

// prefixConstraints is the family-wide tier — entries match when
// modelID starts with the given prefix. First match wins, so order
// from most-specific to most-general.
var prefixConstraints = []struct {
	ProviderType  string
	ModelIDPrefix string
	Constraints   Constraints
}{
	// OpenAI o-series + gpt-5 family lock temperature at 1.0; the API
	// rejects any other value. Documented per OpenAI's reasoning-models
	// guide. Not yet empirically verified by discover-constraints because
	// no direct OpenAI provider is enabled in the dev catalog.
	{"openai-compatible", "gpt-5", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"openai-compatible", "o1", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"openai-compatible", "o3", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"openai-compatible", "o4", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},

	// Anthropic's adaptive-thinking generation (Fable 5 / Opus 4.8 /
	// Sonnet 4.6 onward) locks temperature at 1.0 — the API 400s on any
	// other value. Observed empirically 2026-07 on opus-4-8, sonnet-4-6,
	// and fable-5. Mirrors the adaptiveThinkingPrefixes table in the
	// anthropic driver; models these prefixes miss self-heal at send
	// time via the driver's constraint-retry.
	{"anthropic", "claude-fable-", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-opus-4-7", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-opus-4-8", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-opus-4-9", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-opus-5", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-sonnet-4-6", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-sonnet-4-7", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-sonnet-5", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
	{"anthropic", "claude-haiku-5", Constraints{
		Temperature: &Range{LockedAt: ptrFloat(1.0)},
	}},
}

// providerTypeDefaults is the broadest tier — applies to any model
// under that driver when no exact / prefix entry overrides. Use
// sparingly: a per-driver rule overrides UI affordances on every
// model, including new ones the user may enable later.
var providerTypeDefaults = map[string]Constraints{
	// Anthropic documents temperature ∈ [0, 1]. The current API
	// appears to silently accept higher values (every probe we ran
	// passed) — but the Anthropic UI guidance for users is to stay
	// in [0, 1], and the SDK's own validators clamp here, so the
	// UI should reflect that.
	"anthropic": {
		Temperature: &Range{Min: ptrFloat(0), Max: ptrFloat(1)},
	},
}
