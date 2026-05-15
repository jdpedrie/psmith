package plugins

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// ImagegenName is the registered name for the image-gen tool plugin.
const ImagegenName = "imagegen"

const (
	imagegenDefaultOpenAIEndpoint = "https://api.openai.com/v1/images/generations"
	imagegenDefaultGoogleHost     = "https://generativelanguage.googleapis.com"
	imagegenDefaultSize           = "1024x1024"
	imagegenDefaultQuality        = "high"
	imagegenDefaultTimeout        = 60 * time.Second
)

// imagegen declares one tool — `generate_image` — that the model can call to
// produce an image from a text prompt. Implements ToolProvider + Configurable.
//
// The plugin's only persisted config is a `model` field of
// MODEL_PICKER type. At ExecuteTool time, the plugin resolves the
// chosen (provider_id, model_id) pair through the
// `ProviderResolver` injected on the dispatch context, picks the
// right upstream API based on the resolved provider type, and
// returns the generated image as a `ToolAttachment`. Generated
// images flow through the existing tool-result attachment
// pipeline — they persist on the assistant message with
// role_hint=tool_result and (on Anthropic + Google) ride back
// into the next-round wire prefix so the model can iterate.
//
// Provider dispatch:
//
//   - openai-compatible → POST /v1/images/generations (works for the
//     real OpenAI endpoint with gpt-image-1 / dall-e-3, and any
//     gateway speaking the same shape).
//   - google → POST /v1beta/models/{model}:generateContent with
//     `responseModalities: ["TEXT","IMAGE"]` — covers
//     gemini-2.5-flash-image-preview ("nano banana").
//
// Other provider types return a clear error so a misconfigured
// model doesn't silently fail mid-tool-call.
type imagegen struct {
	cfg    imagegenConfig
	client *http.Client
}

// imagegenConfig is the per-instance config. The only required
// field is `model` (a MODEL_PICKER selection). Default size +
// quality apply when the model doesn't override on a per-call
// basis.
type imagegenConfig struct {
	// Model holds the user's MODEL_PICKER choice — a
	// (provider_id, model_id) pair the plugin resolves at
	// ExecuteTool time via the dispatch-context ProviderResolver.
	// Empty / unset = the plugin can't run; ExecuteTool surfaces
	// a clear error.
	Model imagegenModelRef `json:"model"`

	// Size is the default rendered size when the model doesn't
	// pass one. Meaning is per-provider — OpenAI accepts e.g.
	// "1024x1024" / "1024x1536"; Google ignores it (Gemini
	// picks dimensions based on the model). Defaults to
	// "1024x1024".
	Size string `json:"size"`

	// Quality maps to OpenAI's `quality` parameter ("low",
	// "medium", "high", "auto" for gpt-image-1; "standard",
	// "hd" for dall-e-3). Ignored by the Google path. Defaults
	// to "high".
	Quality string `json:"quality"`

	// EndpointOverride lets test harnesses point the plugin at a
	// fake URL. Empty = production.
	EndpointOverride string `json:"endpoint_override"`
}

// imagegenModelRef is the (provider_id, model_id) tuple a
// MODEL_PICKER persists. Mirrors how conversation settings store
// a chosen model.
type imagegenModelRef struct {
	ProviderID string `json:"provider_id"`
	ModelID    string `json:"model_id"`
}

// imagegenInput is the JSON Schema-described input the model
// passes on tool_use. Only `prompt` is required; size + quality
// are per-call overrides of the plugin defaults.
type imagegenInput struct {
	Prompt  string `json:"prompt"`
	Size    string `json:"size,omitempty"`
	Quality string `json:"quality,omitempty"`
}

