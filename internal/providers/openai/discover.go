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
	pager := d.client.Models.ListAutoPaging(ctx)

	var out []providers.Model
	for pager.Next() {
		info := pager.Current()
		out = append(out, d.enrichModel(ctx, info.ID))
	}
	if err := pager.Err(); err != nil {
		return nil, fmt.Errorf("openai-compatible: list models: %w", err)
	}
	return out, nil
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
