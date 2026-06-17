package openai

import (
	"context"
	"net/http"

	"github.com/jdpedrie/spalt/internal/providers"
)

// Quirks is the per-provider behavior overlay for the openai-compatible
// driver. The driver is generic; each known third-party endpoint gets a
// Quirks instance attached via a preset (see presets.go) so we can
// account for the small wire-shape divergences without forking the
// driver per provider.
//
// Three principles:
//
//  1. Empty Quirks{} is always valid — no hooks fire, behavior is
//     pure-OpenAI. This is the default for the "Custom OpenAI-compatible"
//     preset and for legacy configs without a preset_id.
//  2. Hooks are additive; the driver runs through them in a fixed order
//     (HeaderInjector before send, DiscoveryFunc replaces /models if set,
//     HardcodedModels seed when /models is absent).
//  3. Quirks never see provider config secrets directly — only the
//     SendRequest the driver was called with.
type Quirks struct {
	// HeaderInjector runs once per Send call before the SDK issues the
	// HTTP request. It receives a mutable http.Header and the in-flight
	// SendRequest so the hook can decide based on conversation_id, model
	// id, settings, etc. Used by xAI to set `x-grok-conv-id` from the
	// conversation id, by OpenRouter for `HTTP-Referer` / `X-Title`,
	// etc. No-op if nil.
	HeaderInjector func(h http.Header, req providers.SendRequest)

	// DiscoveryFunc replaces the default `/v1/models` walk during
	// DiscoverModels. Used by xAI (rich data lives at
	// `/v1/language-models`) and by Ollama (richer info on `/api/tags`).
	// When nil, the driver falls back to the SDK's pager. The function
	// receives the same Driver methods/state via closure since it's
	// constructed in presets.go where Driver isn't reachable; see
	// xAIDiscovery for the pattern.
	DiscoveryFunc func(ctx context.Context, d *Driver) ([]providers.Model, error)

	// HardcodedModels is the static fallback list returned by
	// DiscoverModels when both DiscoveryFunc is nil AND the upstream
	// `/models` call returns nothing. Used by Qwen DashScope (compat-mode
	// has no `/models`) and Perplexity (no `/models` endpoint at all).
	// Each entry should already be enriched (display name, context
	// window, modalities) — pricing comes from the models.dev one-shot
	// at provider-add time.
	HardcodedModels []providers.Model

	// RequestBodyFields runs once per Send call and returns
	// provider-specific JSON fields to merge into the request body via
	// the SDK's option.WithJSONSet. Used for the "extra_body" pattern
	// that several providers need: Mistral's `safe_prompt`,
	// Qwen's `enable_thinking`, Perplexity's `search_*`, OpenRouter's
	// `provider`/`models`. Returning an empty map is a no-op. Keys
	// override anything the SDK's typed params set for the same field —
	// last-write-wins, since WithJSONSet runs after the typed params
	// serialize.
	RequestBodyFields func(req providers.SendRequest) map[string]any
}

// IsEmpty reports whether every hook is unset. Used by the driver to
// short-circuit hook dispatch on the common no-quirk path.
func (q Quirks) IsEmpty() bool {
	return q.HeaderInjector == nil &&
		q.DiscoveryFunc == nil &&
		len(q.HardcodedModels) == 0 &&
		q.RequestBodyFields == nil
}