func newImagegen(configBytes json.RawMessage) (Plugin, error) {
	cfg := imagegenConfig{
		Size:    imagegenDefaultSize,
		Quality: imagegenDefaultQuality,
	}
	if len(configBytes) > 0 {
		if err := json.Unmarshal(configBytes, &cfg); err != nil {
			return nil, fmt.Errorf("imagegen: parse config: %w", err)
		}
	}
	if cfg.Size == "" {
		cfg.Size = imagegenDefaultSize
	}
	if cfg.Quality == "" {
		cfg.Quality = imagegenDefaultQuality
	}
	return &imagegen{
		cfg:    cfg,
		client: &http.Client{Timeout: imagegenDefaultTimeout},
	}, nil
}

func init() {
	Register(ImagegenName, newImagegen)
}

func (p *imagegen) Name() string        { return ImagegenName }
func (p *imagegen) DisplayName() string { return "Image Generation" }

func (p *imagegen) Description() string {
	return "Gives the model a generate_image tool. Pick any image-capable model from your existing providers " +
		"(OpenAI gpt-image-1 / dall-e-3, Google gemini-2.5-flash-image-preview / 'nano banana', etc.) — " +
		"the plugin dispatches to the right upstream API based on the chosen model's provider. " +
		"Generated images attach to the assistant turn that produced them and ride back into the " +
		"next round's wire prefix on providers that support image-in-tool-result so the model can iterate."
}

// --- Configurable ---

func (p *imagegen) ConfigFields() []ConfigField {
	return []ConfigField{
		{
			Name:        "model",
			Display:     "Image model",
			Description: "Pick any model that can generate images. Filtered to models with the image-output capability.",
			Type:        ConfigFieldModelPicker,
			Required:    true,
			ModelPickerFilter: ModelPickerFilter{
				RequiresGeneratesImages: true,
			},
		},
		{
			Name:        "size",
			Display:     "Default size",
			Description: "Rendered size when the model doesn't pass one. OpenAI: 1024x1024 / 1024x1536 / 1536x1024 / auto. Google ignores this (the model picks).",
			Type:        ConfigFieldSelect,
			Default:     imagegenDefaultSize,
			Options: []ConfigOption{
				{Value: "1024x1024", Label: "1024×1024 (square)"},
				{Value: "1024x1536", Label: "1024×1536 (portrait)"},
				{Value: "1536x1024", Label: "1536×1024 (landscape)"},
				{Value: "auto", Label: "auto (model picks)"},
			},
		},
		{
			Name:        "quality",
			Display:     "Default quality",
			Description: "OpenAI gpt-image-1: low / medium / high / auto. dall-e-3: standard / hd. Google ignores this.",
			Type:        ConfigFieldSelect,
			Default:     imagegenDefaultQuality,
			Options: []ConfigOption{
				{Value: "low", Label: "low (gpt-image-1)"},
				{Value: "medium", Label: "medium (gpt-image-1)"},
				{Value: "high", Label: "high (gpt-image-1)"},
				{Value: "auto", Label: "auto"},
				{Value: "standard", Label: "standard (dall-e-3)"},
				{Value: "hd", Label: "hd (dall-e-3)"},
			},
		},
	}
}

// --- ToolProvider ---

func (p *imagegen) Tools() []ToolDef {
	schema := []byte(`{
  "type": "object",
  "properties": {
    "prompt": {
      "type": "string",
      "description": "Plain-language description of the image to generate. Be specific about subject, style, composition, and lighting — the model treats the prompt verbatim."
    },
    "size": {
      "type": "string",
      "description": "Optional size override (OpenAI only; Google ignores). Common values: 1024x1024, 1024x1536, 1536x1024, auto.",
      "enum": ["1024x1024", "1024x1536", "1536x1024", "auto"]
    },
    "quality": {
      "type": "string",
      "description": "Optional quality override (OpenAI only). gpt-image-1: low/medium/high/auto. dall-e-3: standard/hd.",
      "enum": ["low", "medium", "high", "auto", "standard", "hd"]
    }
  },
  "required": ["prompt"]
}`)
	return []ToolDef{
		{
			Name:        "generate_image",
			Description: "Generate an image from a text prompt. Returns the generated image as an attachment on this turn — the user sees it inline and you can reference it on the next round.",
			InputSchema: schema,
		},
	}
}

