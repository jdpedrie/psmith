package anthropic

import (
	"context"
	"errors"
	"fmt"

	sdk "github.com/anthropics/anthropic-sdk-go"

	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/providers"
)

// DiscoverModels lists models from Anthropic's /v1/models endpoint and
// enriches each entry with metadata from the catalog where available.
//
// Catalog miss → MetadataSource = SourceDriver and numeric fields are left
// at their zero values; the caller (UI) can surface this so the user knows
// to add a manual snapshot.
func (d *Driver) DiscoverModels(ctx context.Context) ([]providers.Model, error) {
	pager := d.client.Models.ListAutoPaging(ctx, sdk.ModelListParams{})

	var out []providers.Model
	for pager.Next() {
		info := pager.Current()
		out = append(out, d.enrichModel(ctx, info))
	}
	if err := pager.Err(); err != nil {
		return nil, fmt.Errorf("anthropic: list models: %w", err)
	}
	return out, nil
}

func (d *Driver) enrichModel(ctx context.Context, info sdk.ModelInfo) providers.Model {
	m := providers.Model{
		ID:          info.ID,
		DisplayName: info.DisplayName,
	}

	if d.deps.Catalog == nil {
		m.MetadataSource = modelmeta.SourceDriver
		return m
	}

	cat, err := d.deps.Catalog.LookupModel(ctx, "anthropic", info.ID)
	if err != nil {
		if !errors.Is(err, modelmeta.ErrNotFound) && d.deps.Logger != nil {
			d.deps.Logger.Warn("anthropic: catalog lookup failed",
				"model_id", info.ID, "err", err)
		}
		m.MetadataSource = modelmeta.SourceDriver
		return m
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
