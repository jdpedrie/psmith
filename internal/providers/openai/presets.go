package openai

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"

	"github.com/jdpedrie/clark/internal/providers"
)

// PresetID identifies one of the built-in provider configurations the UI
// surfaces in the "Add provider" picker. New configs persist this id in
// `user_model_providers.config.preset_id`; existing configs without a
// preset id resolve to PresetCustom (no quirks, no logo, manual base url).
type PresetID string

const (
	// PresetCustom is the catch-all for endpoints we don't have a built-in
	// for. Empty Quirks; user supplies their own base_url. This is the
	// behaviour every existing pre-preset config gets.
	PresetCustom    PresetID = ""
	PresetOpenAI    PresetID = "openai"
	PresetXAI       PresetID = "xai"
	PresetDeepSeek  PresetID = "deepseek"
	PresetGroq      PresetID = "groq"
	PresetOpenRouter PresetID = "openrouter"
	PresetMistral   PresetID = "mistral"
	PresetTogether  PresetID = "together"
	PresetCerebras  PresetID = "cerebras"
	PresetQwen      PresetID = "qwen"
	PresetOllama    PresetID = "ollama"
	PresetPerplexity PresetID = "perplexity"
)

// Preset is one entry in the built-in provider registry. Display fields
// (DisplayName, LogoSlug) are read by the UI; runtime fields (BaseURL,
// Quirks) are consumed by the driver in New().
type Preset struct {
	ID          PresetID
	DisplayName string
	BaseURL     string
	// LogoSlug is the LobeHub icon slug, looked up at app build time
	// against `https://unpkg.com/@lobehub/icons-static-svg@latest/icons/<slug>.svg`.
	LogoSlug string
	// Quirks is the per-provider behaviour overlay. Empty means "behaves
	// exactly like vanilla OpenAI."
	Quirks Quirks
}

// PresetByID returns the preset for id, or PresetCustom (empty) if id is
// unknown. Unknown ids are not an error — they let us tolerate downgrades
// where a config references a preset the running clarkd doesn't yet know.
func PresetByID(id PresetID) Preset {
	if p, ok := presets[id]; ok {
		return p
	}
	return Preset{ID: PresetCustom}
}

// AllPresets returns every registered preset, in stable order, for the UI
// "Add provider" picker. The Custom preset is intentionally omitted — the
// UI surfaces it as a separate "Custom (OpenAI-compatible)" option.
func AllPresets() []Preset {
	out := make([]Preset, 0, len(presetOrder))
	for _, id := range presetOrder {
		out = append(out, presets[id])
	}
	return out
}

// presetOrder pins display order. Native-driver presets (Anthropic,
// Google) live in their own packages — this registry is openai-compatible
// only.
var presetOrder = []PresetID{
	PresetOpenAI,
	PresetXAI,
	PresetDeepSeek,
	PresetGroq,
	PresetOpenRouter,
	PresetMistral,
	PresetTogether,
	PresetCerebras,
	PresetQwen,
	PresetOllama,
	PresetPerplexity,
}

// presets is the registry. Every entry is a "pure" struct value — no
// closures or shared state — so a Preset can be returned by value without
// surprises.
var presets = map[PresetID]Preset{
	PresetOpenAI: {
		ID: PresetOpenAI, DisplayName: "OpenAI",
		BaseURL: "https://api.openai.com/v1", LogoSlug: "openai",
	},
	PresetXAI: {
		ID: PresetXAI, DisplayName: "xAI Grok",
		BaseURL: "https://api.x.ai/v1", LogoSlug: "xai",
		Quirks: Quirks{
			// xAI's chat-completions endpoint takes the conversation id
			// via this header; the cache is server-pinned, so subsequent
			// turns must hit the same backend to see a cache_read.
			// See: https://docs.x.ai/developers/advanced-api-usage/prompt-caching/maximizing-cache-hits
			HeaderInjector: func(h http.Header, req providers.SendRequest) {
				if req.ConversationID != "" {
					h.Set("x-grok-conv-id", req.ConversationID)
				}
			},
			// /v1/models on xAI returns just bare ids; /v1/language-models
			// returns context window, modalities, and pricing per token.
			// We use the rich endpoint so the user_models snapshot has
			// useful numbers without needing the models.dev follow-up.
			DiscoveryFunc: discoverXAIModels,
		},
	},
	PresetDeepSeek: {
		ID: PresetDeepSeek, DisplayName: "DeepSeek",
		BaseURL: "https://api.deepseek.com/v1", LogoSlug: "deepseek",
	},
	PresetGroq: {
		ID: PresetGroq, DisplayName: "Groq",
		BaseURL: "https://api.groq.com/openai/v1", LogoSlug: "groq",
	},
	PresetOpenRouter: {
		ID: PresetOpenRouter, DisplayName: "OpenRouter",
		BaseURL: "https://openrouter.ai/api/v1", LogoSlug: "openrouter",
	},
	PresetMistral: {
		ID: PresetMistral, DisplayName: "Mistral",
		BaseURL: "https://api.mistral.ai/v1", LogoSlug: "mistral",
	},
	PresetTogether: {
		ID: PresetTogether, DisplayName: "Together AI",
		BaseURL: "https://api.together.ai/v1", LogoSlug: "together",
	},
	PresetCerebras: {
		ID: PresetCerebras, DisplayName: "Cerebras",
		BaseURL: "https://api.cerebras.ai/v1", LogoSlug: "cerebras",
	},
	PresetQwen: {
		ID: PresetQwen, DisplayName: "Qwen",
		BaseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
		LogoSlug: "qwen-color",
	},
	PresetOllama: {
		ID: PresetOllama, DisplayName: "Ollama (local)",
		BaseURL: "http://localhost:11434/v1", LogoSlug: "ollama",
	},
	PresetPerplexity: {
		ID: PresetPerplexity, DisplayName: "Perplexity",
		BaseURL: "https://api.perplexity.ai", LogoSlug: "perplexity",
	},
}