func (p *imagegen) ExecuteTool(ctx context.Context, name string, input json.RawMessage) (ToolResult, error) {
	if name != "generate_image" {
		return ToolResult{}, fmt.Errorf("imagegen: unknown tool %q", name)
	}
	if p.cfg.Model.ProviderID == "" || p.cfg.Model.ModelID == "" {
		return ToolResult{}, fmt.Errorf("imagegen: model is not configured")
	}

	resolver := ProviderResolverFrom(ctx)
	if resolver == nil {
		return ToolResult{}, fmt.Errorf("imagegen: no ProviderResolver in context — server not wired")
	}
	resolved, err := resolver.ResolveModel(ctx, p.cfg.Model.ProviderID, p.cfg.Model.ModelID)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: resolve model: %w", err)
	}
	if resolved.APIKey == "" {
		return ToolResult{}, fmt.Errorf("imagegen: provider %q has no api_key configured", resolved.ProviderType)
	}

	var in imagegenInput
	if err := json.Unmarshal(input, &in); err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: parse input: %w", err)
	}
	in.Prompt = strings.TrimSpace(in.Prompt)
	if in.Prompt == "" {
		return ToolResult{}, fmt.Errorf("imagegen: prompt is required")
	}
	size := in.Size
	if size == "" {
		size = p.cfg.Size
	}
	quality := in.Quality
	if quality == "" {
		quality = p.cfg.Quality
	}

	switch resolved.ProviderType {
	case "openai-compatible":
		return p.callOpenAI(ctx, resolved, in.Prompt, size, quality)
	case "google":
		return p.callGoogle(ctx, resolved, in.Prompt)
	default:
		return ToolResult{}, fmt.Errorf("imagegen: provider type %q not supported (use openai-compatible or google)", resolved.ProviderType)
	}
}

// --- OpenAI dispatch (gpt-image-1, dall-e-3, gateways speaking the same API) ---

