package plugins

import "context"

// ProviderResolver gives a plugin enough information to call an
// upstream provider's API directly. The conversations service
// implements it (it owns the queries + cipher needed to decrypt
// api_keys) and injects an instance into the ExecuteTool context;
// plugins read it via `ProviderResolverFrom(ctx)`.
//
// Use case: a `MODEL_PICKER` config field stores the chosen
// (provider_id, model_id) pair. At ExecuteTool time the plugin
// asks the resolver to turn that pair into the credentials +
// metadata it needs to dispatch to the right upstream API.
//
// Plugins that only call their own self-configured endpoint (e.g.
// brave_search) don't need a resolver — the per-plugin api_key
// already in their config is enough.
type ProviderResolver interface {
	// ResolveModel looks up the user_model + its owning provider
	// and returns the unsealed credentials a plugin needs to
	// dispatch a call. Returns ErrModelNotFound when the
	// provider/model pair doesn't exist or doesn't belong to
	// the calling user.
	ResolveModel(ctx context.Context, providerID, modelID string) (ResolvedModel, error)
}

// ResolvedModel is the unsealed view of a user_model the plugin
// can call directly. ProviderType is the same string that drives
// per-driver dispatch elsewhere ("openai-compatible", "google",
// "anthropic"); the plugin uses it to pick the right API shape.
// APIKey may be empty for providers that don't need one (e.g.
// "local"); plugins that REQUIRE a key check for emptiness and
// surface a configuration error themselves.
//
// Pricing fields mirror `modelmeta.Pricing` and are populated
// from the user_model snapshot. Plugins that compute per-call
// costs (e.g. `imagegen` reading a `usage` block from the
// upstream response) multiply tokens × per-million pricing to
// produce the `ToolResult.CostUSD` field. All four are 0 when
// the catalog had no pricing for the model — plugins should
// treat 0 as "unknown" and skip cost reporting rather than
// reporting $0.
type ResolvedModel struct {
	ProviderType string
	ProviderID   string
	ModelID      string
	APIKey       string
	BaseURL      string
	Pricing      ResolvedPricing
}

// ResolvedPricing carries per-million-token rates from the user_model
// snapshot, in USD. Mirror of `modelmeta.Pricing`.
type ResolvedPricing struct {
	InputPerMillion      float64
	OutputPerMillion     float64
	CacheReadPerMillion  float64
	CacheWritePerMillion float64
}

type providerResolverKey struct{}

// WithProviderResolver attaches a resolver to the context. The
// conversations service does this at the dispatch site (right
// before invoking the owning plugin's ExecuteTool) so the
// plugin can read its own model/provider lookup without taking
// a service dependency.
func WithProviderResolver(ctx context.Context, r ProviderResolver) context.Context {
	if r == nil {
		return ctx
	}
	return context.WithValue(ctx, providerResolverKey{}, r)
}

// ProviderResolverFrom returns the resolver attached to ctx, or
// nil if none was attached. Plugins should treat a nil return as
// "no resolver wired" and either fall back to self-configured
// credentials or surface a clear configuration error.
func ProviderResolverFrom(ctx context.Context) ProviderResolver {
	v, _ := ctx.Value(providerResolverKey{}).(ProviderResolver)
	return v
}
