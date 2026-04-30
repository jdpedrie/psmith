package google

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/providers"
)

// geminiModelInfo is the AI-Studio /models response shape, trimmed to fields
// we care about. Full surface (input/output token limits, supported methods,
// description, etc.) is parsed but only used for filtering.
type geminiModelInfo struct {
	Name                       string   `json:"name"`
	BaseModelID                string   `json:"baseModelId,omitempty"`
	Version                    string   `json:"version,omitempty"`
	DisplayName                string   `json:"displayName,omitempty"`
	Description                string   `json:"description,omitempty"`
	SupportedGenerationMethods []string `json:"supportedGenerationMethods,omitempty"`
}

type listModelsResponse struct {
	Models        []geminiModelInfo `json:"models"`
	NextPageToken string            `json:"nextPageToken,omitempty"`
}

// DiscoverModels lists models from /v1beta/models, filtering to those that
// support generateContent, and enriches each entry via the modelmeta catalog
// when one is available.
//
// Per the architecture brief, the catalog is the canonical source of truth
// for Gemini model metadata at runtime — DiscoverModels exists to satisfy
// the Provider interface and to surface live models that the catalog might
// not yet know about. The model catalog refresher hits models.dev separately.
func (d *Driver) DiscoverModels(ctx context.Context) ([]providers.Model, error) {
	pageToken := ""
	var raw []geminiModelInfo
	for {
		page, err := d.listModelsPage(ctx, pageToken)
		if err != nil {
			return nil, err
		}
		raw = append(raw, page.Models...)
		if page.NextPageToken == "" {
			break
		}
		pageToken = page.NextPageToken
	}

	out := make([]providers.Model, 0, len(raw))
	for _, info := range raw {
		if !supportsGenerateContent(info.SupportedGenerationMethods) {
			continue
		}
		out = append(out, d.enrichModel(ctx, info))
	}
	return out, nil
}

// listModelsPage fetches a single page of /models. The endpoint takes the
// API key as a query string argument (and also accepts the x-goog-api-key
// header — we use the query string to keep the request shape simple and
// match the SSE endpoint's auth shape).
func (d *Driver) listModelsPage(ctx context.Context, pageToken string) (*listModelsResponse, error) {
	u, err := url.Parse(d.baseURL + "/models")
	if err != nil {
		return nil, fmt.Errorf("google: parse models URL: %w", err)
	}
	q := u.Query()
	q.Set("key", d.cfg.APIKey)
	q.Set("pageSize", "1000")
	if pageToken != "" {
		q.Set("pageToken", pageToken)
	}
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("google: build models request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := d.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("google: list models: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body := readBoundedError(resp)
		return nil, fmt.Errorf("google: list models: HTTP %d: %s", resp.StatusCode, body)
	}
	var page listModelsResponse
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		return nil, fmt.Errorf("google: decode models: %w", err)
	}
	return &page, nil
}

func supportsGenerateContent(methods []string) bool {
	for _, m := range methods {
		if m == "generateContent" {
			return true
		}
	}
	// If the field is absent, be permissive — the AI Studio API only recently
	// started including it for every model. The catalog filter is the real
	// source of truth.
	return len(methods) == 0
}

// enrichModel maps a Gemini /models entry into providers.Model and enriches
// it via the catalog where possible.
func (d *Driver) enrichModel(ctx context.Context, info geminiModelInfo) providers.Model {
	// Gemini's `name` is the full resource path "models/<id>". Strip the
	// prefix; downstream code keys by ID.
	id := strings.TrimPrefix(info.Name, "models/")
	display := info.DisplayName
	if display == "" {
		display = id
	}

	m := providers.Model{
		ID:          id,
		DisplayName: display,
	}

	if d.deps.Catalog == nil {
		m.MetadataSource = modelmeta.SourceDriver
		return m
	}

	cat, err := d.deps.Catalog.LookupModel(ctx, "google", id)
	if err != nil {
		if !errors.Is(err, modelmeta.ErrNotFound) {
			d.logger().Warn("google: catalog lookup failed",
				"model_id", id, "err", err)
		}
		m.MetadataSource = modelmeta.SourceDriver
		return m
	}

	if cat.DisplayName != "" {
		m.DisplayName = cat.DisplayName
	}
	m.ContextWindow = cat.ContextWindow
	m.MaxOutputTokens = cat.MaxOutputTokens
	if cat.Pricing != nil {
		m.Pricing = &providers.Pricing{
			InputPerMillion:      cat.Pricing.InputPerMillion,
			OutputPerMillion:     cat.Pricing.OutputPerMillion,
			CacheReadPerMillion:  cat.Pricing.CacheReadPerMillion,
			CacheWritePerMillion: cat.Pricing.CacheWritePerMillion,
		}
	}
	m.Capabilities = providers.ModelCapabilities{
		Streaming:     cat.Capabilities.Streaming,
		Thinking:      cat.Capabilities.Thinking,
		ToolUse:       cat.Capabilities.ToolUse,
		Vision:        cat.Capabilities.Vision,
		PromptCaching: cat.Capabilities.PromptCaching,
	}
	if len(cat.Modalities) > 0 {
		m.Modalities = append([]string(nil), cat.Modalities...)
	}
	if cat.KnowledgeCutoff != nil {
		m.KnowledgeCutoff = cat.KnowledgeCutoff.Format("2006-01-02")
	}
	m.MetadataSource = modelmeta.SourceCatalog
	return m
}