type imagegenOpenAIResponse struct {
	Data []struct {
		B64JSON       string `json:"b64_json"`
		RevisedPrompt string `json:"revised_prompt,omitempty"`
	} `json:"data"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

func (p *imagegen) callOpenAI(ctx context.Context, resolved ResolvedModel, prompt, size, quality string) (ToolResult, error) {
	endpoint := p.cfg.EndpointOverride
	if endpoint == "" {
		base := resolved.BaseURL
		if base == "" {
			endpoint = imagegenDefaultOpenAIEndpoint
		} else {
			endpoint = strings.TrimRight(base, "/") + "/images/generations"
		}
	}

	body := map[string]any{
		"model":   resolved.ModelID,
		"prompt":  prompt,
		"n":       1,
		"size":    size,
		"quality": quality,
	}
	// dall-e-3 requires response_format=b64_json to return base64;
	// gpt-image-1 returns base64 by default and rejects the field.
	if resolved.ModelID == "dall-e-3" {
		body["response_format"] = "b64_json"
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: encode body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+resolved.APIKey)

	resp, err := p.client.Do(req)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: http call: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: read body: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return ToolResult{}, fmt.Errorf("imagegen: openai %s — %s", resp.Status, truncate(string(respBody), 240))
	}
	var raw imagegenOpenAIResponse
	if err := json.Unmarshal(respBody, &raw); err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: decode response: %w", err)
	}
	if raw.Error != nil && raw.Error.Message != "" {
		return ToolResult{}, fmt.Errorf("imagegen: %s", raw.Error.Message)
	}
	if len(raw.Data) == 0 || raw.Data[0].B64JSON == "" {
		return ToolResult{}, fmt.Errorf("imagegen: openai response missing image data")
	}
	imgBytes, err := base64.StdEncoding.DecodeString(raw.Data[0].B64JSON)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: decode b64_json: %w", err)
	}

	out := map[string]any{
		"prompt":           prompt,
		"size":             size,
		"quality":          quality,
		"model":            resolved.ModelID,
		"attachment_count": 1,
	}
	if raw.Data[0].RevisedPrompt != "" {
		out["revised_prompt"] = raw.Data[0].RevisedPrompt
	}
	encoded, _ := json.Marshal(out)
	return ToolResult{
		Output: encoded,
		Attachments: []ToolAttachment{{
			Kind:     "image",
			MimeType: "image/png",
			Data:     imgBytes,
			Filename: "generated.png",
		}},
	}, nil
}

// --- Google dispatch (gemini-2.5-flash-image-preview, etc.) ---

type imagegenGoogleResponse struct {
	Candidates []struct {
		Content struct {
			Parts []struct {
				Text       string `json:"text,omitempty"`
				InlineData *struct {
					MimeType string `json:"mimeType"`
					Data     string `json:"data"`
				} `json:"inlineData,omitempty"`
			} `json:"parts"`
		} `json:"content"`
	} `json:"candidates"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

func (p *imagegen) callGoogle(ctx context.Context, resolved ResolvedModel, prompt string) (ToolResult, error) {
	endpoint := p.cfg.EndpointOverride
	if endpoint == "" {
		base := resolved.BaseURL
		if base == "" {
			base = imagegenDefaultGoogleHost
		}
		endpoint = strings.TrimRight(base, "/") + "/v1beta/models/" + resolved.ModelID + ":generateContent"
	}

	body := map[string]any{
		"contents": []map[string]any{
			{"parts": []map[string]any{{"text": prompt}}},
		},
		"generationConfig": map[string]any{
			// Asks Gemini to emit both text and image parts; without
			// this the model ignores the image-output capability and
			// answers with text only.
			"responseModalities": []string{"TEXT", "IMAGE"},
		},
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: encode body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	// Gemini accepts the API key via either query param OR header;
	// the header form keeps the URL clean and avoids logging keys
	// in proxies.
	req.Header.Set("x-goog-api-key", resolved.APIKey)

	resp, err := p.client.Do(req)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: http call: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: read body: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return ToolResult{}, fmt.Errorf("imagegen: google %s — %s", resp.Status, truncate(string(respBody), 240))
	}
	var raw imagegenGoogleResponse
	if err := json.Unmarshal(respBody, &raw); err != nil {
		return ToolResult{}, fmt.Errorf("imagegen: decode response: %w", err)
	}
	if raw.Error != nil && raw.Error.Message != "" {
		return ToolResult{}, fmt.Errorf("imagegen: %s", raw.Error.Message)
	}

	// Walk the candidate parts; pick the first inlineData image.
	// Capture any text parts as the model's narration so the
	// next-round JSON envelope carries useful context.
	var attachments []ToolAttachment
	var narration strings.Builder
	for _, cand := range raw.Candidates {
		for _, part := range cand.Content.Parts {
			if part.InlineData != nil && part.InlineData.Data != "" {
				data, err := base64.StdEncoding.DecodeString(part.InlineData.Data)
				if err != nil {
					continue
				}
				mime := part.InlineData.MimeType
				if mime == "" {
					mime = "image/png"
				}
				attachments = append(attachments, ToolAttachment{
					Kind:     "image",
					MimeType: mime,
					Data:     data,
					Filename: "generated.png",
				})
			}
			if part.Text != "" {
				if narration.Len() > 0 {
					narration.WriteString("\n")
				}
				narration.WriteString(part.Text)
			}
		}
	}
	if len(attachments) == 0 {
		return ToolResult{}, fmt.Errorf("imagegen: google response had no image parts")
	}

	out := map[string]any{
		"prompt":           prompt,
		"model":            resolved.ModelID,
		"attachment_count": len(attachments),
	}
	if narration.Len() > 0 {
		out["narration"] = narration.String()
	}
	encoded, _ := json.Marshal(out)
	return ToolResult{
		Output:      encoded,
		Attachments: attachments,
	}, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
