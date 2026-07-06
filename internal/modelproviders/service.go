// Package modelproviders implements the ModelProvidersService Connect handler.
// It owns CRUD for user_model_providers and user_models, model discovery via
// the providers registry, and surfaces the modelmeta catalog.
package modelproviders

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/gen/psmith/v1/psmithv1connect"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/profiles"
	"github.com/jdpedrie/psmith/internal/providers"
	openaidriver "github.com/jdpedrie/psmith/internal/providers/openai"
	"github.com/jdpedrie/psmith/internal/store"
)

// Service implements psmithv1connect.ModelProvidersServiceHandler.
type Service struct {
	psmithv1connect.UnimplementedModelProvidersServiceHandler
	queries *store.Queries
	catalog modelmeta.Catalog
	cipher  crypto.Cipher
	logger  *slog.Logger
}

// NewService constructs a Service. logger may be nil — slog.Default() is used
// in that case. cipher must be non-nil; pass crypto.Nop{} to opt out of
// encryption (tests, deployments without PSMITH_MASTER_KEY).
func NewService(queries *store.Queries, catalog modelmeta.Catalog, cipher crypto.Cipher, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	if cipher == nil {
		cipher = crypto.Nop{}
	}
	return &Service{queries: queries, catalog: catalog, cipher: cipher, logger: logger}
}

// resolveProviderConfig returns the plaintext config bytes for a row,
// preferring the encrypted column (decrypted through s.cipher) and
// falling back to the plaintext column for rows that haven't been
// touched since the encryption rollout. Returns []byte("{}") when
// both columns are unset so callers can unmarshal unconditionally.
func (s *Service) resolveProviderConfig(row store.UserModelProvider) ([]byte, error) {
	b, err := crypto.ResolveSecret(s.cipher, row.ConfigEncrypted, row.Config)
	if err != nil {
		return nil, fmt.Errorf("decrypt provider config: %w", err)
	}
	if len(b) == 0 {
		return []byte("{}"), nil
	}
	return b, nil
}

// mergeJSONConfig applies a shallow patch (matching the old SQL-side
// `config = config || $2` semantics) and returns the merged blob.
// `loadCurrent` is a thunk so we don't decrypt-and-discard when the
// patch turns out to be a no-op. Top-level only — nested objects are
// replaced wholesale, matching Postgres jsonb || behaviour.
func mergeJSONConfig(patch []byte, loadCurrent func() ([]byte, error)) ([]byte, error) {
	currentBytes, err := loadCurrent()
	if err != nil {
		return nil, err
	}
	current := map[string]json.RawMessage{}
	if len(currentBytes) > 0 {
		if err := json.Unmarshal(currentBytes, &current); err != nil {
			// Existing config isn't a JSON object — treat as empty so
			// the patch wins. The encrypted-rollover migration won't
			// produce this shape; this branch is just defensive.
			current = map[string]json.RawMessage{}
		}
	}
	var incoming map[string]json.RawMessage
	if err := json.Unmarshal(patch, &incoming); err != nil {
		return nil, fmt.Errorf("patch is not a JSON object: %w", err)
	}
	for k, v := range incoming {
		current[k] = v
	}
	return json.Marshal(current)
}

// --- Driver types & templates ---

func (s *Service) ListProviderTypes(ctx context.Context, _ *connect.Request[psmithv1.ListProviderTypesRequest]) (*connect.Response[psmithv1.ListProviderTypesResponse], error) {
	names := providers.Types()
	sort.Strings(names)
	out := make([]*psmithv1.ProviderType, 0, len(names))
	for _, n := range names {
		out = append(out, &psmithv1.ProviderType{
			Name:         n,
			DisplayName:  humanizeName(n),
			Stateful:     knownStatefulTypes[n],
			ConfigSchema: nil,
		})
	}
	return connect.NewResponse(&psmithv1.ListProviderTypesResponse{Types: out}), nil
}

