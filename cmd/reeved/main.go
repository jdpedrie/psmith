// reeved is the Reeve server.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"

	"github.com/jdpedrie/reeve/gen/reeve/v1/reevev1connect"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/conversations"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/files"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/modelproviders"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/storage"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
	"github.com/jdpedrie/reeve/internal/streamsvc"

	// Driver packages self-register their provider type in init().
	_ "github.com/jdpedrie/reeve/internal/providers/anthropic"
	_ "github.com/jdpedrie/reeve/internal/providers/google"
	_ "github.com/jdpedrie/reeve/internal/providers/openai"
)

// stubServices is empty now that all five services have implementations.
// Kept as a placeholder so future services can land here if needed.
type stubServices struct{}

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	addr := envOr("REEVE_ADDR", ":8080")
	dsn := os.Getenv("REEVE_DSN")
	if dsn == "" {
		return errors.New("REEVE_DSN is required (Postgres connection string)")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return err
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		return err
	}

	queries := store.New(pool)

	if err := auth.Bootstrap(ctx, queries,
		os.Getenv("REEVE_BOOTSTRAP_ADMIN_USERNAME"),
		os.Getenv("REEVE_BOOTSTRAP_ADMIN_PASSWORD"),
	); err != nil {
		return err
	}

	// LiveCatalog: in-memory cache, lazy fetch from models.dev. No DB
	// tables, no periodic refresh. The cache populates on first lookup
	// (typically within seconds of the first DiscoverModels or
	// LookupModel call) and refreshes only when the user explicitly
	// invokes the RefreshCatalog RPC.
	catalog := modelmeta.NewLiveCatalog(nil)

	supervisor := stream.New(queries, slog.Default())
	if err := supervisor.RecoverInterrupted(ctx); err != nil {
		return fmt.Errorf("recover interrupted streams: %w", err)
	}

	// Background pruner — keeps stream_chunks from accumulating
	// indefinitely. Default 1h retention covers late mobile reconnects;
	// see internal/stream/cleanup.go for tuning notes. Cancel runs at
	// graceful shutdown so the goroutine exits before main returns.
	stopChunkCleanup := stream.StartChunkCleanup(ctx, queries, stream.CleanupConfig{}, slog.Default())
	defer stopChunkCleanup()

	// Load the master encryption key from REEVE_MASTER_KEY (or mint a
	// throwaway one when REEVE_DEV_AUTOKEY=1). When neither is set the
	// server falls back to crypto.Nop{} — config blobs land in the DB
	// in plaintext, with a loud warning so deployers don't ship that
	// posture by accident.
	cipher, err := loadCipher()
	if err != nil {
		return fmt.Errorf("load cipher: %w", err)
	}

	authSvc := auth.NewService(queries)
	authInterceptor := auth.NewInterceptor(queries,
		reevev1connect.AuthServiceLoginProcedure,
		reevev1connect.AuthServiceProbeProcedure,
	)
	opts := connect.WithInterceptors(authInterceptor)

	// Filesystem-backed file storage. $REEVE_DATA_DIR is the operator's
	// chosen root; defaults to ./reeved-data so dev "just works." On
	// first boot the `files/` subdirectory is created at 0700.
	dataDir := os.Getenv("REEVE_DATA_DIR")
	if dataDir == "" {
		dataDir = "reeved-data"
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}
	fileStorage, err := storage.NewFS(dataDir)
	if err != nil {
		return fmt.Errorf("init storage: %w", err)
	}

	// HMAC key for signed `/files/{id}` URLs, derived off the master
	// crypto key so URL-signature secret material rotates with the
	// rest of the at-rest secret.
	masterKey, _, err := crypto.LoadKey()
	if err != nil {
		return fmt.Errorf("load master key for url signing: %w", err)
	}
	urlSigningKey := files.DeriveSigningKey(masterKey)
	baseURL := os.Getenv("REEVE_PUBLIC_BASE_URL") // empty → clients prepend

	modelProvidersSvc := modelproviders.NewService(queries, catalog, cipher, slog.Default())
	profilesSvc := profiles.NewService(queries, pool, cipher)
	conversationsSvc := conversations.NewService(queries, pool, catalog, supervisor, cipher, fileStorage, slog.Default())
	// Wire the auto-title hook so the supervisor pings the conversations
	// service after every assistant materialization. Profile-opt-in; no-op
	// when title fields aren't configured.
	supervisor.SetOnAssistantMaterialized(conversationsSvc.MaybeGenerateTitle)
	streamsSvc := streamsvc.NewService(queries, supervisor)
	filesSvc := files.NewService(queries, fileStorage, urlSigningKey, baseURL)

	mux := http.NewServeMux()
	mux.Handle(reevev1connect.NewAuthServiceHandler(authSvc, opts))
	mux.Handle(reevev1connect.NewModelProvidersServiceHandler(modelProvidersSvc, opts))
	mux.Handle(reevev1connect.NewProfilesServiceHandler(profilesSvc, opts))
	mux.Handle(reevev1connect.NewConversationsServiceHandler(conversationsSvc, opts))
	mux.Handle(reevev1connect.NewStreamsServiceHandler(streamsSvc, opts))
	mux.Handle(reevev1connect.NewFilesServiceHandler(filesSvc, opts))
	// Raw-bytes endpoint for signed file URLs. Bypasses Connect framing
	// so a system image loader can fetch the bytes directly.
	mux.HandleFunc("GET /files/{id}", filesSvc.BytesHandler())
	mux.HandleFunc("HEAD /files/{id}", filesSvc.BytesHandler())
	// Plain HTTP probe used by the iOS/Mac shells to flip their
	// connectivity flag. Cheap on purpose — no auth, no DB hop, just
	// a constant 200. Failure (TCP refused, TLS handshake fail,
	// timeout) is what the client treats as "offline".
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	srv := &http.Server{
		Addr:    addr,
		Handler: h2c.NewHandler(mux, &http2.Server{}),
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("reeved listening", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-errCh:
		return err
	case <-stop:
		slog.Info("shutting down")
	}

	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelShutdown()
	return srv.Shutdown(shutdownCtx)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// loadCipher resolves the at-rest encryption cipher from the
// environment per crypto.LoadKey's contract:
//
//   - REEVE_MASTER_KEY set     → AES-256-GCM with that key.
//   - REEVE_DEV_AUTOKEY=1       → AES-256-GCM with an ephemeral key
//                                 (loud warning; data won't survive a
//                                 restart). Local-dev convenience.
//   - neither set               → crypto.Nop{} (passthrough). Config
//                                 blobs land in plaintext; loud
//                                 warning on boot.
//
// Returns a non-nil Cipher so service constructors don't have to
// special-case nil. Errors only on a malformed REEVE_MASTER_KEY (bad
// base64, wrong length) — the policy choice "no key, run unencrypted"
// is intentional and surfaces as a warning, not a failure.
func loadCipher() (crypto.Cipher, error) {
	key, ephemeral, err := crypto.LoadKey()
	if err != nil {
		return nil, err
	}
	if key == nil {
		slog.Warn("reeved: no encryption key configured; provider config blobs will be stored in plaintext",
			"hint", "set REEVE_MASTER_KEY to a base64-encoded 32-byte key (use `reeve genkey` to mint one)",
		)
		return crypto.Nop{}, nil
	}
	if ephemeral {
		slog.Warn("reeved: REEVE_DEV_AUTOKEY in use — encryption key was minted for this process and lost on restart",
			"hint", "set REEVE_MASTER_KEY for any data you want to read after a restart",
		)
	}
	return crypto.NewAESGCM(key)
}
