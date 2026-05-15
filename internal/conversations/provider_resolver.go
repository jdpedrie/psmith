package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/plugins"
)

// userScopedResolver implements plugins.ProviderResolver for the
// duration of a single SendMessage. It scopes resolution to one
// user (the conversation owner) so a misconfigured plugin can't
// reach across user boundaries by passing somebody else's
// provider id.
//
// Constructed inline in service.SendMessage and attached to the
// tool dispatch context — plugins read it via
// plugins.ProviderResolverFrom(ctx).
type userScopedResolver struct {
	svc    *Service
	userID uuid.UUID
}

func (r *userScopedResolver) ResolveModel(ctx context.Context, providerIDStr, modelID string) (plugins.ResolvedModel, error) {
	providerID, err := uuid.Parse(providerIDStr)
	if err != nil {
		return plugins.ResolvedModel{}, fmt.Errorf("provider_resolver: invalid provider_id: %w", err)
	}
	provRow, err := r.svc.queries.GetUserModelProvider(ctx, providerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return plugins.ResolvedModel{}, fmt.Errorf("provider_resolver: provider %s not found", providerID)
		}
		return plugins.ResolvedModel{}, fmt.Errorf("provider_resolver: load provider: %w", err)
	}
	if provRow.UserID != r.userID {
		// Treat foreign-owned providers as not-found rather than
		// returning a permission-error — the plugin can't tell
		// the difference and we'd rather not leak existence.
		return plugins.ResolvedModel{}, fmt.Errorf("provider_resolver: provider %s not found", providerID)
	}

	cfgBytes, err := r.svc.resolveProviderConfig(provRow)
	if err != nil {
		return plugins.ResolvedModel{}, err
	}
	apiKey, baseURL := extractCredentials(cfgBytes)

	// Load the user_model to surface per-million pricing for
	// cost-aware plugins (imagegen multiplies usage × pricing
	// to populate ToolResult.CostUSD). Best-effort: if the row
	// is missing or pricing is null we hand back zeros and the
	// plugin treats that as "unknown".
	var pricing plugins.ResolvedPricing
	if modelRow, err := r.svc.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: providerID,
		ModelID:             modelID,
	}); err == nil {
		if modelRow.InputPricePerMillion != nil {
			pricing.InputPerMillion = *modelRow.InputPricePerMillion
		}
		if modelRow.OutputPricePerMillion != nil {
			pricing.OutputPerMillion = *modelRow.OutputPricePerMillion
		}
		if modelRow.CacheReadPerMillion != nil {
			pricing.CacheReadPerMillion = *modelRow.CacheReadPerMillion
		}
		if modelRow.CacheWritePerMillion != nil {
			pricing.CacheWritePerMillion = *modelRow.CacheWritePerMillion
		}
	}

	return plugins.ResolvedModel{
		ProviderType: provRow.Type,
		ProviderID:   providerIDStr,
		ModelID:      modelID,
		APIKey:       apiKey,
		BaseURL:      baseURL,
		Pricing:      pricing,
	}, nil
}

// extractCredentials picks the api_key and (optional) base_url
// from the decrypted provider config blob. The blob is the
// per-driver `Config` shape; we only care about the two fields
// every driver shares, so a flat anonymous decode is enough.
func extractCredentials(cfg []byte) (apiKey, baseURL string) {
	if len(cfg) == 0 {
		return "", ""
	}
	var probe struct {
		APIKey  string `json:"api_key"`
		BaseURL string `json:"base_url"`
	}
	_ = json.Unmarshal(cfg, &probe)
	return probe.APIKey, probe.BaseURL
}

// ensureUserScopedResolverNotShared is a compile-time guard
// nudging future readers: the resolver MUST be constructed per
// SendMessage so the userID gate is correct. If someone tries to
// stash one on the Service struct, this comment + the
// userID-binding parameter on construction should make them
// reconsider.
var _ plugins.ProviderResolver = (*userScopedResolver)(nil)

// newProviderResolver builds a per-send resolver bound to the
// conversation owner.
func (s *Service) newProviderResolver(userID uuid.UUID) plugins.ProviderResolver {
	return &userScopedResolver{svc: s, userID: userID}
}

// _ keeps the store import live even when no other file in the
// package uses it from this binding (it does — but linters get
// unhappy across reorgs).
var _ store.UserModelProvider