// ListProviderTemplates returns the "Add provider" picker entries:
//
//   - Native-driver presets: Anthropic, Google. driver_type names the
//     dedicated driver; preset_id is empty (the driver_type alone selects
//     behaviour).
//   - Openai-compatible presets: every entry from openai.AllPresets()
//     (OpenAI, xAI, DeepSeek, Groq, ..., Ollama, Perplexity). driver_type
//     is always "openai-compatible"; preset_id pins the Quirks overlay
//     the driver loads at runtime.
//
// Catalog metadata (env_key, doc_url) is best-effort — we look up the
// preset's catalog_provider_id in the in-memory catalog and fill those
// fields when present. Missing catalog entries don't cause the template
// to be omitted; the UI falls back to its bundled defaults.
func (s *Service) ListProviderTemplates(ctx context.Context, _ *connect.Request[psmithv1.ListProviderTemplatesRequest]) (*connect.Response[psmithv1.ListProviderTemplatesResponse], error) {
	out := make([]*psmithv1.ProviderTemplate, 0, len(openaidriver.AllPresets())+2)

	// Native-driver entries first — they appear at the top of the picker.
	out = append(out,
		&psmithv1.ProviderTemplate{
			CatalogProviderId: "anthropic",
			Name:              "Anthropic",
			DriverType:        "anthropic",
			ApiBase:           strPtr("https://api.anthropic.com"),
			LogoSlug:          strPtr("anthropic"),
		},
		&psmithv1.ProviderTemplate{
			CatalogProviderId: "google",
			Name:              "Google Gemini",
			DriverType:        "google",
			ApiBase:           strPtr("https://generativelanguage.googleapis.com/v1beta"),
			LogoSlug:          strPtr("google-color"),
		},
	)

	for _, p := range openaidriver.AllPresets() {
		t := &psmithv1.ProviderTemplate{
			// catalog_provider_id is the preset id for openai-compat
			// entries — same string the driver enricher uses for catalog
			// lookups. It happens to match the models.dev provider slug
			// for OpenAI/xAI/DeepSeek/etc., which is why catalog
			// enrichment Just Works.
			CatalogProviderId: string(p.ID),
			Name:              p.DisplayName,
			DriverType:        "openai-compatible",
			ApiBase:           strPtr(p.BaseURL),
			PresetId:          strPtr(string(p.ID)),
			LogoSlug:          strPtr(p.LogoSlug),
		}
		// Catalog enrichment: env var hint + docs URL when models.dev has
		// the provider on file. Live catalog lookup, lazy-fetched.
		if cat, err := s.catalog.LookupProvider(ctx, string(p.ID)); err == nil && cat != nil {
			if cat.EnvKey != "" {
				t.EnvKey = strPtr(cat.EnvKey)
			}
			if cat.DocURL != "" {
				t.DocUrl = strPtr(cat.DocURL)
			}
		}
		out = append(out, t)
	}

	return connect.NewResponse(&psmithv1.ListProviderTemplatesResponse{Templates: out}), nil
}

// --- UserModelProvider CRUD ---

func (s *Service) CreateUserModelProvider(ctx context.Context, req *connect.Request[psmithv1.CreateUserModelProviderRequest]) (*connect.Response[psmithv1.CreateUserModelProviderResponse], error) {
	u := auth.MustFromContext(ctx)
	if req.Msg.Type == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("type is required"))
	}
	// Validate the type up front so we don't accept dead rows that only fail
	// later on `discoverModels` / `sendMessage`. Cleanup of an invalid row
	// otherwise requires the user to delete it manually.
	if !providers.IsRegistered(req.Msg.Type) {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("unknown provider type %q (registered: %v)", req.Msg.Type, providers.Types()))
	}
	if req.Msg.Label == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("label is required"))
	}
	cfg := req.Msg.Config
	if len(cfg) == 0 {
		cfg = []byte("{}")
	} else if !json.Valid(cfg) {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("config must be valid JSON"))
	}
	encryptedCfg, err := s.cipher.Encrypt(cfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encrypt provider config: %w", err))
	}
	id, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	row, err := s.queries.CreateUserModelProvider(ctx, store.CreateUserModelProviderParams{
		ID:              id,
		UserID:          u.ID,
		Type:            req.Msg.Type,
		Label:           req.Msg.Label,
		ConfigEncrypted: encryptedCfg,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.CreateUserModelProviderResponse{Provider: s.storeProviderToProto(row)}), nil
}

func (s *Service) ListUserModelProviders(ctx context.Context, _ *connect.Request[psmithv1.ListUserModelProvidersRequest]) (*connect.Response[psmithv1.ListUserModelProvidersResponse], error) {
	u := auth.MustFromContext(ctx)
	rows, err := s.queries.ListUserModelProvidersByUser(ctx, u.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*psmithv1.UserModelProvider, 0, len(rows))
	for _, r := range rows {
		out = append(out, s.storeProviderToProto(r))
	}
	return connect.NewResponse(&psmithv1.ListUserModelProvidersResponse{Providers: out}), nil
}

