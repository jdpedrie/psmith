// Package embeddersvc serves the EmbedderService Connect RPCs — the
// per-user embedder credential + toggle CRUD the settings page
// drives. Mirrors langfusesvc's layout: thin handler that reads /
// writes user_embedder_config and keeps the in-memory Resolver
// cache invalidated on writes.
//
// The actual embed loop lives in internal/embeddings; this package
// is the API surface that lets a user say "this is my embedder."
package embeddersvc

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
	"google.golang.org/protobuf/types/known/timestamppb"

	spaltv1 "github.com/jdpedrie/spalt/gen/spalt/v1"
	"github.com/jdpedrie/spalt/internal/auth"
	"github.com/jdpedrie/spalt/internal/crypto"
	"github.com/jdpedrie/spalt/internal/embeddings"
	"github.com/jdpedrie/spalt/internal/store"
)

// Service implements spaltv1connect.EmbedderServiceHandler.
// Stateless beyond the cache-invalidation hook; constructed once at
// server boot and shared across requests.
type Service struct {
	queries *store.Queries
	cipher  crypto.Cipher
	// invalidateCache is called after every Update / Delete so the
	// next Worker poll / Searcher query picks up the new config
	// without a process restart. nil = no caching layer wired
	// (tests).
	invalidateCache func(userID uuid.UUID)
	logger          *slog.Logger
}

// NewService wires the dependencies. invalidateCache is the
// CachingResolver's Invalidate method (or nil for tests).
func NewService(
	queries *store.Queries,
	cipher crypto.Cipher,
	invalidateCache func(userID uuid.UUID),
	logger *slog.Logger,
) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	if cipher == nil {
		cipher = crypto.Nop{}
	}
	return &Service{
		queries:         queries,
		cipher:          cipher,
		invalidateCache: invalidateCache,
		logger:          logger,
	}
}

// nonSecretConfig is the JSON shape persisted in
// user_embedder_config.config — every field the user sees in the
// settings UI, none of the secrets. Mirrors openai.Config minus the
// api_key (which lives in its own encrypted column).
type nonSecretConfig struct {
	BaseURL    string `json:"base_url"`
	Model      string `json:"model"`
	Dimensions int    `json:"dimensions"`
}

// --- GetEmbedderConfig ---

