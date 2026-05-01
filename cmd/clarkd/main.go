// clarkd is the Clark server.
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

	"github.com/jdpedrie/clark/gen/clark/v1/clarkv1connect"
	"github.com/jdpedrie/clark/internal/auth"
	"github.com/jdpedrie/clark/internal/conversations"
	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/modelproviders"
	"github.com/jdpedrie/clark/internal/profiles"
	"github.com/jdpedrie/clark/internal/store"
	"github.com/jdpedrie/clark/internal/stream"
	"github.com/jdpedrie/clark/internal/streamsvc"

	// Driver packages self-register their provider type in init().
	_ "github.com/jdpedrie/clark/internal/providers/anthropic"
	_ "github.com/jdpedrie/clark/internal/providers/google"
	_ "github.com/jdpedrie/clark/internal/providers/openai"
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
	addr := envOr("CLARK_ADDR", ":8080")
	dsn := os.Getenv("CLARK_DSN")
	if dsn == "" {
		return errors.New("CLARK_DSN is required (Postgres connection string)")
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
		os.Getenv("CLARK_BOOTSTRAP_ADMIN_USERNAME"),
		os.Getenv("CLARK_BOOTSTRAP_ADMIN_PASSWORD"),
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

	authSvc := auth.NewService(queries)
	authInterceptor := auth.NewInterceptor(queries,
		clarkv1connect.AuthServiceLoginProcedure,
		clarkv1connect.AuthServiceProbeProcedure,
	)
	opts := connect.WithInterceptors(authInterceptor)

	modelProvidersSvc := modelproviders.NewService(queries, catalog, slog.Default())
	profilesSvc := profiles.NewService(queries, pool)
	conversationsSvc := conversations.NewService(queries, pool, catalog, supervisor, slog.Default())
	// Wire the auto-title hook so the supervisor pings the conversations
	// service after every assistant materialization. Profile-opt-in; no-op
	// when title fields aren't configured.
	supervisor.SetOnAssistantMaterialized(conversationsSvc.MaybeGenerateTitle)
	streamsSvc := streamsvc.NewService(supervisor)

	mux := http.NewServeMux()
	mux.Handle(clarkv1connect.NewAuthServiceHandler(authSvc, opts))
	mux.Handle(clarkv1connect.NewModelProvidersServiceHandler(modelProvidersSvc, opts))
	mux.Handle(clarkv1connect.NewProfilesServiceHandler(profilesSvc, opts))
	mux.Handle(clarkv1connect.NewConversationsServiceHandler(conversationsSvc, opts))
	mux.Handle(clarkv1connect.NewStreamsServiceHandler(streamsSvc, opts))

	srv := &http.Server{
		Addr:    addr,
		Handler: h2c.NewHandler(mux, &http2.Server{}),
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("clarkd listening", "addr", addr)
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
