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
//   - A snapshot older than maxAge is refreshed in-line by the next
//     caller (one request pays the fetch every ~12h; concurrent callers
//     serve the stale snapshot instead of piling up). A failed refresh
//     serves the stale snapshot — stale beats dead, and the next caller
//     retries.
//   - Refresh() forces a re-fetch and replaces the cache atomically.
//   - Status() reports cached counts and the timestamp of the last
//     successful fetch (or zero values if never fetched).
//
// We keep the existing Catalog interface so consumers (drivers, the
// modelproviders service) don't change. The in-memory map shapes mirror
// the DB rowToProvider/rowToModel translations.
type LiveCatalog struct {
	fetcher *Fetcher
	// maxAge is how old the snapshot may be before a lookup triggers a
	// re-fetch. Without this a long-running daemon serves its launch-day
	// model list forever and newly released models never appear in
	// discovery.
	maxAge time.Duration

	mu       sync.RWMutex
	loaded   bool
	loadedAt time.Time
	fetching bool
	// lastAttempt gates refresh retries after a failure. Without it a
	// models.dev outage would make every catalog lookup pay a doomed
	// network round-trip until the outage ends.
	lastAttempt time.Time
	// Providers indexed by ID.
	providers map[string]*Provider
	// Models indexed by (providerID, modelID).
	models map[string]map[string]*Model
}

// defaultCatalogMaxAge bounds how stale the models.dev snapshot may get
// before a lookup refreshes it. models.dev updates within hours of a
// model release; 12h keeps discovery current without hammering it.
const defaultCatalogMaxAge = 12 * time.Hour

// refreshRetryBackoff is the minimum gap between refresh attempts once
// the snapshot is past maxAge. It only matters when refreshes fail
// (success resets loadedAt); it stops an outage from turning every
// lookup into a doomed network call.
const refreshRetryBackoff = 5 * time.Minute

// NewLiveCatalog constructs a LiveCatalog backed by fetcher. If fetcher
// is nil, NewFetcher() supplies the default models.dev source.
func NewLiveCatalog(fetcher *Fetcher) *LiveCatalog {
	if fetcher == nil {
		fetcher = NewFetcher()
	}
	return &LiveCatalog{fetcher: fetcher, maxAge: defaultCatalogMaxAge}
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

// LoadSnapshot replaces the cache with a literal Snapshot, marking it
// loaded as if Refresh had succeeded. Test-only helper — production code
// always reaches the cache via the Fetcher (Refresh / lazy-load paths).
func (c *LiveCatalog) LoadSnapshot(snap Snapshot) {
	c.replace(snap)
}

// MergeSnapshot adds the snapshot's providers and models to the cache
// without removing existing entries. Test-only helper for fixtures that
// build up the catalog across multiple seedCatalog calls — production
// flows (Refresh, lazy-load) always replace wholesale to avoid leaking
// retired entries.
func (c *LiveCatalog) MergeSnapshot(snap Snapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.providers == nil {
		c.providers = make(map[string]*Provider)
	}
	if c.models == nil {
		c.models = make(map[string]map[string]*Model)
	}
	for _, ps := range snap.Providers {
		p := ps.Provider
		c.providers[p.ID] = &p
		pm, ok := c.models[p.ID]
		if !ok {
			pm = make(map[string]*Model, len(ps.Models))
			c.models[p.ID] = pm
		}
		for _, ms := range ps.Models {
			m := ms.Model
			pm[m.ID] = &m
		}
	}
	c.loaded = true
	if snap.FetchedAt.After(c.loadedAt) {
		c.loadedAt = snap.FetchedAt
	}
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

// ensureLoaded fetches on first touch and re-fetches when the snapshot
// is older than maxAge. The fast path is a single RWMutex check. When a
// refresh is due, exactly one caller performs it (in-line, outside the
// lock); concurrent callers serve the existing snapshot rather than
// piling up behind the fetch. A failed refresh with a snapshot in hand
// serves stale — the next caller past maxAge retries.
func (c *LiveCatalog) ensureLoaded(ctx context.Context) error {
	c.mu.RLock()
	loaded := c.loaded
	fresh := loaded && (c.maxAge <= 0 || time.Since(c.loadedAt) < c.maxAge)
	c.mu.RUnlock()
	if fresh {
		return nil
	}

	// Slow path: claim the fetch under the write lock. The lock is
	// released exactly once, below, on every path.
	c.mu.Lock()
	loaded = c.loaded
	claimed := false
	switch {
	case loaded && (c.maxAge <= 0 || time.Since(c.loadedAt) < c.maxAge):
		c.mu.Unlock()
		return nil // another caller refreshed while we waited
	case loaded && time.Since(c.lastAttempt) < refreshRetryBackoff:
		c.mu.Unlock()
		return nil // a recent attempt failed; serve stale, retry later
	case c.fetching && loaded:
		c.mu.Unlock()
		return nil // serve stale while the claiming caller refreshes
	case c.fetching:
		// Cold start with a fetch already in flight: fall through and
		// fetch too rather than inventing a wait queue. The duplicate
		// fetch is bounded to process startup, and we must not clear
		// the claiming caller's flag on the way out.
	default:
		c.fetching = true
		c.lastAttempt = time.Now()
		claimed = true
	}
	c.mu.Unlock()
	if claimed {
		defer func() {
			c.mu.Lock()
			c.fetching = false
			c.mu.Unlock()
		}()
	}

	// Fetch outside the lock — the network call can take seconds and
	// we don't want lookup goroutines piling up behind it. Final
	// publish takes the lock again.
	snap, err := c.fetcher.Fetch(ctx)
	if err != nil {
		if loaded {
			return nil // stale beats dead
		}
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
