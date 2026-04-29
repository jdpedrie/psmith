// Package modelmeta is the catalog of model metadata refreshed periodically
// from models.dev. Provides lookup APIs that drivers use to enrich the IDs
// they discover from provider APIs with full metadata (pricing, capabilities,
// context window, etc.).
package modelmeta

import (
	"context"
	"errors"
	"time"
)

// Source records where a piece of model metadata came from.
type Source string

const (
	SourceCatalog Source = "catalog"
	SourceDriver  Source = "driver"
	SourceManual  Source = "manual"
)

// ErrNotFound is returned when a lookup misses.
var ErrNotFound = errors.New("modelmeta: not found")

// Provider is a known catalog provider entry (typically corresponds to a
// models.dev provider record).
type Provider struct {
	ID        string
	Name      string
	APIBase   string
	EnvKey    string
	DocURL    string
	NPM       string
	FetchedAt time.Time
}

// Model is the catalog metadata for a single model.
type Model struct {
	ProviderID      string
	ID              string
	DisplayName     string
	ContextWindow   int
	MaxOutputTokens int
	Pricing         *Pricing
	Capabilities    Capabilities
	Modalities      []string
	KnowledgeCutoff *time.Time
	FetchedAt       time.Time
}

type Pricing struct {
	InputPerMillion      float64
	OutputPerMillion     float64
	CacheReadPerMillion  float64
	CacheWritePerMillion float64
}

type Capabilities struct {
	Streaming     bool
	Thinking      bool
	ToolUse       bool
	Vision        bool
	PromptCaching bool
}

// Status is a snapshot of the catalog contents.
type Status struct {
	ProvidersCount int
	ModelsCount    int
	LastRefreshAt  *time.Time
}

// Catalog is the lookup + refresh surface used by drivers and the
// ModelProvidersService catalog RPCs.
type Catalog interface {
	// LookupModel returns the catalog entry for (providerID, modelID).
	// Returns ErrNotFound if absent.
	LookupModel(ctx context.Context, providerID, modelID string) (*Model, error)

	// LookupProvider returns the catalog entry for providerID.
	// Returns ErrNotFound if absent.
	LookupProvider(ctx context.Context, providerID string) (*Provider, error)

	// ListProviders returns all catalog providers (used to surface templates).
	ListProviders(ctx context.Context) ([]Provider, error)

	// ListModelsByProvider returns every catalog model under providerID,
	// alphabetised. Used by the discovery flow when a user_model_provider
	// has a `catalog_provider_id` configured — we trust the catalog as the
	// source of truth instead of hitting the live provider API.
	ListModelsByProvider(ctx context.Context, providerID string) ([]Model, error)

	// Refresh fetches the latest data from the upstream source (models.dev) and
	// upserts both providers and models. Idempotent.
	Refresh(ctx context.Context) error

	// Status returns counts and the last refresh time.
	Status(ctx context.Context) (Status, error)
}
