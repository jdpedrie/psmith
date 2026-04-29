package modelmeta

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/jdpedrie/clark/internal/store"
)

// DBCatalog is a Catalog backed by the catalog_model_providers and
// catalog_models tables. Refresh delegates to a Fetcher (defaults to models.dev).
type DBCatalog struct {
	queries *store.Queries
	fetcher *Fetcher
}

func NewDBCatalog(queries *store.Queries, fetcher *Fetcher) *DBCatalog {
	if fetcher == nil {
		fetcher = NewFetcher()
	}
	return &DBCatalog{queries: queries, fetcher: fetcher}
}

func (c *DBCatalog) LookupModel(ctx context.Context, providerID, modelID string) (*Model, error) {
	row, err := c.queries.GetCatalogModel(ctx, store.GetCatalogModelParams{
		ProviderID: providerID,
		ModelID:    modelID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("modelmeta: lookup model: %w", err)
	}
	return rowToModel(row), nil
}

func (c *DBCatalog) LookupProvider(ctx context.Context, providerID string) (*Provider, error) {
	row, err := c.queries.GetCatalogProvider(ctx, providerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("modelmeta: lookup provider: %w", err)
	}
	return rowToProvider(row), nil
}

func (c *DBCatalog) ListProviders(ctx context.Context) ([]Provider, error) {
	rows, err := c.queries.ListCatalogProviders(ctx)
	if err != nil {
		return nil, fmt.Errorf("modelmeta: list providers: %w", err)
	}
	out := make([]Provider, len(rows))
	for i, r := range rows {
		out[i] = *rowToProvider(r)
	}
	return out, nil
}

func (c *DBCatalog) ListModelsByProvider(ctx context.Context, providerID string) ([]Model, error) {
	rows, err := c.queries.ListCatalogModelsByProvider(ctx, providerID)
	if err != nil {
		return nil, fmt.Errorf("modelmeta: list models: %w", err)
	}
	out := make([]Model, len(rows))
	for i, r := range rows {
		out[i] = *rowToModel(r)
	}
	return out, nil
}

// Refresh fetches the latest snapshot and upserts everything. Failures partway
// through leave the table in an inconsistent state — callers should treat the
// catalog as eventually-consistent across refreshes.
func (c *DBCatalog) Refresh(ctx context.Context) error {
	snap, err := c.fetcher.Fetch(ctx)
	if err != nil {
		return fmt.Errorf("modelmeta: fetch: %w", err)
	}
	return c.Upsert(ctx, snap)
}

// Upsert writes a Snapshot into the catalog tables. Exposed so tests and
// alternative ingestion sources can populate the catalog without going through
// the HTTP fetcher.
func (c *DBCatalog) Upsert(ctx context.Context, snap Snapshot) error {
	for _, ps := range snap.Providers {
		if err := c.queries.UpsertCatalogProvider(ctx, store.UpsertCatalogProviderParams{
			ID:        ps.Provider.ID,
			Name:      ps.Provider.Name,
			ApiBase:   strPtr(ps.Provider.APIBase),
			EnvKey:    strPtr(ps.Provider.EnvKey),
			DocUrl:    strPtr(ps.Provider.DocURL),
			Npm:       strPtr(ps.Provider.NPM),
			Raw:       ps.RawJSON,
			FetchedAt: ps.Provider.FetchedAt,
		}); err != nil {
			return fmt.Errorf("modelmeta: upsert provider %q: %w", ps.Provider.ID, err)
		}
		for _, ms := range ps.Models {
			capJSON, err := json.Marshal(ms.Model.Capabilities)
			if err != nil {
				return fmt.Errorf("modelmeta: marshal capabilities for %q: %w", ms.Model.ID, err)
			}
			if err := c.queries.UpsertCatalogModel(ctx, store.UpsertCatalogModelParams{
				ProviderID:            ps.Provider.ID,
				ModelID:               ms.Model.ID,
				DisplayName:           ms.Model.DisplayName,
				ContextWindow:         intPtrOrNil(ms.Model.ContextWindow),
				MaxOutputTokens:       intPtrOrNil(ms.Model.MaxOutputTokens),
				InputPricePerMillion:  pricingPtr(ms.Model.Pricing, func(p *Pricing) float64 { return p.InputPerMillion }),
				OutputPricePerMillion: pricingPtr(ms.Model.Pricing, func(p *Pricing) float64 { return p.OutputPerMillion }),
				CacheReadPerMillion:   pricingPtr(ms.Model.Pricing, func(p *Pricing) float64 { return p.CacheReadPerMillion }),
				CacheWritePerMillion:  pricingPtr(ms.Model.Pricing, func(p *Pricing) float64 { return p.CacheWritePerMillion }),
				KnowledgeCutoff:       dateOrNull(ms.Model.KnowledgeCutoff),
				Modalities:            ms.Model.Modalities,
				Capabilities:          capJSON,
				Raw:                   ms.RawJSON,
				FetchedAt:             ms.Model.FetchedAt,
			}); err != nil {
				return fmt.Errorf("modelmeta: upsert model %q/%q: %w", ps.Provider.ID, ms.Model.ID, err)
			}
		}
	}
	return nil
}

func (c *DBCatalog) Status(ctx context.Context) (Status, error) {
	pc, err := c.queries.CountCatalogProviders(ctx)
	if err != nil {
		return Status{}, err
	}
	mc, err := c.queries.CountCatalogModels(ctx)
	if err != nil {
		return Status{}, err
	}
	out := Status{ProvidersCount: int(pc), ModelsCount: int(mc)}
	if pc > 0 {
		t, err := c.queries.LatestCatalogFetch(ctx)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return Status{}, err
		}
		if !t.IsZero() {
			out.LastRefreshAt = &t
		}
	}
	return out, nil
}

