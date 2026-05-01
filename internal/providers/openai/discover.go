package openai

import (
	"context"
	"errors"
	"fmt"

	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/providers"
)

// DiscoverModels lists models from the configured endpoint's /v1/models
// route and enriches each entry with metadata from the catalog when a
// CatalogProviderID is configured.
//
// Behaviour:
//   - CatalogProviderID empty → every model returned with
//     MetadataSource = SourceDriver and no enrichment fields populated.
//   - CatalogProviderID set, catalog hit → metadata copied,
//     MetadataSource = SourceCatalog.
//   - CatalogProviderID set, catalog miss → MetadataSource = SourceDriver.
//
// Models are always returned even when enrichment fails, because the user
// may want to enable a model the catalog doesn't yet know about and edit
// the snapshot manually.
func (d *Driver) DiscoverModels(ctx context.Context) ([]providers.Model, error) {
	// Quirk: provider exposes richer metadata at a non-standard endpoint
	// (xAI's /v1/language-models, Ollama's /api/tags). The hook returns
	// pre-enriched providers.Model values; we still optionally pass them
	// through the catalog enricher in case CatalogProviderID is set and
	// fills in fields the provider itself doesn't supply.
	if d.quirks.DiscoveryFunc != nil {
		raw, err := d.quirks.DiscoveryFunc(ctx, d)
		if err != nil {
			return nil, err
		}
		return d.enrichDiscovered(ctx, raw), nil
	}

	pager := d.client.Models.ListAutoPaging(ctx)

	var out []providers.Model
	for pager.Next() {
		info := pager.Current()
		out = append(out, d.enrichModel(ctx, info.ID))
	}
	if err := pager.Err(); err != nil {
		return nil, fmt.Errorf("openai-compatible: list models: %w", err)
	}
	// Quirk: when /models is empty (or returns nothing useful) and the
	// preset ships a hardcoded list (Qwen, Perplexity), fall back to it.
	if len(out) == 0 && len(d.quirks.HardcodedModels) > 0 {
		seeded := append([]providers.Model(nil), d.quirks.HardcodedModels...)
		return d.enrichDiscovered(ctx, seeded), nil
	}
	return out, nil
}

// enrichDiscovered runs models that came from a quirk source through the
// catalog enricher. Fields the source already populated win — enrichment
// only fills in unset values. This lets xAI's discovery (which has
// pricing+modalities) keep its data, while still picking up display name
// or context window from the catalog when available.
func (d *Driver) enrichDiscovered(ctx context.Context, models []providers.Model) []providers.Model {
	if d.cfg.CatalogProviderID == "" || d.deps.Catalog == nil {
		// Mark as driver-sourced for the snapshot bookkeeping.
		for i := range models {
			if models[i].MetadataSource == "" {
				models[i].MetadataSource = modelmeta.SourceDriver
			}
		}
		return models
	}
	for i := range models {
		enriched := d.enrichModel(ctx, models[i].ID)
		mergeFromCatalog(&models[i], enriched)
	}
	return models
}

// mergeFromCatalog copies catalog-sourced fields into dst only where dst
// hasn't supplied its own value. Keeps quirk-sourced data (xAI's pricing,
// Ollama's quantization) authoritative.
func mergeFromCatalog(dst *providers.Model, cat providers.Model) {
	if dst.DisplayName == "" || dst.DisplayName == dst.ID {
		dst.DisplayName = cat.DisplayName
	}
	if dst.ContextWindow == 0 {
		dst.ContextWindow = cat.ContextWindow
	}
	if dst.MaxOutputTokens == 0 {
		dst.MaxOutputTokens = cat.MaxOutputTokens
	}
	if dst.Pricing == nil {
		dst.Pricing = cat.Pricing
	}
	if !dst.Capabilities.Streaming {
		dst.Capabilities.Streaming = cat.Capabilities.Streaming
	}
	if !dst.Capabilities.Thinking {
		dst.Capabilities.Thinking = cat.Capabilities.Thinking
	}
	if !dst.Capabilities.ToolUse {
		dst.Capabilities.ToolUse = cat.Capabilities.ToolUse
	}
	if !dst.Capabilities.Vision {
		dst.Capabilities.Vision = cat.Capabilities.Vision
	}
	if !dst.Capabilities.PromptCaching {
		dst.Capabilities.PromptCaching = cat.Capabilities.PromptCaching
	}
	if len(dst.Modalities) == 0 {
		dst.Modalities = cat.Modalities
	}
	if dst.KnowledgeCutoff == "" {
		dst.KnowledgeCutoff = cat.KnowledgeCutoff
	}
	if dst.MetadataSource == "" {
		dst.MetadataSource = cat.MetadataSource
	}
}

func (d *Driver) enrichModel(ctx context.Context, modelID string) providers.Model {
	m := providers.Model{
		ID: modelID,
		// OpenAI's /v1/models doesn't return a display name; fall back to
		// the ID. The catalog (when it has the row) will leave display name
		// as the catalog's value, which we intentionally don't copy here
		// because providers.Model has no DisplayName from the catalog row
		// in the enrichment loop — see below.
		DisplayName: modelID,
	}

	if d.cfg.CatalogProviderID == "" || d.deps.Catalog == nil {
		m.MetadataSource = modelmeta.SourceDriver
		return m
	}

	cat, err := d.deps.Catalog.LookupModel(ctx, d.cfg.CatalogProviderID, modelID)
	if err != nil {
		if !errors.Is(err, modelmeta.ErrNotFound) && d.deps.Logger != nil {
			d.deps.Logger.Warn("openai-compatible: catalog lookup failed",
				"provider_id", d.cfg.CatalogProviderID,
				"model_id", modelID,
				"err", err)
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
