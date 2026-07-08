// Package speechsvc serves the SpeechService Connect RPCs — the
// per-user TTS config CRUD the settings page drives — and builds
// ready-to-use Synthesizers for the /tts endpoint. Mirrors
// embeddersvc's layout. The synthesis pipeline itself lives in
// internal/speech; this package is the API surface that lets a user
// say "this is my voice."
package speechsvc

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
	"github.com/jackc/pgx/v5"
	"google.golang.org/protobuf/types/known/timestamppb"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/speech"
	"github.com/jdpedrie/psmith/internal/store"

	"github.com/google/uuid"
)

// KindAppleLocal is the client-side sentinel kind: the device
// synthesizes with AVSpeechSynthesizer and the server is not involved.
// It is the default when no config row exists.
const KindAppleLocal = "apple_local"

// Service implements psmithv1connect.SpeechServiceHandler.
type Service struct {
	queries *store.Queries
	cipher  crypto.Cipher
	logger  *slog.Logger
}

func NewService(queries *store.Queries, cipher crypto.Cipher, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	if cipher == nil {
		cipher = crypto.Nop{}
	}
	return &Service{queries: queries, cipher: cipher, logger: logger}
}

// nonSecretConfig is the JSON persisted in user_tts_config.config —
// the fields the settings UI round-trips, none of the secrets.
type nonSecretConfig struct {
	Voice   string  `json:"voice"`
	Model   string  `json:"model"`
	Speed   float64 `json:"speed"`
	BaseURL string  `json:"base_url"`
}

// --- GetSpeechConfig ---

func (s *Service) GetSpeechConfig(ctx context.Context, _ *connect.Request[psmithv1.GetSpeechConfigRequest]) (*connect.Response[psmithv1.GetSpeechConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	row, err := s.queries.GetUserTTSConfig(ctx, user.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return connect.NewResponse(&psmithv1.GetSpeechConfigResponse{
				Config: defaultProtoConfig(),
			}), nil
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	cfg, err := s.rowToProto(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.GetSpeechConfigResponse{Config: cfg}), nil
}

// defaultProtoConfig is the shape returned when no row exists: the
// apple_local default, enabled, everything else zero.
func defaultProtoConfig() *psmithv1.SpeechConfig {
	return &psmithv1.SpeechConfig{
		Kind:              KindAppleLocal,
		Enabled:           true,
		NormalizerVersion: speech.NormalizerVersion,
	}
}

func (s *Service) rowToProto(row store.UserTtsConfig) (*psmithv1.SpeechConfig, error) {
	var ns nonSecretConfig
	if len(row.Config) > 0 {
		if err := json.Unmarshal(row.Config, &ns); err != nil {
			return nil, fmt.Errorf("decode tts config: %w", err)
		}
	}
	out := &psmithv1.SpeechConfig{
		Kind:              row.Kind,
		Voice:             ns.Voice,
		Model:             ns.Model,
		Speed:             ns.Speed,
		BaseUrl:           ns.BaseURL,
		ApiKeySet:         len(row.ApiKeyEncrypted) > 0,
		Enabled:           row.Enabled,
		CreatedAt:         timestamppb.New(row.CreatedAt),
		UpdatedAt:         timestamppb.New(row.UpdatedAt),
		NormalizerVersion: speech.NormalizerVersion,
	}
	if row.ProviderRef != nil {
		out.ProviderRef = row.ProviderRef.String()
	}
	return out, nil
}

// --- UpdateSpeechConfig ---

func (s *Service) UpdateSpeechConfig(ctx context.Context, req *connect.Request[psmithv1.UpdateSpeechConfigRequest]) (*connect.Response[psmithv1.UpdateSpeechConfigResponse], error) {
	user := auth.MustFromContext(ctx)

	existing, err := s.queries.GetUserTTSConfig(ctx, user.ID)
	hadRow := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	kind := KindAppleLocal
	var ns nonSecretConfig
	enabled := true
	var encryptedKey []byte
	var providerRef *uuid.UUID
	if hadRow {
		kind = existing.Kind
		if len(existing.Config) > 0 {
			if err := json.Unmarshal(existing.Config, &ns); err != nil {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("decode existing config: %w", err))
			}
		}
		enabled = existing.Enabled
		encryptedKey = existing.ApiKeyEncrypted
		providerRef = existing.ProviderRef
	}

	if req.Msg.Kind != nil {
		k := strings.TrimSpace(*req.Msg.Kind)
		if k != KindAppleLocal && !registeredKind(k) {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("unknown speech kind %q", k))
		}
		kind = k
	}
	if req.Msg.Voice != nil {
		ns.Voice = strings.TrimSpace(*req.Msg.Voice)
	}
	if req.Msg.Model != nil {
		ns.Model = strings.TrimSpace(*req.Msg.Model)
	}
	if req.Msg.Speed != nil {
		if *req.Msg.Speed < 0 || *req.Msg.Speed > 4 {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("speed out of range"))
		}
		ns.Speed = *req.Msg.Speed
	}
	if req.Msg.BaseUrl != nil {
		ns.BaseURL = strings.TrimSpace(*req.Msg.BaseUrl)
	}
	if req.Msg.ApiKey != nil {
		if *req.Msg.ApiKey == "" {
			encryptedKey = nil
		} else {
			enc, err := s.cipher.Encrypt([]byte(*req.Msg.ApiKey))
			if err != nil {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encrypt api key: %w", err))
			}
			encryptedKey = enc
		}
	}
	if req.Msg.ProviderRef != nil {
		if *req.Msg.ProviderRef == "" {
			providerRef = nil
		} else {
			id, err := uuid.Parse(*req.Msg.ProviderRef)
			if err != nil {
				return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid provider_ref: %w", err))
			}
			// Ownership: the referenced chat provider must be the
			// caller's — the ref grants use of its credential.
			prov, err := s.queries.GetUserModelProvider(ctx, id)
			if err != nil || prov.UserID != user.ID {
				return nil, connect.NewError(connect.CodeNotFound, errors.New("provider not found"))
			}
			providerRef = &id
		}
	}
	if req.Msg.Enabled != nil {
		enabled = *req.Msg.Enabled
	}

	blob, err := json.Marshal(ns)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	row, err := s.queries.UpsertUserTTSConfig(ctx, store.UpsertUserTTSConfigParams{
		UserID:          user.ID,
		Kind:            kind,
		Config:          blob,
		ApiKeyEncrypted: encryptedKey,
		ProviderRef:     providerRef,
		Enabled:         enabled,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	cfg, err := s.rowToProto(row)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.UpdateSpeechConfigResponse{Config: cfg}), nil
}