// --- conversion helpers ---

func rowToProvider(r store.CatalogModelProvider) *Provider {
	return &Provider{
		ID:        r.ID,
		Name:      r.Name,
		APIBase:   derefStr(r.ApiBase),
		EnvKey:    derefStr(r.EnvKey),
		DocURL:    derefStr(r.DocUrl),
		NPM:       derefStr(r.Npm),
		FetchedAt: r.FetchedAt,
	}
}

func rowToModel(r store.CatalogModel) *Model {
	m := &Model{
		ProviderID:      r.ProviderID,
		ID:              r.ModelID,
		DisplayName:     r.DisplayName,
		ContextWindow:   derefInt(r.ContextWindow),
		MaxOutputTokens: derefInt(r.MaxOutputTokens),
		Modalities:      r.Modalities,
		FetchedAt:       r.FetchedAt,
	}
	if hasAnyPricing(r) {
		m.Pricing = &Pricing{
			InputPerMillion:      derefFloat(r.InputPricePerMillion),
			OutputPerMillion:     derefFloat(r.OutputPricePerMillion),
			CacheReadPerMillion:  derefFloat(r.CacheReadPerMillion),
			CacheWritePerMillion: derefFloat(r.CacheWritePerMillion),
		}
	}
	if len(r.Capabilities) > 0 {
		_ = json.Unmarshal(r.Capabilities, &m.Capabilities)
	}
	if r.KnowledgeCutoff.Valid {
		t := r.KnowledgeCutoff.Time
		m.KnowledgeCutoff = &t
	}
	return m
}

func hasAnyPricing(r store.CatalogModel) bool {
	return r.InputPricePerMillion != nil || r.OutputPricePerMillion != nil ||
		r.CacheReadPerMillion != nil || r.CacheWritePerMillion != nil
}

func intPtrOrNil(v int) *int32 {
	if v == 0 {
		return nil
	}
	x := int32(v)
	return &x
}

func pricingPtr(p *Pricing, get func(*Pricing) float64) *float64 {
	if p == nil {
		return nil
	}
	v := get(p)
	if v == 0 {
		return nil
	}
	return &v
}

func dateOrNull(t *time.Time) pgtype.Date {
	if t == nil {
		return pgtype.Date{}
	}
	return pgtype.Date{Time: *t, Valid: true}
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefInt(p *int32) int {
	if p == nil {
		return 0
	}
	return int(*p)
}

func derefFloat(p *float64) float64 {
	if p == nil {
		return 0
	}
	return *p
}
