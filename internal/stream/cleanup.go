package stream

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/jdpedrie/spalt/internal/store"
)

// Default cleanup parameters. Retention is the safety window AFTER a
// stream finalizes during which we keep its chunks around — covers
// late reconnects (a flaky mobile client coming back well after a
// stream wrapped up). Sweep interval is how often the housekeeping
// goroutine runs; chosen to keep the DB-side scan light while still
// reclaiming space within an hour or so of expiry.
const (
	DefaultChunkRetention      = time.Hour
	DefaultChunkSweepInterval  = 10 * time.Minute
	chunkSweepShutdownDeadline = 30 * time.Second
)

// CleanupConfig configures the stream-chunk cleanup goroutine.
type CleanupConfig struct {
	// Retention is how long after a stream_run finalizes we keep its
	// chunks. Pruned rows can no longer satisfy late SubscribeStream
	// reconnects, so set this comfortably larger than the longest
	// expected client-side network outage.
	Retention time.Duration
	// SweepInterval is how often the goroutine runs. Each tick fires
	// one indexed DB delete; setting this very low burns DB cycles
	// without much benefit.
	SweepInterval time.Duration
}

// StartChunkCleanup launches a background goroutine that periodically
// deletes stream_chunks belonging to stream_runs finalized more than
// `cfg.Retention` ago. Returns the cancel func; call it on shutdown
// to stop the loop. The goroutine logs each non-zero sweep at info
// level and any error at error level; zero-row sweeps are silent.
//
// Survives across server restarts naturally — the cleanup is keyed on
// stream_runs.ended_at, not on per-run timers, so chunks orphaned by a
// crash mid-finalization get swept on the next tick after their row's
// ended_at falls outside the retention window.
func StartChunkCleanup(ctx context.Context, queries *store.Queries, cfg CleanupConfig, logger *slog.Logger) context.CancelFunc {
	if cfg.Retention <= 0 {
		cfg.Retention = DefaultChunkRetention
	}
	if cfg.SweepInterval <= 0 {
		cfg.SweepInterval = DefaultChunkSweepInterval
	}
	if logger == nil {
		logger = slog.Default()
	}

	loopCtx, cancel := context.WithCancel(ctx)
	go runChunkCleanupLoop(loopCtx, queries, cfg, logger.With("component", "chunk_cleanup"))
	return cancel
}

func runChunkCleanupLoop(ctx context.Context, queries *store.Queries, cfg CleanupConfig, logger *slog.Logger) {
	logger.Info("stream-chunk cleanup goroutine started",
		"retention", cfg.Retention.String(),
		"sweep_interval", cfg.SweepInterval.String())

	ticker := time.NewTicker(cfg.SweepInterval)
	defer ticker.Stop()

	// Run one sweep immediately on startup — covers chunks that aged
	// out while the server was down.
	sweepOnce(ctx, queries, cfg.Retention, logger)

	for {
		select {
		case <-ctx.Done():
			logger.Info("stream-chunk cleanup goroutine stopping")
			return
		case <-ticker.C:
			sweepOnce(ctx, queries, cfg.Retention, logger)
		}
	}
}

// sweepOnce runs one prune query. Uses a per-call timeout so a slow DB
// can't block the next scheduled tick (the next iteration just kicks
// off a fresh attempt). Errors are logged and swallowed — the loop
// keeps going.
func sweepOnce(ctx context.Context, queries *store.Queries, retention time.Duration, logger *slog.Logger) {
	sweepCtx, cancel := context.WithTimeout(ctx, chunkSweepShutdownDeadline)
	defer cancel()

	interval := pgtype.Interval{
		Microseconds: retention.Microseconds(),
		Valid:        true,
	}
	rows, err := queries.PruneFinalizedStreamChunks(sweepCtx, interval)
	if err != nil {
		logger.Error("prune finalized stream chunks failed", "err", err)
		return
	}
	if rows > 0 {
		logger.Info("stream-chunks pruned", "rows", rows)
	}
}
