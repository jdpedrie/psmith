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

// PricingTier is one context-size pricing step (grok-4.5-style: a
// different rate card once the prompt exceeds a threshold). Stored on
// user_models.pricing_tiers as a JSON array; the catalog source
// (models.dev) doesn't carry tiers, so these are user-maintained via
// the model edit surface. Nil subfields inherit the base (flat-column)
// price for that component.
type PricingTier struct {
	ThresholdTokens      int      `json:"threshold_tokens"`
	InputPerMillion      *float64 `json:"input_per_million,omitempty"`
	OutputPerMillion     *float64 `json:"output_per_million,omitempty"`
	CacheReadPerMillion  *float64 `json:"cache_read_per_million,omitempty"`
	CacheWritePerMillion *float64 `json:"cache_write_per_million,omitempty"`
}

// EffectiveTier returns the tier with the highest threshold strictly
// below promptTokens, or nil when no tier applies (base pricing).
// Provider semantics: the WHOLE request prices at the winning tier,
// not marginally.
func EffectiveTier(tiers []PricingTier, promptTokens int) *PricingTier {
	var best *PricingTier
	for i := range tiers {
		t := &tiers[i]
		if promptTokens > t.ThresholdTokens {
			if best == nil || t.ThresholdTokens > best.ThresholdTokens {
				best = t
			}
		}
	}
	return best
}

type Capabilities struct {
	Streaming bool
	Thinking  bool
	ToolUse   bool
	// Vision is the input modality — model accepts image
	// attachments in user messages.
	Vision        bool
	PromptCaching bool
	// GeneratesImages is the output modality — model produces
	// image bytes in its response. Drives the `MODEL_PICKER`
	// filter in modality-aware plugin config (e.g. `imagegen`).
	GeneratesImages bool
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