func (s *Service) GetEmbedderConfig(ctx context.Context, _ *connect.Request[spaltv1.GetEmbedderConfigRequest]) (*connect.Response[spaltv1.GetEmbedderConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	row, err := s.queries.GetUserEmbedderConfig(ctx, user.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return connect.NewResponse(&spaltv1.GetEmbedderConfigResponse{
				Config: defaultProtoConfig(),
			}), nil
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&spaltv1.GetEmbedderConfigResponse{
		Config: s.rowToProto(row),
	}), nil
}

// --- UpdateEmbedderConfig ---

func (s *Service) UpdateEmbedderConfig(ctx context.Context, req *connect.Request[spaltv1.UpdateEmbedderConfigRequest]) (*connect.Response[spaltv1.UpdateEmbedderConfigResponse], error) {
	user := auth.MustFromContext(ctx)

	// Load existing row so we can sparse-merge.
	existing, err := s.queries.GetUserEmbedderConfig(ctx, user.ID)
	hadRow := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	driverType := defaultType
	nonSecret := defaultNonSecret()
	enabled := false
	var encryptedAPIKey []byte
	if hadRow {
		driverType = existing.Type
		if err := json.Unmarshal(existing.Config, &nonSecret); err != nil {
			return nil, connect.NewError(connect.CodeInternal,
				fmt.Errorf("decode existing config: %w", err))
		}
		enabled = existing.Enabled
		encryptedAPIKey = existing.ApiKeyEncrypted
	}

	if req.Msg.Type != nil {
		t := strings.TrimSpace(*req.Msg.Type)
		if t == "" {
			return nil, connect.NewError(connect.CodeInvalidArgument,
				errors.New("type cannot be empty"))
		}
		if !embeddings.IsRegistered(t) {
			return nil, connect.NewError(connect.CodeInvalidArgument,
				fmt.Errorf("unknown embedder type %q (known: %v)", t, embeddings.Names()))
		}
		driverType = t
	}
	if req.Msg.BaseUrl != nil {
		nonSecret.BaseURL = strings.TrimRight(strings.TrimSpace(*req.Msg.BaseUrl), "/")
	}
	if req.Msg.Model != nil {
		nonSecret.Model = strings.TrimSpace(*req.Msg.Model)
	}
	if req.Msg.Dimensions != nil {
		if *req.Msg.Dimensions <= 0 {
			return nil, connect.NewError(connect.CodeInvalidArgument,
				errors.New("dimensions must be positive"))
		}
		nonSecret.Dimensions = int(*req.Msg.Dimensions)
	}
	if req.Msg.ApiKey != nil {
		v := strings.TrimSpace(*req.Msg.ApiKey)
		if v == "" {
			encryptedAPIKey = nil
		} else {
			enc, encErr := s.cipher.Encrypt([]byte(v))
			if encErr != nil {
				return nil, connect.NewError(connect.CodeInternal,
					fmt.Errorf("encrypt api_key: %w", encErr))
			}
			encryptedAPIKey = enc
		}
	}
	if req.Msg.Enabled != nil {
		enabled = *req.Msg.Enabled
	}

	// Sanity check before persisting.
	if nonSecret.BaseURL == "" || nonSecret.Model == "" || nonSecret.Dimensions <= 0 {
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			errors.New("base_url, model, and dimensions are all required"))
	}

	cfgJSON, err := json.Marshal(nonSecret)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encode config: %w", err))
	}

	row, err := s.queries.UpsertUserEmbedderConfig(ctx, store.UpsertUserEmbedderConfigParams{
		UserID:          user.ID,
		Type:            driverType,
		Config:          cfgJSON,
		ApiKeyEncrypted: encryptedAPIKey,
		Enabled:         enabled,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Drop the cache so the next embed / search builds the new config.
	if s.invalidateCache != nil {
		s.invalidateCache(user.ID)
	}

	return connect.NewResponse(&spaltv1.UpdateEmbedderConfigResponse{
		Config: s.rowToProto(row),
	}), nil
}

// --- DeleteEmbedderConfig ---

func (s *Service) DeleteEmbedderConfig(ctx context.Context, _ *connect.Request[spaltv1.DeleteEmbedderConfigRequest]) (*connect.Response[spaltv1.DeleteEmbedderConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	if err := s.queries.DeleteUserEmbedderConfig(ctx, user.ID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if s.invalidateCache != nil {
		s.invalidateCache(user.ID)
	}
	return connect.NewResponse(&spaltv1.DeleteEmbedderConfigResponse{}), nil
}

// --- TestEmbedderConfig ---

// TestEmbedderConfig fires one Embed("ping") at the configured
// endpoint and reports back. Returns ok=false (with the error in
// error_message) on auth / network failure rather than a Connect
// error, so the settings UI can render the result inline.
func (s *Service) TestEmbedderConfig(ctx context.Context, _ *connect.Request[spaltv1.TestEmbedderConfigRequest]) (*connect.Response[spaltv1.TestEmbedderConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	row, err := s.queries.GetUserEmbedderConfig(ctx, user.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return connect.NewResponse(&spaltv1.TestEmbedderConfigResponse{
				Ok: false, ErrorMessage: "no embedder config saved yet",
			}), nil
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	embedder, buildErr := buildEmbedderFromRow(s.cipher, row)
	if buildErr != nil {
		return connect.NewResponse(&spaltv1.TestEmbedderConfigResponse{
			Ok: false, ErrorMessage: buildErr.Error(),
		}), nil
	}

	start := time.Now()
	probeCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	_, err = embedder.Embed(probeCtx, []string{"ping"})
	latency := time.Since(start).Milliseconds()
	if err != nil {
		return connect.NewResponse(&spaltv1.TestEmbedderConfigResponse{
			Ok: false, ErrorMessage: err.Error(), LatencyMs: latency,
		}), nil
	}
	return connect.NewResponse(&spaltv1.TestEmbedderConfigResponse{
		Ok: true, LatencyMs: latency,
	}), nil
}

// --- ListEmbedderTypes ---

func (s *Service) ListEmbedderTypes(_ context.Context, _ *connect.Request[spaltv1.ListEmbedderTypesRequest]) (*connect.Response[spaltv1.ListEmbedderTypesResponse], error) {
	names := embeddings.Names()
	sort.Strings(names)
	return connect.NewResponse(&spaltv1.ListEmbedderTypesResponse{Types: names}), nil
}

// --- GetEmbedderStats ---

func (s *Service) GetEmbedderStats(ctx context.Context, _ *connect.Request[spaltv1.GetEmbedderStatsRequest]) (*connect.Response[spaltv1.GetEmbedderStatsResponse], error) {
	user := auth.MustFromContext(ctx)
	unembedded, err := s.queries.CountUnembeddedMessages(ctx, user.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Worker is active when the user has a row marked enabled.
	// (The cmd/spaltd SPALT_EMBEDDER fallback path counts as
	// "active" too — we surface that case in a follow-up when the
	// fallback is wired into this service.)
	workerActive := false
	if row, err := s.queries.GetUserEmbedderConfig(ctx, user.ID); err == nil && row.Enabled {
		workerActive = true
	}
	return connect.NewResponse(&spaltv1.GetEmbedderStatsResponse{
		UnembeddedCount: unembedded,
		WorkerActive:    workerActive,
	}), nil
}

// --- internal helpers ---

const defaultType = "openai"

func defaultNonSecret() nonSecretConfig {
	return nonSecretConfig{
		BaseURL:    "http://localhost:11434/v1",
		Model:      "nomic-embed-text",
		Dimensions: 768,
	}
}

func defaultProtoConfig() *spaltv1.EmbedderConfig {
	d := defaultNonSecret()
	return &spaltv1.EmbedderConfig{
		Type:       defaultType,
		BaseUrl:    d.BaseURL,
		Model:      d.Model,
		Dimensions: int32(d.Dimensions),
		Enabled:    false,
	}
}

func (s *Service) rowToProto(row store.UserEmbedderConfig) *spaltv1.EmbedderConfig {
	var ns nonSecretConfig
	_ = json.Unmarshal(row.Config, &ns)
	return &spaltv1.EmbedderConfig{
		Type:       row.Type,
		BaseUrl:    ns.BaseURL,
		Model:      ns.Model,
		Dimensions: int32(ns.Dimensions),
		ApiKeySet:  row.ApiKeyEncrypted != nil,
		Enabled:    row.Enabled,
		CreatedAt:  timestamppb.New(row.CreatedAt),
		UpdatedAt:  timestamppb.New(row.UpdatedAt),
	}
}

// buildEmbedderFromRow turns a user_embedder_config row into a live
// Embedder. Decrypts the api_key via the cipher, merges into the
// driver's config JSON, calls embeddings.Build. Exported indirectly
// via NewDBResolver below — also used by the test handler.
func buildEmbedderFromRow(cipher crypto.Cipher, row store.UserEmbedderConfig) (embeddings.Embedder, error) {
	var ns nonSecretConfig
	if err := json.Unmarshal(row.Config, &ns); err != nil {
		return nil, fmt.Errorf("decode config: %w", err)
	}
	// Merge non-secret + decrypted api_key into one driver config
	// blob. The driver's own JSON unmarshal handles unknown fields
	// gracefully, so this works for any future driver shape.
	driverCfg := map[string]any{
		"base_url":   ns.BaseURL,
		"model":      ns.Model,
		"dimensions": ns.Dimensions,
	}
	if row.ApiKeyEncrypted != nil {
		plain, err := cipher.Decrypt(row.ApiKeyEncrypted)
		if err != nil {
			return nil, fmt.Errorf("decrypt api_key: %w", err)
		}
		driverCfg["api_key"] = string(plain)
	}
	cfgJSON, err := json.Marshal(driverCfg)
	if err != nil {
		return nil, fmt.Errorf("encode driver config: %w", err)
	}
	return embeddings.Build(row.Type, cfgJSON)
}

// NewDBResolver returns an embeddings.Resolver that pulls per-user
// configs from user_embedder_config and decrypts the api_key via
// the given cipher. The returned function is suitable for
// embeddings.CachingResolver.Build:
//
//	cached := &embeddings.CachingResolver{Build: embeddersvc.NewDBResolver(q, cipher)}
//
// Surfaces ErrNoEmbedderForUser when the user has no row or the row
// is disabled — the worker / searcher skips them cleanly.
func NewDBResolver(q *store.Queries, cipher crypto.Cipher) func(ctx context.Context, userID uuid.UUID) (embeddings.Embedder, error) {
	if cipher == nil {
		cipher = crypto.Nop{}
	}
	return func(ctx context.Context, userID uuid.UUID) (embeddings.Embedder, error) {
		row, err := q.GetUserEmbedderConfig(ctx, userID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, embeddings.ErrNoEmbedderForUser
			}
			return nil, err
		}
		if !row.Enabled {
			return nil, embeddings.ErrNoEmbedderForUser
		}
		return buildEmbedderFromRow(cipher, row)
	}
}
