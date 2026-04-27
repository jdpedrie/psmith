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
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"google.golang.org/protobuf/types/known/timestamppb"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/gen/clark/v1/clarkv1connect"
	"github.com/jdpedrie/clark/internal/auth"
	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/providers"
	"github.com/jdpedrie/clark/internal/store"
)

// Service implements clarkv1connect.ModelProvidersServiceHandler.
type Service struct {
	clarkv1connect.UnimplementedModelProvidersServiceHandler
	queries *store.Queries
	catalog modelmeta.Catalog
	logger  *slog.Logger
}

// NewService constructs a Service. logger may be nil — slog.Default() is used
// in that case.
func NewService(queries *store.Queries, catalog modelmeta.Catalog, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{queries: queries, catalog: catalog, logger: logger}
}

// --- Driver types & templates ---

func (s *Service) ListProviderTypes(ctx context.Context, _ *connect.Request[clarkv1.ListProviderTypesRequest]) (*connect.Response[clarkv1.ListProviderTypesResponse], error) {
	names := providers.Types()
	sort.Strings(names)
	out := make([]*clarkv1.ProviderType, 0, len(names))
	for _, n := range names {
		out = append(out, &clarkv1.ProviderType{
			Name:         n,
			DisplayName:  humanizeName(n),
			Stateful:     knownStatefulTypes[n],
			ConfigSchema: nil,
		})
	}
	return connect.NewResponse(&clarkv1.ListProviderTypesResponse{Types: out}), nil
}

func (s *Service) ListProviderTemplates(ctx context.Context, _ *connect.Request[clarkv1.ListProviderTemplatesRequest]) (*connect.Response[clarkv1.ListProviderTemplatesResponse], error) {
	provs, err := s.catalog.ListProviders(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*clarkv1.ProviderTemplate, 0, len(provs))
	for _, p := range provs {
		var driverType string
		switch {
		case p.ID == "anthropic":
			driverType = "anthropic"
		case p.ID == "openai":
			driverType = "openai-compatible"
		case p.APIBase != "":
			driverType = "openai-compatible"
		default:
			continue
		}
		tmpl := &clarkv1.ProviderTemplate{
			CatalogProviderId: p.ID,
			Name:              p.Name,
			DriverType:        driverType,
			ApiBase:           strPtr(p.APIBase),
			EnvKey:            strPtr(p.EnvKey),
			DocUrl:            strPtr(p.DocURL),
		}
		out = append(out, tmpl)
	}
	return connect.NewResponse(&clarkv1.ListProviderTemplatesResponse{Templates: out}), nil
}

// --- UserModelProvider CRUD ---

func (s *Service) CreateUserModelProvider(ctx context.Context, req *connect.Request[clarkv1.CreateUserModelProviderRequest]) (*connect.Response[clarkv1.CreateUserModelProviderResponse], error) {
	u := auth.MustFromContext(ctx)
	if req.Msg.Type == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("type is required"))
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
	id, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	row, err := s.queries.CreateUserModelProvider(ctx, store.CreateUserModelProviderParams{
		ID:     id,
		UserID: u.ID,
		Type:   req.Msg.Type,
		Label:  req.Msg.Label,
		Config: cfg,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.CreateUserModelProviderResponse{Provider: storeProviderToProto(row)}), nil
}

func (s *Service) ListUserModelProviders(ctx context.Context, _ *connect.Request[clarkv1.ListUserModelProvidersRequest]) (*connect.Response[clarkv1.ListUserModelProvidersResponse], error) {
	u := auth.MustFromContext(ctx)
	rows, err := s.queries.ListUserModelProvidersByUser(ctx, u.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*clarkv1.UserModelProvider, 0, len(rows))
	for _, r := range rows {
		out = append(out, storeProviderToProto(r))
	}
	return connect.NewResponse(&clarkv1.ListUserModelProvidersResponse{Providers: out}), nil
}

func (s *Service) GetUserModelProvider(ctx context.Context, req *connect.Request[clarkv1.GetUserModelProviderRequest]) (*connect.Response[clarkv1.GetUserModelProviderResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.Id)
	if err != nil {
		return nil, err
	}
	models, err := s.queries.ListUserModelsByProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	enabled := make([]*clarkv1.UserModel, 0, len(models))
	for _, m := range models {
		enabled = append(enabled, storeUserModelToProto(m))
	}
	return connect.NewResponse(&clarkv1.GetUserModelProviderResponse{
		Provider:      storeProviderToProto(row),
		EnabledModels: enabled,
	}), nil
}

func (s *Service) UpdateUserModelProvider(ctx context.Context, req *connect.Request[clarkv1.UpdateUserModelProviderRequest]) (*connect.Response[clarkv1.UpdateUserModelProviderResponse], error) {
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
		if err := s.queries.UpdateUserModelProviderConfig(ctx, store.UpdateUserModelProviderConfigParams{
			ID:     row.ID,
			Config: req.Msg.Config,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	updated, err := s.queries.GetUserModelProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.UpdateUserModelProviderResponse{Provider: storeProviderToProto(updated)}), nil
}

func (s *Service) DeleteUserModelProvider(ctx context.Context, req *connect.Request[clarkv1.DeleteUserModelProviderRequest]) (*connect.Response[clarkv1.DeleteUserModelProviderResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.Id)
	if err != nil {
		return nil, err
	}
	if err := s.queries.DeleteUserModelProvider(ctx, row.ID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.DeleteUserModelProviderResponse{}), nil
}

// --- Discovery & enablement ---

func (s *Service) DiscoverModels(ctx context.Context, req *connect.Request[clarkv1.DiscoverModelsRequest]) (*connect.Response[clarkv1.DiscoverModelsResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	driver, err := providers.Build(row.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, row.Config)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build driver: %w", err))
	}
	models, err := driver.DiscoverModels(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("discover models: %w", err))
	}
	enabled, err := s.queries.ListUserModelsByProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	enabledSet := make(map[string]bool, len(enabled))
	for _, m := range enabled {
		enabledSet[m.ModelID] = true
	}
	out := make([]*clarkv1.DiscoveredModel, 0, len(models))
	for _, m := range models {
		out = append(out, providerModelToDiscovered(m, enabledSet[m.ID]))
	}
	return connect.NewResponse(&clarkv1.DiscoverModelsResponse{Models: out}), nil
}