func registeredKind(k string) bool {
	for _, name := range speech.Kinds() {
		if name == k {
			return true
		}
	}
	return false
}

// --- DeleteSpeechConfig ---

func (s *Service) DeleteSpeechConfig(ctx context.Context, _ *connect.Request[psmithv1.DeleteSpeechConfigRequest]) (*connect.Response[psmithv1.DeleteSpeechConfigResponse], error) {
	user := auth.MustFromContext(ctx)
	if err := s.queries.DeleteUserTTSConfig(ctx, user.ID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.DeleteSpeechConfigResponse{}), nil
}

// --- TestSpeechConfig ---

const testPhrase = "This is a Psmith speech test."

func (s *Service) TestSpeechConfig(ctx context.Context, _ *connect.Request[psmithv1.TestSpeechConfigRequest]) (*connect.Response[psmithv1.TestSpeechConfigResponse], error) {
	user := auth.MustFromContext(ctx)

	synth, kind, req, err := s.BuildForUser(ctx, user.ID)
	if err != nil {
		return connect.NewResponse(&psmithv1.TestSpeechConfigResponse{
			Ok: false, ErrorMessage: err.Error(),
		}), nil
	}
	if kind == KindAppleLocal {
		// Nothing server-side to test: the device synthesizes.
		return connect.NewResponse(&psmithv1.TestSpeechConfigResponse{Ok: true}), nil
	}

	testCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	start := time.Now()
	in := make(chan string, 1)
	in <- testPhrase
	close(in)
	frames, errs := synth.Synthesize(testCtx, req, in)
	var bytes int64
	for f := range frames {
		bytes += int64(len(f.PCM))
	}
	if err := <-errs; err != nil {
		return connect.NewResponse(&psmithv1.TestSpeechConfigResponse{
			Ok: false, ErrorMessage: err.Error(), LatencyMs: time.Since(start).Milliseconds(),
		}), nil
	}
	return connect.NewResponse(&psmithv1.TestSpeechConfigResponse{
		Ok: true, LatencyMs: time.Since(start).Milliseconds(), AudioBytes: bytes,
	}), nil
}

