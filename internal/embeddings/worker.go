package embeddings

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/pgvector/pgvector-go"
)

// Worker runs an embedding loop: it polls `messages` for unembedded
// rows, hands a batch to the configured Embedder, and writes the
// resulting vectors back via SetMessageEmbedding.
//
// Polling-not-pushed by design — the partial
// `messages_unembedded_created_at` index makes the lookup query free
// even on a million-row catalogue, and a single-user dogfood deploy
// doesn't need the complexity of an in-process queue + nudge channel
// to absorb stream bursts. The worker idles between polls when there's
// nothing to do.
//
// When the active embedder changes (a different Model()), the
// model-swap path is symmetric: ListMessagesEmbeddedUnderDifferentModel
// finds rows still on the old model and re-embeds them under the new
// one. That's the same `embed-and-write-back` loop pointed at a
// different query, so callers wire either via the same Worker by
// changing what FetchBatch returns.
type Worker struct {
	pool     *pgxpool.Pool
	q        *store.Queries
	embedder Embedder
	cfg      WorkerConfig
	log      *slog.Logger
}

// WorkerConfig is the tunable shape. Zero values pick sensible
// defaults so callers can NewWorker with `WorkerConfig{}` and get a
// working loop.
type WorkerConfig struct {
	// BatchSize is the number of messages to embed per Ollama call.
	// Default 32. Ollama batches efficiently up to a few hundred,
	// but smaller batches give better cancellation latency and
	// smoother memory.
	BatchSize int

	// IdleInterval is how long the loop sleeps when there are no
	// unembedded rows to process. Default 10s.
	IdleInterval time.Duration

	// BusyInterval is the tiny sleep between back-to-back full
	// batches — lets a Run() loop yield CPU when racing against
	// a heavy ingest. Default 100ms.
	BusyInterval time.Duration
}

// NewWorker wires the dependencies. Doesn't start the loop — call
// Run(ctx) from a goroutine when you want it running.
func NewWorker(pool *pgxpool.Pool, embedder Embedder, cfg WorkerConfig, log *slog.Logger) *Worker {
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = 32
	}
	if cfg.IdleInterval <= 0 {
		cfg.IdleInterval = 10 * time.Second
	}
	if cfg.BusyInterval < 0 {
		cfg.BusyInterval = 0
	}
	if cfg.BusyInterval == 0 {
		cfg.BusyInterval = 100 * time.Millisecond
	}
	if log == nil {
		log = slog.Default()
	}
	return &Worker{
		pool:     pool,
		q:        store.New(pool),
		embedder: embedder,
		cfg:      cfg,
		log:      log.With("component", "embeddings.worker", "model", embedder.Model()),
	}
}

// Run loops forever, terminating only when ctx is cancelled. Errors
// during a single batch are logged and the loop continues — a flaky
// embedder shouldn't be able to kill the worker. (A persistent error
// will spam logs; if that becomes painful add exponential backoff.)
func (w *Worker) Run(ctx context.Context) {
	w.log.Info("embedding worker started",
		"batch_size", w.cfg.BatchSize,
		"idle_interval", w.cfg.IdleInterval)
	defer w.log.Info("embedding worker stopped")

	for {
		if ctx.Err() != nil {
			return
		}
		n, err := w.RunOnce(ctx)
		if err != nil {
			// Polling Postgres or talking to the embedder failed.
			// Log and sleep; next iteration tries again. Don't
			// propagate — the daemon stays up.
			w.log.Warn("embedding batch failed", "error", err)
			if !sleep(ctx, w.cfg.IdleInterval) {
				return
			}
			continue
		}
		if n == 0 {
			if !sleep(ctx, w.cfg.IdleInterval) {
				return
			}
			continue
		}
		// Made progress; brief yield before the next batch so a heavy
		// backfill doesn't starve other goroutines on a small box.
		if !sleep(ctx, w.cfg.BusyInterval) {
			return
		}
	}
}

// RunOnce processes a single batch and returns the count embedded.
// Returns (0, nil) when there's nothing to do. Exported so tests can
// drive the worker deterministically without managing the loop, and
// so an admin RPC could one-shot it.
func (w *Worker) RunOnce(ctx context.Context) (int, error) {
	rows, err := w.q.ListUnembeddedMessages(ctx, int32(w.cfg.BatchSize))
	if err != nil {
		return 0, fmt.Errorf("list unembedded: %w", err)
	}
	if len(rows) == 0 {
		return 0, nil
	}
	return w.embedBatch(ctx, rows)
}

// embedBatch is shared by RunOnce and the model-swap path. It receives
// the (id, content) rows to embed, fires one Embedder call, writes
// each vector back. Returns the count actually written — a partial
// write-failure is surfaced as the count so the caller can tell how
// far they got.
func (w *Worker) embedBatch(ctx context.Context, rows []store.ListUnembeddedMessagesRow) (int, error) {
	inputs := make([]string, len(rows))
	for i, r := range rows {
		inputs[i] = r.Content
	}
	vectors, err := w.embedder.Embed(ctx, inputs)
	if err != nil {
		return 0, fmt.Errorf("embed: %w", err)
	}
	if len(vectors) != len(rows) {
		return 0, fmt.Errorf("embedder returned %d vectors for %d inputs",
			len(vectors), len(rows))
	}
	model := w.embedder.Model()
	now := time.Now().UTC()
	written := 0
	for i, r := range rows {
		v := pgvector.NewVector(vectors[i])
		if err := w.writeOne(ctx, r.ID, v, model, now); err != nil {
			w.log.Warn("embedding write failed; will retry on next pass",
				"message_id", r.ID, "error", err)
			// Don't bail the whole batch — log this one and keep
			// going. The unembedded predicate means the failed row
			// gets picked up again next loop.
			continue
		}
		written++
	}
	return written, nil
}

// writeOne writes a single embedding triple. Split out so the caller
// can swap in a transactional variant later; today the single-row
// UPDATE is atomic and rollback-free already.
func (w *Worker) writeOne(ctx context.Context, id uuid.UUID, v pgvector.Vector, model string, at time.Time) error {
	mdl := model
	t := at
	return w.q.SetMessageEmbedding(ctx, store.SetMessageEmbeddingParams{
		ID:             id,
		Embedding:      &v,
		EmbeddingModel: &mdl,
		EmbeddingAt:    &t,
	})
}

// sleep is context-aware. Returns false when ctx is done so the caller
// can break out of the loop without a stray Sleep on shutdown.
func sleep(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return ctx.Err() == nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
