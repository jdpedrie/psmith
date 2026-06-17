// Package openai implements the Spalt provider driver for any backend that
// speaks the OpenAI HTTP API. The same driver covers OpenAI direct,
// OpenRouter, Together, Groq, Fireworks, Ollama, vLLM, llama.cpp, LM Studio
// and any other OpenAI-compatible endpoint — the only difference is the
// base URL (and possibly the API key shape).
//
// The driver is stateless: every turn carries the full prefix.
//
// The driver self-registers in init(); importing this package is sufficient
// to make the type available to providers.Build("openai-compatible", ...).
//
// # Token counting
//
// TokenCounter is intentionally NOT implemented. OpenAI-compatible endpoints
// are inconsistent about whether they expose a /v1/tokenize-style endpoint
// (some do — vLLM, llama.cpp; many don't), and the official openai-go SDK
// doesn't ship a tiktoken-style local helper. Adding a heavy local tokenizer
// dependency for a single optional method isn't worth it; if Spalt needs
// token counts it will plumb through a separate utility (or rely on the
// provider's own usage stats reported on stream completion).
package openai

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	sdk "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"

	"github.com/jdpedrie/spalt/internal/providers"
)

func init() {
	providers.Register("openai-compatible", New)
}

// Config is the driver-specific JSON blob stored in
// user_model_providers.config.
type Config struct {
	// APIKey is required. For unauthenticated local endpoints (Ollama,
	// llama.cpp running without auth) configure any non-empty placeholder —
	// the value is sent in the Authorization header but ignored upstream.
	APIKey string `json:"api_key"`
	// BaseURL is required for PresetCustom configs. When PresetID is set,
	// the preset's BaseURL applies unless this field overrides it (UI lets
	// power users point e.g. the OpenAI preset at an Azure deployment).
	// Examples:
	//   - https://api.openai.com/v1
	//   - https://openrouter.ai/api/v1
	//   - http://localhost:11434/v1   (Ollama)
	BaseURL string `json:"base_url"`
	// PresetID, when non-empty, names a built-in provider preset (see
	// presets.go) that supplies the default BaseURL and a Quirks overlay
	// (cache headers, custom discovery endpoint, hardcoded model list).
	// Empty = PresetCustom = no quirks, behaves as vanilla OpenAI. Pre-
	// preset configs leave this unset and continue to work unchanged.
	PresetID PresetID `json:"preset_id,omitempty"`
	// CatalogProviderID is an optional hint for the modelmeta catalog
	// lookup. When set, DiscoverModels enriches each discovered model by
	// LookupModel(catalog_provider_id, model_id). Examples: "openai",
	// "groq", "openrouter". When empty, no enrichment happens and every
	// model is returned with MetadataSource = SourceDriver.
	CatalogProviderID string `json:"catalog_provider_id"`
	// UseChatCompletions routes Send through the `/v1/chat/completions`
	// endpoint instead of the Responses API. The Responses API is
	// OpenAI-specific (api.openai.com) and not supported by most
	// "openai-compatible" backends — Ollama, LM Studio, vLLM, and
	// OpenRouter for many models only implement chat-completions. Default
	// resolution: nil = auto (chat-completions unless base_url points at
	// api.openai.com), true = force chat-completions, false = force
	// Responses. Stored as `*bool` so JSON `null` / missing is
	// distinguishable from explicit `false`.
	UseChatCompletions *bool `json:"use_chat_completions,omitempty"`
}

// Driver is the live driver instance.
type Driver struct {
	cfg    Config
	deps   providers.Deps
	client sdk.Client

	// chatCompletions is the resolved routing decision: true → use
	// `/v1/chat/completions`, false → Responses API. Computed once in
	// `New()` from `cfg.UseChatCompletions` (explicit override) and
	// `cfg.BaseURL` (auto-detect). Send() reads this directly instead of
	// re-resolving per request.
	chatCompletions bool

	// quirks is the resolved provider-quirks overlay. Sourced from
	// PresetByID(cfg.PresetID); empty for PresetCustom and legacy
	// pre-preset configs.
	quirks Quirks

	// httpClient lets tests pin a custom *http.Client. The SDK accepts
	// anything implementing option.HTTPClient; *http.Client satisfies it.
	httpClient *http.Client
}

