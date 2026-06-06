package embeddings

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/pgvector/pgvector-go"
)

// Resolver returns the Embedder configured for a given user, or
// ErrNoEmbedderForUser if the user hasn't configured one. The Worker
// uses it to pick the right embedder per message batch; the Searcher
// uses it for per-query embedding. Caching is the resolver's
// responsibility — Worker calls Resolve repeatedly during steady
// state, so a non-cached implementation will hammer the DB.
type Resolver interface {
	Resolve(ctx context.Context, userID uuid.UUID) (Embedder, error)
}

// ErrNoEmbedderForUser is the sentinel a Resolver returns when the
// user hasn't configured an embedder (no user_embedder_config row,
// or the row has enabled=false). The worker treats these messages
// as "skip for now" — they get picked up the next time around if
// the user configures one.
var ErrNoEmbedderForUser = errors.New("embeddings: no embedder configured for user")

// Worker runs an embedding loop: it polls `messages` for unembedded
// rows, groups them by owner, asks the Resolver for that owner's
// Embedder, and writes the resulting vectors back.
//
// Polling-not-pushed by design — the partial
// `messages_unembedded_created_at` index makes the lookup query free
// even on a million-row catalogue. The Resolver layer means each
// user can choose their own embedder (real OpenAI for one,
// nomic-embed-text via Ollama for another) and the worker still
// fans out from a single goroutine.
type Worker struct {
	pool     *pgxpool.Pool
	q        *store.Queries
	resolver Resolver
	cfg      WorkerConfig
	log      *slog.Logger
}

// WorkerConfig is the tunable shape. Zero values pick sensible
// defaults so callers can NewWorker with `WorkerConfig{}` and get a
// working loop.
type WorkerConfig struct {
	// BatchSize is the number of messages fetched per poll. The
	// worker groups them by user; each user-group is then handed
	// to that user's embedder as one batched Embed call. Default
	// 32. Larger batches give better throughput but worse
	// cancellation latency; 32 is a good compromise on CPU.
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
func NewWorker(pool *pgxpool.Pool, resolver Resolver, cfg WorkerConfig, log *slog.Logger) *Worker {
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
		resolver: resolver,
		cfg:      cfg,
		log:      log.With("component", "embeddings.worker"),
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
		if !sleep(ctx, w.cfg.BusyInterval) {
			return
		}
	}
}

// RunOnce processes a single batch and returns the count embedded.
// Returns (0, nil) when there's nothing to do or when no user in
// the batch has an embedder configured. Exported so tests can drive
// the worker deterministically without managing the loop.
func (w *Worker) RunOnce(ctx context.Context) (int, error) {
	rows, err := w.q.ListUnembeddedMessages(ctx, int32(w.cfg.BatchSize))
	if err != nil {
		return 0, fmt.Errorf("list unembedded: %w", err)
	}
	if len(rows) == 0 {
		return 0, nil
	}

	// The query already ORDER BYs user_id, so consecutive rows
	// with the same owner are adjacent. Walk the slice and
	// flush per-owner groups as we cross boundaries — saves a
	// second pass over the rows just to bucket them.
	written := 0
	var batch []store.ListUnembeddedMessagesRow
	var currentUser uuid.UUID
	flush := func() {
		if len(batch) == 0 {
			return
		}
		got, err := w.embedUserBatch(ctx, currentUser, batch)
		if err != nil {
			if errors.Is(err, ErrNoEmbedderForUser) {
				// Skip silently — this is the steady-state for
				// users who haven't opted into embeddings yet.
				return
			}
			w.log.Warn("embed batch for user failed; will retry next loop",
				"user_id", currentUser, "size", len(batch), "error", err)
			return
		}
		written += got
	}
	for _, r := range rows {
		if r.UserID != currentUser {
			flush()
			currentUser = r.UserID
			batch = batch[:0]
		}
		batch = append(batch, r)
	}
	flush()
	return written, nil
}

// embedUserBatch is the per-owner inner loop. Resolves the user's
// Embedder, calls it on the group's contents, writes results back.
func (w *Worker) embedUserBatch(ctx context.Context, userID uuid.UUID, rows []store.ListUnembeddedMessagesRow) (int, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	embedder, err := w.resolver.Resolve(ctx, userID)
	if err != nil {
		return 0, err
	}
	inputs := make([]string, len(rows))
	for i, r := range rows {
		inputs[i] = r.Content
	}
	vectors, err := embedder.Embed(ctx, inputs)
	if err != nil {
		return 0, fmt.Errorf("embed: %w", err)
	}
	if len(vectors) != len(rows) {
		return 0, fmt.Errorf("embedder returned %d vectors for %d inputs",
			len(vectors), len(rows))
	}
	model := embedder.Model()
	now := time.Now().UTC()
	written := 0
	for i, r := range rows {
		v := pgvector.NewVector(vectors[i])
		if err := w.writeOne(ctx, r.ID, v, model, now); err != nil {
			w.log.Warn("embedding write failed; will retry on next pass",
				"message_id", r.ID, "error", err)
			continue
		}
		written++
	}
	return written, nil
}

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

// --- StaticResolver: the simple cache that wraps a single Embedder ---

// StaticResolver returns the same Embedder for every user. Useful
// when REEVE_EMBEDDER configures a server-wide default — every user
// shares one embedder instance and there's no per-user lookup.
// Tests use this too.
type StaticResolver struct {
	Embedder Embedder
}

func (s StaticResolver) Resolve(_ context.Context, _ uuid.UUID) (Embedder, error) {
	if s.Embedder == nil {
		return nil, ErrNoEmbedderForUser
	}
	return s.Embedder, nil
}

// --- CachingResolver: per-user with a build function + invalidation ---

// CachingResolver builds embedders on demand and caches them per
// user. Build is called once per user, and again only after a
// matching Invalidate call (e.g. the user updated their config). All
// the database / decrypt machinery lives in the Build closure;
// CachingResolver itself is sync-primitive housekeeping.
type CachingResolver struct {
	// Build constructs the user's Embedder. Return
	// (nil, ErrNoEmbedderForUser) when the user has no config —
	// the cache skips populating in that case.
	Build func(ctx context.Context, userID uuid.UUID) (Embedder, error)

	mu    sync.Mutex
	cache map[uuid.UUID]Embedder
}

func (c *CachingResolver) Resolve(ctx context.Context, userID uuid.UUID) (Embedder, error) {
	c.mu.Lock()
	if c.cache != nil {
		if e, ok := c.cache[userID]; ok {
			c.mu.Unlock()
			return e, nil
		}
	}
	c.mu.Unlock()

	// Build outside the lock so a slow upstream (Ollama down,
	// real OpenAI slow) doesn't block other users' Resolves.
	e, err := c.Build(ctx, userID)
	if err != nil {
		return nil, err
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cache == nil {
		c.cache = map[uuid.UUID]Embedder{}
	}
	c.cache[userID] = e
	return e, nil
}

// Invalidate drops the cached Embedder for a user — call from the
// SetEmbedderConfig RPC handler so the next batch picks up the new
// config without a process restart.
func (c *CachingResolver) Invalidate(userID uuid.UUID) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.cache, userID)
}
