package modelmeta

import (
	"context"
	"sort"
	"sync"
	"time"
)

// LiveCatalog is an in-memory implementation of Catalog backed by a
// lazy fetch from models.dev. Replaces the DB-backed cache that used to
// sit in catalog_models / catalog_model_providers.
//
// Lifecycle:
//
//   - First call to LookupModel / LookupProvider / List* triggers Fetch
//     under a mutex if the cache is empty. Subsequent calls reuse it.
//   - Refresh() forces a re-fetch and replaces the cache atomically.
//   - Status() reports cached counts and the timestamp of the last
//     successful fetch (or zero values if never fetched).
//   - Stale-cache freshness is the caller's responsibility — the
//     ModelProvidersService exposes a Refresh RPC for the UI to invoke
//     when the user explicitly clicks "refresh metadata."
//
// We keep the existing Catalog interface so consumers (drivers, the
// modelproviders service) don't change. The in-memory map shapes mirror
// the DB rowToProvider/rowToModel translations.
type LiveCatalog struct {
	fetcher *Fetcher

	mu       sync.RWMutex
	loaded   bool
	loadedAt time.Time
	// Providers indexed by ID.
	providers map[string]*Provider
	// Models indexed by (providerID, modelID).
	models map[string]map[string]*Model
}

// NewLiveCatalog constructs a LiveCatalog backed by fetcher. If fetcher
// is nil, NewFetcher() supplies the default models.dev source.
func NewLiveCatalog(fetcher *Fetcher) *LiveCatalog {
	if fetcher == nil {
		fetcher = NewFetcher()
	}
	return &LiveCatalog{fetcher: fetcher}
}

// LookupModel returns the catalog entry for (providerID, modelID).
func (c *LiveCatalog) LookupModel(ctx context.Context, providerID, modelID string) (*Model, error) {
	if err := c.ensureLoaded(ctx); err != nil {
		return nil, err
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	if pm, ok := c.models[providerID]; ok {
		if m, ok := pm[modelID]; ok {
			cp := *m
			return &cp, nil
		}
	}
	return nil, ErrNotFound
}

// LookupProvider returns the catalog entry for providerID.
func (c *LiveCatalog) LookupProvider(ctx context.Context, providerID string) (*Provider, error) {
	if err := c.ensureLoaded(ctx); err != nil {
		return nil, err
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	if p, ok := c.providers[providerID]; ok {
		cp := *p
		return &cp, nil
	}
	return nil, ErrNotFound
}

// ListProviders returns every catalog provider in stable id order.
func (c *LiveCatalog) ListProviders(ctx context.Context) ([]Provider, error) {
	if err := c.ensureLoaded(ctx); err != nil {
		return nil, err
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make([]Provider, 0, len(c.providers))
	for _, p := range c.providers {
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// ListModelsByProvider returns models under providerID, alphabetised.
func (c *LiveCatalog) ListModelsByProvider(ctx context.Context, providerID string) ([]Model, error) {
	if err := c.ensureLoaded(ctx); err != nil {
		return nil, err
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	pm, ok := c.models[providerID]
	if !ok {
		return nil, nil
	}
	out := make([]Model, 0, len(pm))
	for _, m := range pm {
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// Refresh forces a fresh fetch and atomically replaces the cache. Used
// by the UI's "refresh metadata" affordance and by tests.
func (c *LiveCatalog) Refresh(ctx context.Context) error {
	snap, err := c.fetcher.Fetch(ctx)
	if err != nil {
		return err
	}
	c.replace(snap)
	return nil
}

// Status returns counts and the last refresh time.
func (c *LiveCatalog) Status(ctx context.Context) (Status, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := Status{
		ProvidersCount: len(c.providers),
	}
	for _, pm := range c.models {
		out.ModelsCount += len(pm)
	}
	if !c.loadedAt.IsZero() {
		t := c.loadedAt
		out.LastRefreshAt = &t
	}
	return out, nil
}

// ensureLoaded triggers a one-shot fetch the first time the cache is
// touched. Subsequent calls are a single RWMutex check — the fast path
// is read-only.
func (c *LiveCatalog) ensureLoaded(ctx context.Context) error {
	c.mu.RLock()
	loaded := c.loaded
	c.mu.RUnlock()
	if loaded {
		return nil
	}
	// Slow path: take the write lock, double-check, fetch.
	c.mu.Lock()
	if c.loaded {
		c.mu.Unlock()
		return nil
	}
	c.mu.Unlock()

	// Fetch outside the lock — the network call can take seconds and
	// we don't want lookup goroutines piling up behind it. Final
	// publish takes the lock again.
	snap, err := c.fetcher.Fetch(ctx)
	if err != nil {
		return err
	}
	c.replace(snap)
	return nil
}

// replace atomically substitutes the cache contents from a Snapshot.
func (c *LiveCatalog) replace(snap Snapshot) {
	providers := make(map[string]*Provider, len(snap.Providers))
	models := make(map[string]map[string]*Model, len(snap.Providers))
	for _, ps := range snap.Providers {
		p := ps.Provider
		providers[p.ID] = &p
		if len(ps.Models) > 0 {
			pm := make(map[string]*Model, len(ps.Models))
			for _, ms := range ps.Models {
				m := ms.Model
				pm[m.ID] = &m
			}
			models[p.ID] = pm
		}
	}
	c.mu.Lock()
	c.providers = providers
	c.models = models
	c.loaded = true
	c.loadedAt = snap.FetchedAt
	c.mu.Unlock()
}
