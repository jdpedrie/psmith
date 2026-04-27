// Package openai implements the Clark provider driver for any backend that
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
// dependency for a single optional method isn't worth it; if Clark needs
// token counts it will plumb through a separate utility (or rely on the
// provider's own usage stats reported on stream completion).
package openai

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	sdk "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"

	"github.com/jdpedrie/clark/internal/providers"
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
	// BaseURL is required. Examples:
	//   - https://api.openai.com/v1
	//   - https://openrouter.ai/api/v1
	//   - http://localhost:11434/v1   (Ollama)
	BaseURL string `json:"base_url"`
	// CatalogProviderID is an optional hint for the modelmeta catalog
	// lookup. When set, DiscoverModels enriches each discovered model by
	// LookupModel(catalog_provider_id, model_id). Examples: "openai",
	// "groq", "openrouter". When empty, no enrichment happens and every
	// model is returned with MetadataSource = SourceDriver.
	CatalogProviderID string `json:"catalog_provider_id"`
	// UseChatCompletions, if true, would route Send through the
	// /v1/chat/completions endpoint instead of the Responses API. Not
	// implemented in v1 — exposed in the struct so future versions can
	// honour it without a config-shape break.
	UseChatCompletions bool `json:"use_chat_completions,omitempty"`
}

// Driver is the live driver instance.
type Driver struct {
	cfg    Config
	deps   providers.Deps
	client sdk.Client

	// httpClient lets tests pin a custom *http.Client. The SDK accepts
	// anything implementing option.HTTPClient; *http.Client satisfies it.
	httpClient *http.Client
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
	if cfg.BaseURL == "" {
		return nil, errors.New("openai-compatible: base_url is required")
	}

	d := &Driver{
		cfg:  cfg,
		deps: deps,
	}

	opts := []option.RequestOption{
		option.WithAPIKey(cfg.APIKey),
		option.WithBaseURL(cfg.BaseURL),
		// Clark's stream supervisor owns retry policy. Disable SDK retries
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