// --- ListSpeechKinds ---

func (s *Service) ListSpeechKinds(ctx context.Context, _ *connect.Request[psmithv1.ListSpeechKindsRequest]) (*connect.Response[psmithv1.ListSpeechKindsResponse], error) {
	kinds := append(speech.Kinds(), KindAppleLocal)
	sort.Strings(kinds)
	return connect.NewResponse(&psmithv1.ListSpeechKindsResponse{Kinds: kinds}), nil
}

// --- Synthesizer assembly (used by the /tts endpoint and Test) ---

// ErrNotServerSynthesized marks configs the server does not synthesize
// for: apple_local (client-side) and disabled rows.
var ErrNotServerSynthesized = errors.New("speech: not server-synthesized")

// BuildForUser resolves the user's speech config into a ready
// Synthesizer plus the per-request knobs. For apple_local it returns
// (nil, KindAppleLocal, zero, nil) — callers branch on kind. The
// standalone api_key wins over provider_ref when both are present.
func (s *Service) BuildForUser(ctx context.Context, userID uuid.UUID) (speech.Synthesizer, string, speech.Request, error) {
	row, err := s.queries.GetUserTTSConfig(ctx, userID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, KindAppleLocal, speech.Request{}, nil
		}
		return nil, "", speech.Request{}, err
	}
	if !row.Enabled {
		return nil, "", speech.Request{}, fmt.Errorf("%w: speech is disabled", ErrNotServerSynthesized)
	}
	if row.Kind == KindAppleLocal {
		return nil, KindAppleLocal, speech.Request{}, nil
	}

	var ns nonSecretConfig
	if len(row.Config) > 0 {
		if err := json.Unmarshal(row.Config, &ns); err != nil {
			return nil, "", speech.Request{}, fmt.Errorf("decode tts config: %w", err)
		}
	}

	apiKey := ""
	if len(row.ApiKeyEncrypted) > 0 {
		key, err := s.cipher.Decrypt(row.ApiKeyEncrypted)
		if err != nil {
			return nil, "", speech.Request{}, fmt.Errorf("decrypt api key: %w", err)
		}
		apiKey = string(key)
	} else if row.ProviderRef != nil {
		key, err := s.providerAPIKey(ctx, *row.ProviderRef, userID)
		if err != nil {
			return nil, "", speech.Request{}, err
		}
		apiKey = key
	}

	driverCfg, err := json.Marshal(map[string]string{
		"api_key":  apiKey,
		"base_url": ns.BaseURL,
	})
	if err != nil {
		return nil, "", speech.Request{}, err
	}
	synth, err := speech.Build(row.Kind, driverCfg)
	if err != nil {
		return nil, "", speech.Request{}, err
	}
	return synth, row.Kind, speech.Request{Voice: ns.Voice, Model: ns.Model, Speed: ns.Speed}, nil
}

// providerAPIKey pulls the api_key out of a chat provider's decrypted
// config blob for the credential-reuse path.
func (s *Service) providerAPIKey(ctx context.Context, providerID, userID uuid.UUID) (string, error) {
	row, err := s.queries.GetUserModelProvider(ctx, providerID)
	if err != nil || row.UserID != userID {
		return "", errors.New("speech: referenced provider not found")
	}
	blob, err := crypto.ResolveSecret(s.cipher, row.ConfigEncrypted, row.Config)
	if err != nil {
		return "", fmt.Errorf("decrypt provider config: %w", err)
	}
	var cfg struct {
		APIKey string `json:"api_key"`
	}
	if len(blob) > 0 {
		if err := json.Unmarshal(blob, &cfg); err != nil {
			return "", fmt.Errorf("decode provider config: %w", err)
		}
	}
	if cfg.APIKey == "" {
		return "", errors.New("speech: referenced provider has no api_key")
	}
	return cfg.APIKey, nil
}
