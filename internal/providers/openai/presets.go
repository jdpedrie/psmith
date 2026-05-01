package openai

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

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
		Quirks: Quirks{
			// OpenRouter strongly recommends app-identity headers for
			// analytics + leaderboard inclusion. Static values; no need
			// to inspect SendRequest.
			HeaderInjector: func(h http.Header, _ providers.SendRequest) {
				h.Set("HTTP-Referer", openRouterReferer)
				h.Set("X-Title", openRouterTitle)
			},
		},
	},
	PresetMistral: {
		ID: PresetMistral, DisplayName: "Mistral",
		BaseURL: "https://api.mistral.ai/v1", LogoSlug: "mistral",
		Quirks: Quirks{
			// `safe_prompt` is a Mistral-specific top-level body field
			// that prepends an authored safety preamble. Default off —
			// when we add a UI surface for it, populate from settings.
			// For now no-op; the registration is here so the hook fires
			// the moment we wire it.
			RequestBodyFields: func(_ providers.SendRequest) map[string]any {
				return nil
			},
		},
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
		Quirks: Quirks{
			// Qwen3 hybrid-thinking models accept `enable_thinking` at
			// the top level. We mirror our universal Thinking.Enabled
			// signal here — if the user turned thinking on for the
			// turn (or it inherited from the profile/model layer), Qwen
			// gets the boolean; otherwise the field is omitted and
			// Qwen falls back to its default (off for most snapshots).
			RequestBodyFields: func(req providers.SendRequest) map[string]any {
				if req.Settings.Thinking == nil || req.Settings.Thinking.Enabled == nil {
					return nil
				}
				return map[string]any{"enable_thinking": *req.Settings.Thinking.Enabled}
			},
		},
	},
	PresetOllama: {
		ID: PresetOllama, DisplayName: "Ollama (local)",
		BaseURL: "http://localhost:11434/v1", LogoSlug: "ollama",
		Quirks: Quirks{
			// Ollama's OpenAI-compat /v1/models returns just bare ids.
			// /api/tags (the native endpoint, sibling of /v1/) returns
			// model file size, parameter count, quantization level, and
			// the underlying family — useful in the picker. Falls back
			// to the SDK pager on failure so users with Ollama behind
			// a strict OpenAI-compat-only proxy still get a model list.
			DiscoveryFunc: discoverOllamaModels,
		},
	},
	PresetPerplexity: {
		ID: PresetPerplexity, DisplayName: "Perplexity",
		BaseURL: "https://api.perplexity.ai", LogoSlug: "perplexity",
		Quirks: Quirks{
			// Perplexity's `search_*` controls live at the top level of
			// the request body. They aren't surfaced through Clark
			// settings yet — when they are (per-conversation
			// recency/domain filters), wire from req.Settings here. The
			// stub registers the hook so future wiring is one-line.
			RequestBodyFields: func(_ providers.SendRequest) map[string]any {
				return nil
			},
		},
	},
}

// OpenRouter app-identity defaults. Sent on every request from this
// preset; the title shows up in OpenRouter's per-app dashboards.
// `clark://` is a non-resolving URI by design — it identifies the app
// without exposing any user-facing URL.
const (
	openRouterReferer = "clark://app"
	openRouterTitle   = "Clark"
)

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

// --- Ollama discovery ----------------------------------------------------

// ollamaTagsResponse is the shape of `GET /api/tags`. Trimmed to fields
// we actually use; Ollama also returns `digest`, `modified_at`, and a
// `families` array we don't need.
type ollamaTagsResponse struct {
	Models []ollamaTagsModel `json:"models"`
}

type ollamaTagsModel struct {
	Name    string `json:"name"`    // "llama3.1:8b"
	Size    int64  `json:"size"`    // file size in bytes
	Details struct {
		Family            string `json:"family"`             // "llama"
		ParameterSize     string `json:"parameter_size"`     // "8.0B"
		QuantizationLevel string `json:"quantization_level"` // "Q4_0"
	} `json:"details"`
}

// discoverOllamaModels calls /api/tags (sibling of /v1) and synthesizes
// providers.Model entries. The returned models carry display names that
// embed the parameter size and quantization level so the picker shows
// meaningful labels even when models.dev has no local-model entries.
//
// Path translation: /v1 base url → /api/tags. The OpenAI-compat root is
// always at /v1 for default Ollama; we strip that suffix to find /api.
func discoverOllamaModels(ctx context.Context, d *Driver) ([]providers.Model, error) {
	u, err := url.Parse(d.cfg.BaseURL)
	if err != nil {
		return nil, fmt.Errorf("ollama: parse base_url: %w", err)
	}
	// Drop a trailing /v1 (case-sensitive — Ollama's compat path is
	// always lowercase) so we can address /api/tags on the same host.
	apiBase := strings.TrimSuffix(strings.TrimSuffix(u.Path, "/"), "/v1")
	u.Path = singleSlashJoin(apiBase, "api/tags")

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("ollama: build /api/tags request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	httpClient := d.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ollama: /api/tags: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("ollama: /api/tags: HTTP %d", resp.StatusCode)
	}

	var parsed ollamaTagsResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, fmt.Errorf("ollama: decode /api/tags: %w", err)
	}

	out := make([]providers.Model, 0, len(parsed.Models))
	for _, m := range parsed.Models {
		display := m.Name
		// Suffix with quantization + param size when present so the
		// picker disambiguates "llama3.1:8b (Q4_0, 8.0B)" from a Q8
		// re-quant of the same tag.
		if m.Details.QuantizationLevel != "" || m.Details.ParameterSize != "" {
			parts := []string{}
			if m.Details.ParameterSize != "" {
				parts = append(parts, m.Details.ParameterSize)
			}
			if m.Details.QuantizationLevel != "" {
				parts = append(parts, m.Details.QuantizationLevel)
			}
			display = fmt.Sprintf("%s (%s)", m.Name, strings.Join(parts, ", "))
		}
		model := providers.Model{
			ID:          m.Name,
			DisplayName: display,
			Capabilities: providers.ModelCapabilities{Streaming: true},
		}
		out = append(out, model)
	}
	return out, nil
}
