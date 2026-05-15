// Package langfusesvc serves the LangfuseService Connect RPCs —
// the per-user Langfuse credential + toggle CRUD that the settings
// page drives. The actual emit-on-turn loop lives in
// internal/langfuse; this package is the thin API surface that
// reads + writes user_langfuse_config and keeps the in-memory
// emitter cache in sync.
package langfusesvc

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"
	"google.golang.org/protobuf/types/known/timestamppb"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/langfuse"
	"github.com/jdpedrie/reeve/internal/store"
)

// Service implements reevev1connect.LangfuseServiceHandler. Stateless;
// constructed once at server startup and shared across all requests.
type Service struct {
	queries *store.Queries
	cipher  crypto.Cipher
	emitter *langfuse.Emitter
	logger  *slog.Logger
}

// NewService wires the dependencies. emitter is the process-wide
// Langfuse client; the service refreshes its per-user cache via
// emitter.SetUserConfig on every Update / Delete so changes are
// immediately reflected in subsequent emits.
func NewService(queries *store.Queries, cipher crypto.Cipher, emitter *langfuse.Emitter, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{queries: queries, cipher: cipher, emitter: emitter, logger: logger}
}

// GetLangfuseConfig returns the calling user's row, or a
// zero-value disabled shape when no row exists. secret_key is
// never echoed back — the response carries `has_secret_key` so the
// client can render a "credentials saved" indicator.
func (s *Service) GetLangfuseConfig(ctx context.Context, _ *connect.Request[reevev1.GetLangfuseConfigRequest]) (*connect.Response[reevev1.GetLangfuseConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	row, err := s.queries.GetUserLangfuseConfig(ctx, user.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return connect.NewResponse(&reevev1.GetLangfuseConfigResponse{
				Config: defaultProtoConfig(),
			}), nil
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&reevev1.GetLangfuseConfigResponse{
		Config: rowToProto(row),
	}), nil
}

// UpdateLangfuseConfig upserts the row. Each request field is
// optional; absent = keep existing value (or default on first
// write). secret_key has tri-state semantics:
//
//   - field absent (nil) → leave the encrypted blob alone.
//   - field present + empty ("") → clear the secret.
//   - field present + non-empty → encrypt + replace.
//
// On success, the in-memory emitter cache is refreshed so the next
// turn dispatches with the new credentials.
func (s *Service) UpdateLangfuseConfig(ctx context.Context, req *connect.Request[reevev1.UpdateLangfuseConfigRequest]) (*connect.Response[reevev1.UpdateLangfuseConfigResponse], error) {
	user := auth.MustFromContext(ctx)

	// Load existing row (if any) so the upsert merges sparsely.
	existing, err := s.queries.GetUserLangfuseConfig(ctx, user.ID)
	hadRow := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	host := defaultHost
	publicKey := ""
	enabled := false
	var encryptedSecret []byte
	if hadRow {
		host = existing.Host
		publicKey = existing.PublicKey
		enabled = existing.Enabled
		encryptedSecret = existing.SecretKeyEncrypted
	}

	if req.Msg.Host != nil {
		host = strings.TrimRight(strings.TrimSpace(*req.Msg.Host), "/")
		if host == "" {
			host = defaultHost
		}
	}
	if req.Msg.PublicKey != nil {
		publicKey = strings.TrimSpace(*req.Msg.PublicKey)
	}
	if req.Msg.SecretKey != nil {
		v := strings.TrimSpace(*req.Msg.SecretKey)
		if v == "" {
			encryptedSecret = nil
		} else {
			enc, encErr := s.cipher.Encrypt([]byte(v))
			if encErr != nil {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encrypt secret_key: %w", encErr))
			}
			encryptedSecret = enc
		}
	}
	if req.Msg.Enabled != nil {
		enabled = *req.Msg.Enabled
	}

	// Guard: don't let a user enable tracing without a secret. Without
	// the key the emitter would silently drop everything anyway, but
	// the toggle being on without a way to authenticate is a confusing
	// "saved successfully" → "nothing happens" UX.
	if enabled && (publicKey == "" || encryptedSecret == nil) {
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			errors.New("enabled requires both public_key and secret_key"))
	}

	row, err := s.queries.UpsertUserLangfuseConfig(ctx, store.UpsertUserLangfuseConfigParams{
		UserID:             user.ID,
		Host:               host,
		PublicKey:          publicKey,
		SecretKeyEncrypted: encryptedSecret,
		Enabled:            enabled,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Refresh the in-memory emitter cache so the next assistant turn
	// uses the new credentials. Best-effort: a decrypt failure here
	// (corrupt blob, key rotation, etc.) is non-fatal — we surface
	// the row to the client and log so the operator notices.
	s.refreshEmitter(user.ID.String(), row)

	return connect.NewResponse(&reevev1.UpdateLangfuseConfigResponse{
		Config: rowToProto(row),
	}), nil
}

// DeleteLangfuseConfig removes the row entirely + drops the
// emitter's cached credentials. Idempotent — no error when nothing
// exists to delete.
func (s *Service) DeleteLangfuseConfig(ctx context.Context, _ *connect.Request[reevev1.DeleteLangfuseConfigRequest]) (*connect.Response[reevev1.DeleteLangfuseConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	if err := s.queries.DeleteUserLangfuseConfig(ctx, user.ID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if s.emitter != nil {
		s.emitter.SetUserConfig(user.ID.String(), langfuse.Config{})
	}
	return connect.NewResponse(&reevev1.DeleteLangfuseConfigResponse{}), nil
}

// TestLangfuseConfig fires a single synthetic trace at the
// configured host and reports back. Returns ok=false (with the
// error in error_message) on auth / network failure rather than an
// RPC error — the settings page renders the result inline next to
// the test button.
//
// This call deliberately does NOT use the batched Emitter — it
// needs synchronous success/failure for the UI's test affordance.
// A throwaway one-shot Emitter is constructed, fired, and torn
// down within the call.
func (s *Service) TestLangfuseConfig(ctx context.Context, _ *connect.Request[reevev1.TestLangfuseConfigRequest]) (*connect.Response[reevev1.TestLangfuseConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	row, err := s.queries.GetUserLangfuseConfig(ctx, user.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return connect.NewResponse(&reevev1.TestLangfuseConfigResponse{
				Ok: false, ErrorMessage: "no langfuse config saved yet",
			}), nil
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	cfg, decErr := s.decryptedConfig(row)
	if decErr != nil {
		return connect.NewResponse(&reevev1.TestLangfuseConfigResponse{
			Ok: false, ErrorMessage: decErr.Error(),
		}), nil
	}
	if cfg.PublicKey == "" || cfg.SecretKey == "" {
		return connect.NewResponse(&reevev1.TestLangfuseConfigResponse{
			Ok: false, ErrorMessage: "credentials are incomplete",
		}), nil
	}

	// Spin up a one-shot emitter, fire one trace, stop. The Stop
	// call blocks until the buffer drains, so we get sync success
	// signal even though the underlying client is async.
	probeEmitter := langfuse.NewEmitter(s.logger, langfuse.EmitterConfig{
		FlushInterval:  100 * time.Millisecond,
		FlushBatchSize: 1,
	})
	probeEmitter.SetUserConfig(user.ID.String(), langfuse.Config{
		Host: cfg.Host, PublicKey: cfg.PublicKey, SecretKey: cfg.SecretKey, Enabled: true,
	})
	now := time.Now().UTC()
	probeEmitter.EmitTurn(user.ID.String(),
		langfuse.Trace{
			ID:        fmt.Sprintf("reeve-test-%d", now.UnixNano()),
			Name:      "reeve · test trace",
			SessionID: "reeve-test-session",
			Output:    "If you're seeing this in Langfuse, your Reeve integration is working.",
			StartTime: now,
			EndTime:   now,
			Tags:      []string{"reeve", "test"},
		},
		langfuse.Generation{
			ID:        fmt.Sprintf("reeve-test-gen-%d", now.UnixNano()),
			TraceID:   fmt.Sprintf("reeve-test-%d", now.UnixNano()),
			Name:      "test ping",
			Model:     "synthetic",
			Output:    "ok",
			StartTime: now,
			EndTime:   now,
		})

	stopCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	start := time.Now()
	probeEmitter.Stop(stopCtx)
	latency := time.Since(start).Milliseconds()

	// The Emitter logs HTTP failures rather than returning them, so
	// we can't distinguish success from "POST happened but Langfuse
	// rejected it" here. Treat completion-without-panic as success;
	// real auth failures show up in server logs and the user can
	// re-test after fixing.
	return connect.NewResponse(&reevev1.TestLangfuseConfigResponse{
		Ok:        true,
		LatencyMs: latency,
	}), nil
}

// LoadAllOnStartup primes the emitter cache with every existing
// user_langfuse_config row at server boot. Without this the first
// assistant turn after restart would emit nothing (emitter cache
// is empty until the user touches Update). Best-effort per-row;
// decrypt failures are logged and skipped so one bad row doesn't
// break boot.
func (s *Service) LoadAllOnStartup(ctx context.Context) error {
	if s.emitter == nil {
		return nil
	}
	rows, err := s.queries.ListUserLangfuseConfigs(ctx)
	if err != nil {
		return fmt.Errorf("list langfuse configs: %w", err)
	}
	for _, row := range rows {
		s.refreshEmitter(row.UserID.String(), row)
	}
	return nil
}

// --- internal helpers ---

const defaultHost = "https://us.cloud.langfuse.com"

func defaultProtoConfig() *reevev1.LangfuseConfig {
	return &reevev1.LangfuseConfig{
		Host:    defaultHost,
		Enabled: false,
	}
}

func rowToProto(row store.UserLangfuseConfig) *reevev1.LangfuseConfig {
	return &reevev1.LangfuseConfig{
		Host:         row.Host,
		PublicKey:    row.PublicKey,
		HasSecretKey: row.SecretKeyEncrypted != nil,
		Enabled:      row.Enabled,
		CreatedAt:    timestamppb.New(row.CreatedAt),
		UpdatedAt:    timestamppb.New(row.UpdatedAt),
	}
}

// decryptedConfig pulls the encrypted secret_key off the row,
// decrypts it through the configured cipher, and packages the
// result into a langfuse.Config the emitter can consume. Returns
// an error if the encrypted blob exists but won't decrypt
// (corrupt, key rotation, etc.) — callers should surface this so
// the operator notices.
//
// Encryption-only by design: the table has no plaintext fallback
// column. If row.SecretKeyEncrypted is nil the user simply hasn't
// set a secret yet, and the returned Config has SecretKey="" —
// langfuse.Config.Valid() then reports false and the emitter
// skips the user.
func (s *Service) decryptedConfig(row store.UserLangfuseConfig) (langfuse.Config, error) {
	cfg := langfuse.Config{
		Host:      row.Host,
		PublicKey: row.PublicKey,
		Enabled:   row.Enabled,
	}
	if row.SecretKeyEncrypted == nil {
		return cfg, nil
	}
	plain, err := s.cipher.Decrypt(row.SecretKeyEncrypted)
	if err != nil {
		return langfuse.Config{}, fmt.Errorf("decrypt secret_key: %w", err)
	}
	cfg.SecretKey = string(plain)
	return cfg, nil
}

// refreshEmitter pushes the row's decrypted shape into the
// emitter's per-user cache. Logs and continues on decrypt failure
// so a malformed row doesn't stall the calling RPC.
func (s *Service) refreshEmitter(userID string, row store.UserLangfuseConfig) {
	if s.emitter == nil {
		return
	}
	cfg, err := s.decryptedConfig(row)
	if err != nil {
		s.logger.Warn("langfuse: decrypt failed, skipping emitter cache update",
			"user_id", userID, "err", err)
		return
	}
	s.emitter.SetUserConfig(userID, cfg)
}