func (s *Service) EnableModels(ctx context.Context, req *connect.Request[clarkv1.EnableModelsRequest]) (*connect.Response[clarkv1.EnableModelsResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	if len(req.Msg.ModelIds) == 0 {
		return connect.NewResponse(&clarkv1.EnableModelsResponse{}), nil
	}

	catalogProviderID := configCatalogProviderID(row.Type, row.Config)

	// Driver discovery is lazy — only build/call once if any model misses the catalog.
	var (
		driverModels    []providers.Model
		driverPopulated bool
	)
	loadDriverModels := func() ([]providers.Model, error) {
		if driverPopulated {
			return driverModels, nil
		}
		driver, dErr := providers.Build(row.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, row.Config)
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

	enabled := make([]*clarkv1.UserModel, 0, len(req.Msg.ModelIds))
	now := time.Now().UTC()

	for _, modelID := range req.Msg.ModelIds {
		if modelID == "" {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id cannot be empty"))
		}

		var (
			snap   store.UpsertUserModelParams
			found  bool
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
		enabled = append(enabled, storeUserModelToProto(written))
	}

	return connect.NewResponse(&clarkv1.EnableModelsResponse{Enabled: enabled}), nil
}

func (s *Service) DisableModels(ctx context.Context, req *connect.Request[clarkv1.DisableModelsRequest]) (*connect.Response[clarkv1.DisableModelsResponse], error) {
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
	return connect.NewResponse(&clarkv1.DisableModelsResponse{}), nil
}

func (s *Service) ListUserModels(ctx context.Context, req *connect.Request[clarkv1.ListUserModelsRequest]) (*connect.Response[clarkv1.ListUserModelsResponse], error) {
	row, err := s.loadOwnedProvider(ctx, req.Msg.UserModelProviderId)
	if err != nil {
		return nil, err
	}
	models, err := s.queries.ListUserModelsByProvider(ctx, row.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*clarkv1.UserModel, 0, len(models))
	for _, m := range models {
		out = append(out, storeUserModelToProto(m))
	}
	return connect.NewResponse(&clarkv1.ListUserModelsResponse{Models: out}), nil
}

func (s *Service) ListAllUserModels(ctx context.Context, _ *connect.Request[clarkv1.ListAllUserModelsRequest]) (*connect.Response[clarkv1.ListAllUserModelsResponse], error) {
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
	entries := make([]*clarkv1.UserModelEntry, 0, len(models))
	for _, m := range models {
		p, ok := provByID[m.UserModelProviderID]
		if !ok {
			// Defensive: row from JOIN should always match. Skip if not.
			continue
		}
		entries = append(entries, &clarkv1.UserModelEntry{
			Provider: storeProviderToProto(p),
			Model:    storeUserModelToProto(m),
		})
	}
	return connect.NewResponse(&clarkv1.ListAllUserModelsResponse{Entries: entries}), nil
}

// --- Catalog ---

func (s *Service) RefreshModelCatalog(ctx context.Context, _ *connect.Request[clarkv1.RefreshModelCatalogRequest]) (*connect.Response[clarkv1.RefreshModelCatalogResponse], error) {
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
	resp := &clarkv1.RefreshModelCatalogResponse{
		ProvidersCount: int32(status.ProvidersCount),
		ModelsCount:    int32(status.ModelsCount),
	}
	if status.LastRefreshAt != nil {
		resp.FetchedAt = timestamppb.New(*status.LastRefreshAt)
	}
	return connect.NewResponse(resp), nil
}

func (s *Service) GetCatalogStatus(ctx context.Context, _ *connect.Request[clarkv1.GetCatalogStatusRequest]) (*connect.Response[clarkv1.GetCatalogStatusResponse], error) {
	// Auth-protected by the interceptor; no admin requirement.
	_ = auth.MustFromContext(ctx)
	status, err := s.catalog.Status(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	resp := &clarkv1.GetCatalogStatusResponse{
		ProvidersCount: int32(status.ProvidersCount),
		ModelsCount:    int32(status.ModelsCount),
	}
	if status.LastRefreshAt != nil {
		resp.LastRefreshAt = timestamppb.New(*status.LastRefreshAt)
	}
	return connect.NewResponse(resp), nil
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
		Streaming:     m.Capabilities.Streaming,
		Thinking:      m.Capabilities.Thinking,
		ToolUse:       m.Capabilities.ToolUse,
		Vision:        m.Capabilities.Vision,
		PromptCaching: m.Capabilities.PromptCaching,
	}); err == nil {
		out.Capabilities = capJSON
	}
	if defJSON, err := encodeCallSettings(m.DefaultSettings); err == nil && defJSON != nil {
		out.DefaultSettings = defJSON
	}
	return out, nil
}