// resolveChatCompletions applies the routing rule:
//
//   - base_url ≠ api.openai.com → always chat-completions. The Responses
//     API only lives at api.openai.com; routing a third-party endpoint
//     (Ollama, vLLM, OpenRouter, Z.AI, LM Studio, Together, …) at it
//     produces a 404 every time. The stored UseChatCompletions value is
//     ignored here — it's likely stale from an older default that picked
//     Responses for everything, and there's no scenario where a non-OpenAI
//     backend wants to opt into a non-existent endpoint.
//   - base_url = api.openai.com + UseChatCompletions == nil → Responses
//     (the modern, recommended OpenAI path).
//   - base_url = api.openai.com + UseChatCompletions != nil → honour the
//     explicit override (some workflows prefer the older chat-completions
//     shape even on official OpenAI).
func resolveChatCompletions(cfg Config) bool {
	if !isOfficialOpenAIBaseURL(cfg.BaseURL) {
		return true
	}
	if cfg.UseChatCompletions != nil {
		return *cfg.UseChatCompletions
	}
	return false
}

// isOfficialOpenAIBaseURL reports whether the configured base_url points
// at OpenAI's own endpoint. Match is permissive — the canonical form is
// `https://api.openai.com/v1` but variations (trailing slashes, http vs
// https, project-suffixed paths) all reach the same Responses API.
func isOfficialOpenAIBaseURL(baseURL string) bool {
	low := strings.ToLower(baseURL)
	return strings.Contains(low, "api.openai.com")
}

// ForceResponsesAPIForTest is a testing-only escape hatch. The routing
// rule in New() forces non-OpenAI base URLs to chat-completions, but
// httptest base URLs are localhost — so package-external tests that
// exercise the Responses-API code path (e.g. fakellm round-trips) need
// to flip the routing manually after construction.
//
// Not used by production code; safe to call only on a fresh driver before
// any Send() invocation.
func ForceResponsesAPIForTest(p providers.Provider) {
	if d, ok := p.(*Driver); ok {
		d.chatCompletions = false
	}
}

// New constructs a Driver from a Config blob and injected deps.
//
// configBytes must be non-empty valid JSON containing at least api_key and
// base_url. An empty/nil blob is rejected — we cannot speak to an
// unconfigured endpoint.
func New(deps providers.Deps, configBytes json.RawMessage) (providers.Provider, error) {
	if len(configBytes) == 0 {
		return nil, errors.New("openai-compatible: config is required")
	}
	var cfg Config
	if err := json.Unmarshal(configBytes, &cfg); err != nil {
		return nil, fmt.Errorf("openai-compatible: parse config: %w", err)
	}
	if cfg.APIKey == "" {
		return nil, errors.New("openai-compatible: api_key is required")
	}

	// Apply preset defaults: when a preset_id is set, fill in BaseURL
	// from the preset if the user didn't override it. Quirks always come
	// from the preset (config can't redefine them — they're code).
	preset := PresetByID(cfg.PresetID)
	if cfg.BaseURL == "" {
		cfg.BaseURL = preset.BaseURL
	}
	if cfg.BaseURL == "" {
		return nil, errors.New("openai-compatible: base_url is required")
	}

	d := &Driver{
		cfg:             cfg,
		deps:            deps,
		chatCompletions: resolveChatCompletions(cfg),
		quirks:          preset.Quirks,
	}

	opts := []option.RequestOption{
		option.WithAPIKey(cfg.APIKey),
		option.WithBaseURL(cfg.BaseURL),
		// Spalt's stream supervisor owns retry policy. Disable SDK retries
		// to keep behaviour predictable in tests and prod.
		option.WithMaxRetries(0),
	}
	d.client = sdk.NewClient(opts...)
	return d, nil
}

// Type returns the registered provider-type identifier.
func (d *Driver) Type() string { return "openai-compatible" }

// Stateful returns false — OpenAI-compatible HTTP APIs are stateless.
func (d *Driver) Stateful() bool { return false }