func (s *Service) GetUserModelProvider(ctx context.Context, req *connect.Request[psmithv1.GetUserModelProviderRequest]) (*connect.Response[psmithv1.GetUserModelProviderResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.Id)
	if err != nil {
		return nil, err
	}
	models, err := s.queries.ListUserModelsByProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	enabled := make([]*psmithv1.UserModel, 0, len(models))
	for _, m := range models {
		enabled = append(enabled, storeUserModelToProto(m, row.Type))
	}
	return connect.NewResponse(&psmithv1.GetUserModelProviderResponse{
		Provider:      s.storeProviderToProto(row),
		EnabledModels: enabled,
	}), nil
}

func (s *Service) UpdateUserModelProvider(ctx context.Context, req *connect.Request[psmithv1.UpdateUserModelProviderRequest]) (*connect.Response[psmithv1.UpdateUserModelProviderResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.Id)
	if err != nil {
		return nil, err
	}
	if req.Msg.Label != nil {
		if *req.Msg.Label == "" {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("label cannot be empty"))
		}
		if err := s.queries.UpdateUserModelProviderLabel(ctx, store.UpdateUserModelProviderLabelParams{
			ID:    row.ID,
			Label: *req.Msg.Label,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	if req.Msg.Config != nil {
		if !json.Valid(req.Msg.Config) {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("config must be valid JSON"))
		}
		// Shallow-merge semantics preserved: load existing, parse both
		// blobs as a flat object, copy patch keys over, re-encrypt the
		// result. The old SQL-side `config = config || $2` did this in
		// the database; with encrypted storage the merge has to happen
		// client-side because we can't || sealed bytes.
		merged, err := mergeJSONConfig(req.Msg.Config, func() ([]byte, error) {
			return s.resolveProviderConfig(row)
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		encrypted, err := s.cipher.Encrypt(merged)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encrypt provider config: %w", err))
		}
		if err := s.queries.UpdateUserModelProviderEncryptedConfig(ctx, store.UpdateUserModelProviderEncryptedConfigParams{
			ID:              row.ID,
			ConfigEncrypted: encrypted,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	if req.Msg.DefaultSettings != nil {
		// Replace semantics: marshal whatever the caller sent (including an
		// empty CallSettings, which marshals to `{}` and clears any prior
		// content). Unset on the request leaves the column untouched.
		raw, err := profiles.MarshalCallSettings(req.Msg.DefaultSettings)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("marshal default_settings: %w", err))
		}
		if err := s.queries.UpdateUserModelProviderDefaultSettings(ctx, store.UpdateUserModelProviderDefaultSettingsParams{
			ID:              row.ID,
			DefaultSettings: raw,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	updated, err := s.queries.GetUserModelProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.UpdateUserModelProviderResponse{Provider: s.storeProviderToProto(updated)}), nil
}

func (s *Service) DeleteUserModelProvider(ctx context.Context, req *connect.Request[psmithv1.DeleteUserModelProviderRequest]) (*connect.Response[psmithv1.DeleteUserModelProviderResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.Id)
	if err != nil {
		return nil, err
	}
	if err := s.queries.DeleteUserModelProvider(ctx, row.ID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.DeleteUserModelProviderResponse{}), nil
}

// --- Discovery & enablement ---

func (s *Service) DiscoverModels(ctx context.Context, req *connect.Request[psmithv1.DiscoverModelsRequest]) (*connect.Response[psmithv1.DiscoverModelsResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}

	enabled, err := s.queries.ListUserModelsByProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	enabledSet := make(map[string]bool, len(enabled))
	for _, m := range enabled {
		enabledSet[m.ModelID] = true
	}

	cfg, err := s.resolveProviderConfig(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Prefer the catalog as the source of truth for model discovery whenever
	// the provider has a `catalog_provider_id` (every Anthropic provider does
	// implicitly; openai-compatible providers carry it in their config).
	// Catalog data is curated and metadata-rich; the live provider API
	// (e.g. OpenRouter's /v1/models) leaks alias pointers and unversioned
	// entries that have no pricing/context-window data, which is what users
	// run into. Fall back to live discovery only for providers with no
	// catalog hint at all (LM Studio, Ollama, custom endpoints).
	catalogProviderID := configCatalogProviderID(row.Type, cfg)
	if catalogProviderID != "" {
		cms, lookupErr := s.catalog.ListModelsByProvider(ctx, catalogProviderID)
		if lookupErr != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("catalog list: %w", lookupErr))
		}
		out := make([]*psmithv1.DiscoveredModel, 0, len(cms))
		for i := range cms {
			out = append(out, catalogModelToDiscovered(&cms[i], enabledSet[cms[i].ID]))
		}
		return connect.NewResponse(&psmithv1.DiscoverModelsResponse{Models: out}), nil
	}

	driver, err := providers.Build(row.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, cfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build driver: %w", err))
	}
	models, err := driver.DiscoverModels(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("discover models: %w", err))
	}
	out := make([]*psmithv1.DiscoveredModel, 0, len(models))
	for _, m := range models {
		out = append(out, providerModelToDiscovered(m, enabledSet[m.ID]))
	}
	return connect.NewResponse(&psmithv1.DiscoverModelsResponse{Models: out}), nil
}

func (s *Service) EnableModels(ctx context.Context, req *connect.Request[psmithv1.EnableModelsRequest]) (*connect.Response[psmithv1.EnableModelsResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	if len(req.Msg.ModelIds) == 0 {
		return connect.NewResponse(&psmithv1.EnableModelsResponse{}), nil
	}

	cfg, err := s.resolveProviderConfig(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	catalogProviderID := configCatalogProviderID(row.Type, cfg)

	// Driver discovery is lazy — only build/call once if any model misses the catalog.
	var (
		driverModels    []providers.Model
		driverPopulated bool
	)
	loadDriverModels := func() ([]providers.Model, error) {
		if driverPopulated {
			return driverModels, nil
		}
		driver, dErr := providers.Build(row.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, cfg)
		if dErr != nil {
			return nil, dErr
		}
		ms, dErr := driver.DiscoverModels(ctx)
		if dErr != nil {
			return nil, dErr
		}
		driverModels = ms
		driverPopulated = true
		return driverModels, nil
	}

	enabled := make([]*psmithv1.UserModel, 0, len(req.Msg.ModelIds))
	now := time.Now().UTC()

	for _, modelID := range req.Msg.ModelIds {
		if modelID == "" {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id cannot be empty"))
		}

		var (
			snap  store.UpsertUserModelParams
			found bool
		)

		if catalogProviderID != "" {
			cm, lookupErr := s.catalog.LookupModel(ctx, catalogProviderID, modelID)
			if lookupErr == nil {
				snap = catalogModelToSnapshot(row.ID, cm, now)
				found = true
			} else if !errors.Is(lookupErr, modelmeta.ErrNotFound) {
				return nil, connect.NewError(connect.CodeInternal, lookupErr)
			}
		}

		if !found {
			ms, dErr := loadDriverModels()
			if dErr != nil {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("driver discover: %w", dErr))
			}
			for _, m := range ms {
				if m.ID == modelID {
					snap, err = providerModelToSnapshot(row.ID, m, now)
					if err != nil {
						return nil, connect.NewError(connect.CodeInternal, err)
					}
					found = true
					break
				}
			}
		}

		if !found {
			return nil, connect.NewError(connect.CodeInvalidArgument,
				fmt.Errorf("model %q is not discoverable on this provider; use AddManualModel instead (TODO: not yet implemented)", modelID))
		}

		written, err := s.queries.UpsertUserModel(ctx, snap)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		enabled = append(enabled, storeUserModelToProto(written, row.Type))
	}

	return connect.NewResponse(&psmithv1.EnableModelsResponse{Enabled: enabled}), nil
}

func (s *Service) DisableModels(ctx context.Context, req *connect.Request[psmithv1.DisableModelsRequest]) (*connect.Response[psmithv1.DisableModelsResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	for _, modelID := range req.Msg.ModelIds {
		if modelID == "" {
			continue
		}
		if err := s.queries.DeleteUserModel(ctx, store.DeleteUserModelParams{
			UserModelProviderID: row.ID,
			ModelID:             modelID,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	return connect.NewResponse(&psmithv1.DisableModelsResponse{}), nil
}

func (s *Service) ListUserModels(ctx context.Context, req *connect.Request[psmithv1.ListUserModelsRequest]) (*connect.Response[psmithv1.ListUserModelsResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	models, err := s.queries.ListUserModelsByProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*psmithv1.UserModel, 0, len(models))
	for _, m := range models {
		out = append(out, storeUserModelToProto(m, row.Type))
	}
	return connect.NewResponse(&psmithv1.ListUserModelsResponse{Models: out}), nil
}

func (s *Service) ListAllUserModels(ctx context.Context, _ *connect.Request[psmithv1.ListAllUserModelsRequest]) (*connect.Response[psmithv1.ListAllUserModelsResponse], error) {
	u := auth.MustFromContext(ctx)
	provs, err := s.queries.ListUserModelProvidersByUser(ctx, u.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	provByID := make(map[uuid.UUID]store.UserModelProvider, len(provs))
	for _, p := range provs {
		provByID[p.ID] = p
	}
	models, err := s.queries.ListUserModelsByUser(ctx, u.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	entries := make([]*psmithv1.UserModelEntry, 0, len(models))
	for _, m := range models {
		p, ok := provByID[m.UserModelProviderID]
		if !ok {
			// Defensive: row from JOIN should always match. Skip if not.
			continue
		}
		entries = append(entries, &psmithv1.UserModelEntry{
			Provider: s.storeProviderToProto(p),
			Model:    storeUserModelToProto(m, p.Type),
		})
	}
	return connect.NewResponse(&psmithv1.ListAllUserModelsResponse{Entries: entries}), nil
}

// --- Favorite toggle ---

// ToggleUserModelFavorite sets the `favorite` flag on a single user model.
// Verifies the caller owns the parent provider; the model row must already
// exist (callers can't favorite a model they haven't enabled).
func (s *Service) ToggleUserModelFavorite(ctx context.Context, req *connect.Request[psmithv1.ToggleUserModelFavoriteRequest]) (*connect.Response[psmithv1.ToggleUserModelFavoriteResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	if req.Msg.ModelId == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id is required"))
	}
	// Make sure the model exists on this provider before toggling — we want
	// NotFound rather than a silent no-op if the row doesn't exist.
	existing, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: row.ID,
		ModelID:             req.Msg.ModelId,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("model not enabled on this provider"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if existing.Favorite != req.Msg.Favorite {
		if err := s.queries.SetUserModelFavorite(ctx, store.SetUserModelFavoriteParams{
			UserModelProviderID: row.ID,
			ModelID:             req.Msg.ModelId,
			Favorite:            req.Msg.Favorite,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	updated, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: row.ID,
		ModelID:             req.Msg.ModelId,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.ToggleUserModelFavoriteResponse{
		Model: storeUserModelToProto(updated, row.Type),
	}), nil
}

// --- UpdateUserModel ---

// UpdateUserModel mutates fields on an enabled user model row. Every
// metadata field is independently optional — present overwrites, absent
// leaves the column untouched. The wire `model_id` is the row key and is
// never updatable; ToggleUserModelFavorite owns the favorite flag.
//
// The model row must already exist on the named provider — callers can't
// create one here. Verification is symmetrical to ToggleUserModelFavorite:
// own the parent provider, model row exists.
//
// Implementation note: rather than maintain a sparse SQL UPDATE with a
// COALESCE column per field, we read the existing row, apply the requested
// changes in-memory, then re-call UpsertUserModel with the full set. The
// merge is one place, easy to read, and stays in sync as the row grows
// new columns.
func (s *Service) UpdateUserModel(ctx context.Context, req *connect.Request[psmithv1.UpdateUserModelRequest]) (*connect.Response[psmithv1.UpdateUserModelResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	if req.Msg.ModelId == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id is required"))
	}
	existing, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: row.ID,
		ModelID:             req.Msg.ModelId,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("model not enabled on this provider"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	params := store.UpsertUserModelParams{
		UserModelProviderID:   row.ID,
		ModelID:               existing.ModelID,
		DisplayName:           existing.DisplayName,
		ContextWindow:         existing.ContextWindow,
		MaxOutputTokens:       existing.MaxOutputTokens,
		InputPricePerMillion:  existing.InputPricePerMillion,
		OutputPricePerMillion: existing.OutputPricePerMillion,
		CacheReadPerMillion:   existing.CacheReadPerMillion,
		CacheWritePerMillion:  existing.CacheWritePerMillion,
		KnowledgeCutoff:       existing.KnowledgeCutoff,
		Modalities:            existing.Modalities,
		Capabilities:          existing.Capabilities,
		DefaultSettings:       existing.DefaultSettings,
		MetadataSource:        existing.MetadataSource,
		MetadataSnapshotAt:    time.Now().UTC(),
	}
	if req.Msg.DisplayName != nil {
		dn := strings.TrimSpace(req.Msg.GetDisplayName())
		if dn == "" {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("display_name cannot be empty"))
		}
		params.DisplayName = dn
	}
	// Clear flags win over set values — UI sends clear=true with the value
	// field unset to revert the column to NULL.
	if req.Msg.ClearContextWindow {
		params.ContextWindow = nil
	} else if req.Msg.ContextWindow != nil {
		v := req.Msg.GetContextWindow()
		params.ContextWindow = &v
	}
	if req.Msg.ClearMaxOutputTokens {
		params.MaxOutputTokens = nil
	} else if req.Msg.MaxOutputTokens != nil {
		v := req.Msg.GetMaxOutputTokens()
		params.MaxOutputTokens = &v
	}
	if p := req.Msg.Pricing; p != nil {
		// Pricing is replace-block: any subfield not set on the incoming
		// ModelPricing means "clear that subfield" (matches AddManualModel
		// semantics where a Pricing object always carries its full intent).
		params.InputPricePerMillion = p.InputPerMillionTokens
		params.OutputPricePerMillion = p.OutputPerMillionTokens
		params.CacheReadPerMillion = p.CacheReadPerMillionTokens
		params.CacheWritePerMillion = p.CacheWritePerMillionTokens
	}
	if c := req.Msg.Capabilities; c != nil {
		capJSON, err := json.Marshal(modelmeta.Capabilities{
			Streaming:       c.Streaming,
			Thinking:        c.Thinking,
			ToolUse:         c.ToolUse,
			Vision:          c.Vision,
			PromptCaching:   c.PromptCaching,
			GeneratesImages: c.GeneratesImages,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("marshal capabilities: %w", err))
		}
		params.Capabilities = capJSON
	}
	if req.Msg.UpdateModalities {
		// Always-replace semantics — empty array means "no modalities".
		params.Modalities = req.Msg.Modalities
	}
	if req.Msg.ClearKnowledgeCutoff {
		params.KnowledgeCutoff = pgtype.Date{}
	} else if req.Msg.KnowledgeCutoff != nil {
		params.KnowledgeCutoff = dateFromString(req.Msg.GetKnowledgeCutoff())
	}
	if req.Msg.DefaultSettings != nil {
		raw, err := profiles.MarshalCallSettings(req.Msg.DefaultSettings)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("marshal default_settings: %w", err))
		}
		params.DefaultSettings = raw
	}

	written, err := s.queries.UpsertUserModel(ctx, params)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.UpdateUserModelResponse{
		UserModel: storeUserModelToProto(written, row.Type),
	}), nil
}

// --- AddManualModel ---

// AddManualModel registers a user-described model on a provider for which
// driver discovery / catalog lookup didn't surface it. Stores every metadata
// field verbatim with `metadata_source = manual`. Errors:
//   - InvalidArgument when model_id or display_name is empty.
//   - NotFound when the provider doesn't belong to the caller (or doesn't exist).
//   - AlreadyExists when (provider_id, model_id) is already enabled. The user
//     should call UpdateUserModel (when implemented for snapshot fields) or
//     DisableModels first.
func (s *Service) AddManualModel(ctx context.Context, req *connect.Request[psmithv1.AddManualModelRequest]) (*connect.Response[psmithv1.AddManualModelResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	if req.Msg.ModelId == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id is required"))
	}
	if req.Msg.DisplayName == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("display_name is required"))
	}

	// Reject duplicates explicitly — UpsertUserModel would overwrite the
	// existing snapshot, which is surprising for an "Add" RPC.
	if _, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: row.ID,
		ModelID:             req.Msg.ModelId,
	}); err == nil {
		return nil, connect.NewError(connect.CodeAlreadyExists, errors.New("model already enabled on this provider"))
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	now := time.Now().UTC()
	params := store.UpsertUserModelParams{
		UserModelProviderID: row.ID,
		ModelID:             req.Msg.ModelId,
		DisplayName:         req.Msg.DisplayName,
		ContextWindow:       req.Msg.ContextWindow,
		MaxOutputTokens:     req.Msg.MaxOutputTokens,
		KnowledgeCutoff:     dateFromString(req.Msg.GetKnowledgeCutoff()),
		Modalities:          req.Msg.Modalities,
		MetadataSource:      string(modelmeta.SourceManual),
		MetadataSnapshotAt:  now,
	}
	if p := req.Msg.Pricing; p != nil {
		params.InputPricePerMillion = p.InputPerMillionTokens
		params.OutputPricePerMillion = p.OutputPerMillionTokens
		params.CacheReadPerMillion = p.CacheReadPerMillionTokens
		params.CacheWritePerMillion = p.CacheWritePerMillionTokens
	}
	if c := req.Msg.Capabilities; c != nil {
		capJSON, err := json.Marshal(modelmeta.Capabilities{
			Streaming:       c.Streaming,
			Thinking:        c.Thinking,
			ToolUse:         c.ToolUse,
			Vision:          c.Vision,
			PromptCaching:   c.PromptCaching,
			GeneratesImages: c.GeneratesImages,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("marshal capabilities: %w", err))
		}
		params.Capabilities = capJSON
	}
	if ds := req.Msg.DefaultSettings; ds != nil {
		raw, err := profiles.MarshalCallSettings(ds)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("marshal default_settings: %w", err))
		}
		params.DefaultSettings = raw
	}

	written, err := s.queries.UpsertUserModel(ctx, params)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.AddManualModelResponse{
		UserModel: storeUserModelToProto(written, row.Type),
	}), nil
}

// --- Catalog ---

func (s *Service) RefreshModelCatalog(ctx context.Context, _ *connect.Request[psmithv1.RefreshModelCatalogRequest]) (*connect.Response[psmithv1.RefreshModelCatalogResponse], error) {
	u := auth.MustFromContext(ctx)
	if !u.IsAdmin {
		return nil, connect.NewError(connect.CodePermissionDenied, errors.New("admin required"))
	}
	if err := s.catalog.Refresh(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	status, err := s.catalog.Status(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	resp := &psmithv1.RefreshModelCatalogResponse{
		ProvidersCount: int32(status.ProvidersCount),
		ModelsCount:    int32(status.ModelsCount),
	}
	if status.LastRefreshAt != nil {
		resp.FetchedAt = timestamppb.New(*status.LastRefreshAt)
	}
	return connect.NewResponse(resp), nil
}

func (s *Service) GetCatalogStatus(ctx context.Context, _ *connect.Request[psmithv1.GetCatalogStatusRequest]) (*connect.Response[psmithv1.GetCatalogStatusResponse], error) {
	// Auth-protected by the interceptor; no admin requirement.
	_ = auth.MustFromContext(ctx)
	status, err := s.catalog.Status(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	resp := &psmithv1.GetCatalogStatusResponse{
		ProvidersCount: int32(status.ProvidersCount),
		ModelsCount:    int32(status.ModelsCount),
	}
	if status.LastRefreshAt != nil {
		resp.LastRefreshAt = timestamppb.New(*status.LastRefreshAt)
	}
	return connect.NewResponse(resp), nil
}

// ListProviderCosts returns one row per configured provider with the running
// cost total inside the optional [since, until) window. Providers with no
// events in the window still appear with 0.0 / 0 — the settings screen renders
// enabled providers consistently rather than hiding the ones the user hasn't
// sent through yet.
func (s *Service) ListProviderCosts(ctx context.Context, req *connect.Request[psmithv1.ListProviderCostsRequest]) (*connect.Response[psmithv1.ListProviderCostsResponse], error) {
	u := auth.MustFromContext(ctx)
	var since, until *time.Time
	if req.Msg.Since != nil {
		t := req.Msg.Since.AsTime()
		since = &t
	}
	if req.Msg.Until != nil {
		t := req.Msg.Until.AsTime()
		until = &t
	}
	rows, err := s.queries.ListProviderCostTotals(ctx, store.ListProviderCostTotalsParams{
		UserID: u.ID,
		Since:  since,
		Until:  until,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*psmithv1.ProviderCost, 0, len(rows))
	var grand float64
	for _, r := range rows {
		total := costNumericToFloat(r.TotalCostUsd)
		grand += total
		out = append(out, &psmithv1.ProviderCost{
			ProviderId:    r.ProviderID.String(),
			ProviderLabel: r.ProviderLabel,
			ProviderType:  r.ProviderType,
			TotalCostUsd:  total,
			EventCount:    r.EventCount,
		})
	}
	return connect.NewResponse(&psmithv1.ListProviderCostsResponse{
		Providers:     out,
		GrandTotalUsd: grand,
	}), nil
}

// costNumericToFloat converts a pgtype.Numeric ($USD) to float64, returning
// 0 when the value is null/invalid. We don't surface NaN/Inf because every
// path that writes amount_usd validates it first.
func costNumericToFloat(n pgtype.Numeric) float64 {
	if !n.Valid {
		return 0
	}
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		return 0
	}
	return f.Float64
}

// --- helpers ---

// loadOwnedProvider parses the id, looks up the provider, and verifies the
// caller owns it. Common preamble for every per-provider RPC.
func (s *Service) loadOwnedProvider(ctx context.Context, idStr string) (store.UserModelProvider, error) {
	u := auth.MustFromContext(ctx)
	id, err := uuid.Parse(idStr)
	if err != nil {
		return store.UserModelProvider{}, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}
	row, err := s.queries.GetUserModelProvider(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return store.UserModelProvider{}, connect.NewError(connect.CodeNotFound, errors.New("provider not found"))
		}
		return store.UserModelProvider{}, connect.NewError(connect.CodeInternal, err)
	}
	if row.UserID != u.ID {
		// Don't leak existence — return NotFound.
		return store.UserModelProvider{}, connect.NewError(connect.CodeNotFound, errors.New("provider not found"))
	}
	return row, nil
}

// configCatalogProviderID extracts the catalog provider id used to look up
// model metadata at enable time. For the anthropic driver it's hardcoded; for
// openai-compatible it's read from the config blob's optional
// "catalog_provider_id" field. Returns "" when no catalog hint is available.
func configCatalogProviderID(driverType string, config []byte) string {
	switch driverType {
	case "anthropic":
		return "anthropic"
	case "google":
		return "google"
	case "openai-compatible":
		var c struct {
			CatalogProviderID string `json:"catalog_provider_id"`
		}
		if len(config) == 0 {
			return ""
		}
		if err := json.Unmarshal(config, &c); err != nil {
			return ""
		}
		return c.CatalogProviderID
	default:
		return ""
	}
}

// catalogModelToSnapshot converts a catalog Model into Upsert params.
func catalogModelToSnapshot(providerID uuid.UUID, m *modelmeta.Model, now time.Time) store.UpsertUserModelParams {
	out := store.UpsertUserModelParams{
		UserModelProviderID: providerID,
		ModelID:             m.ID,
		DisplayName:         m.DisplayName,
		ContextWindow:       intPtrOrNil(m.ContextWindow),
		MaxOutputTokens:     intPtrOrNil(m.MaxOutputTokens),
		KnowledgeCutoff:     dateOrNullPtr(m.KnowledgeCutoff),
		Modalities:          m.Modalities,
		MetadataSource:      string(modelmeta.SourceCatalog),
		MetadataSnapshotAt:  now,
	}
	if m.Pricing != nil {
		out.InputPricePerMillion = floatPtrOrNil(m.Pricing.InputPerMillion)
		out.OutputPricePerMillion = floatPtrOrNil(m.Pricing.OutputPerMillion)
		out.CacheReadPerMillion = floatPtrOrNil(m.Pricing.CacheReadPerMillion)
		out.CacheWritePerMillion = floatPtrOrNil(m.Pricing.CacheWritePerMillion)
	}
	if capJSON, err := json.Marshal(m.Capabilities); err == nil {
		out.Capabilities = capJSON
	}
	return out
}

// providerModelToSnapshot converts a discovered provider Model into Upsert
// params. metadata_source falls back to "driver" when the model didn't carry a
// preferred source.
func providerModelToSnapshot(providerID uuid.UUID, m providers.Model, now time.Time) (store.UpsertUserModelParams, error) {
	source := m.MetadataSource
	if source == "" {
		source = modelmeta.SourceDriver
	}
	out := store.UpsertUserModelParams{
		UserModelProviderID: providerID,
		ModelID:             m.ID,
		DisplayName:         m.DisplayName,
		ContextWindow:       intPtrOrNil(m.ContextWindow),
		MaxOutputTokens:     intPtrOrNil(m.MaxOutputTokens),
		KnowledgeCutoff:     dateFromString(m.KnowledgeCutoff),
		Modalities:          m.Modalities,
		MetadataSource:      string(source),
		MetadataSnapshotAt:  now,
	}
	if m.Pricing != nil {
		out.InputPricePerMillion = floatPtrOrNil(m.Pricing.InputPerMillion)
		out.OutputPricePerMillion = floatPtrOrNil(m.Pricing.OutputPerMillion)
		out.CacheReadPerMillion = floatPtrOrNil(m.Pricing.CacheReadPerMillion)
		out.CacheWritePerMillion = floatPtrOrNil(m.Pricing.CacheWritePerMillion)
	}
	if capJSON, err := json.Marshal(modelmeta.Capabilities{
		Streaming:       m.Capabilities.Streaming,
		Thinking:        m.Capabilities.Thinking,
		ToolUse:         m.Capabilities.ToolUse,
		Vision:          m.Capabilities.Vision,
		PromptCaching:   m.Capabilities.PromptCaching,
		GeneratesImages: m.Capabilities.GeneratesImages,
	}); err == nil {
		out.Capabilities = capJSON
	}
	if defJSON, err := encodeCallSettings(m.DefaultSettings); err == nil && defJSON != nil {
		out.DefaultSettings = defJSON
	}
	return out, nil
}