// --- xAI discovery -------------------------------------------------------

// xaiLanguageModelsResponse is the shape returned by /v1/language-models —
// xAI's enrichment endpoint that sits alongside the standard OpenAI-compat
// /v1/models. Fields trimmed to what we actually consume; xAI returns more
// (input/output modality lists, aliases, tags) but they're not worth
// surfacing today.
type xaiLanguageModelsResponse struct {
	Models []struct {
		ID                  string  `json:"id"`
		Created             int64   `json:"created,omitempty"`
		OwnedBy             string  `json:"owned_by,omitempty"`
		Version             string  `json:"version,omitempty"`
		PromptTextTokenPrice    float64 `json:"prompt_text_token_price,omitempty"`
		CachedPromptTextTokenPrice float64 `json:"cached_prompt_text_token_price,omitempty"`
		CompletionTextTokenPrice float64 `json:"completion_text_token_price,omitempty"`
		PromptImageTokenPrice    float64 `json:"prompt_image_token_price,omitempty"`
		// Input/output modalities arrive as []string but are noisy
		// (text, image, file). Capture only to set Vision.
		InputModalities  []string `json:"input_modalities,omitempty"`
		OutputModalities []string `json:"output_modalities,omitempty"`
	} `json:"models"`
}

// discoverXAIModels calls /v1/language-models and synthesizes the
// providers.Model list. Pricing fields are reported as "price per 100M
// tokens in cents" by xAI — we normalize to USD per million so the UI's
// existing cost columns work.
//
// xAI's quirky pricing scale: docs describe the values as "the cost per
// 100,000,000 tokens in USD cents" — i.e. a value of 30 means
// $0.30 per 1M tokens. We multiply by 0.01 to land in dollars-per-million.
func discoverXAIModels(ctx context.Context, d *Driver) ([]providers.Model, error) {
	u, err := url.Parse(d.cfg.BaseURL)
	if err != nil {
		return nil, fmt.Errorf("xai: parse base_url: %w", err)
	}
	u.Path = singleSlashJoin(u.Path, "language-models")

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("xai: build language-models request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+d.cfg.APIKey)
	req.Header.Set("Accept", "application/json")

	httpClient := d.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("xai: language-models: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("xai: language-models: HTTP %d", resp.StatusCode)
	}

	var parsed xaiLanguageModelsResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, fmt.Errorf("xai: decode language-models: %w", err)
	}

	out := make([]providers.Model, 0, len(parsed.Models))
	for _, m := range parsed.Models {
		model := providers.Model{
			ID:          m.ID,
			DisplayName: m.ID,
		}
		if m.PromptTextTokenPrice > 0 || m.CompletionTextTokenPrice > 0 ||
			m.CachedPromptTextTokenPrice > 0 {
			model.Pricing = &providers.Pricing{
				InputPerMillion:     m.PromptTextTokenPrice * 0.01,
				OutputPerMillion:    m.CompletionTextTokenPrice * 0.01,
				CacheReadPerMillion: m.CachedPromptTextTokenPrice * 0.01,
			}
		}
		// Vision capability: input modality includes "image".
		for _, mod := range m.InputModalities {
			if mod == "image" {
				model.Capabilities.Vision = true
				break
			}
		}
		model.Capabilities.Streaming = true
		model.Modalities = m.InputModalities
		out = append(out, model)
	}
	return out, nil
}

// singleSlashJoin appends segment to base, collapsing exactly one slash.
// `https://api.x.ai/v1` + `language-models` → `https://api.x.ai/v1/language-models`.
func singleSlashJoin(base, segment string) string {
	if base == "" {
		return "/" + segment
	}
	if base[len(base)-1] == '/' {
		return base + segment
	}
	return base + "/" + segment
}
