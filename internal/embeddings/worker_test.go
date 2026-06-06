package embeddings_test

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jdpedrie/reeve/internal/embeddings"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/testutil"
)

// stubEmbedder is a deterministic Embedder: returns a 3-d unit vector
// padded with zeros to 768 dims (matching the messages column). Tracks
// each call so tests can assert batching/order.
type stubEmbedder struct {
	mu       sync.Mutex
	model    string
	dim      int
	calls    [][]string
	failNext atomic.Bool
}

func newStub(model string) *stubEmbedder {
	return &stubEmbedder{model: model, dim: 768}
}

func (s *stubEmbedder) Model() string   { return s.model }
func (s *stubEmbedder) Dimensions() int { return s.dim }

func (s *stubEmbedder) Embed(_ context.Context, inputs []string) ([][]float32, error) {
	if s.failNext.Swap(false) {
		return nil, errors.New("induced embed failure")
	}
	s.mu.Lock()
	s.calls = append(s.calls, append([]string(nil), inputs...))
	s.mu.Unlock()
	out := make([][]float32, len(inputs))
	for i, in := range inputs {
		v := make([]float32, s.dim)
		// Reproducible per-input pattern.
		v[0] = float32(len(in))
		out[i] = v
	}
	return out, nil
}

// workerFixture is the worker-specific counterpart to the integration
// fixture in store_integration_test.go. Embedding tests need messages
// in the DB; this builds them via the same minimal seeding flow.
type workerFixture struct {
	pool   *pgxpool.Pool
	q      *store.Queries
	userID uuid.UUID
	cxID   uuid.UUID
	msgs   []store.Message
}

func newWorkerFixture(t *testing.T, contents []string) (*workerFixture, *embeddings.Worker, *stubEmbedder) {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()

	u, err := q.CreateUser(ctx, store.CreateUserParams{
		ID: uuid.New(), Username: "worker-test-" + uuid.NewString()[:8], PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	p, err := q.CreateProfile(ctx, store.CreateProfileParams{
		ID: uuid.New(), UserID: u.ID, Name: "worker",
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	tt := "worker"
	c, err := q.CreateConversation(ctx, store.CreateConversationParams{
		ID: uuid.New(), UserID: u.ID, ProfileID: p.ID, Title: &tt,
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	cx, err := q.CreateContext(ctx, store.CreateContextParams{
		ID: uuid.New(), ConversationID: c.ID, ContextActivationTime: time.Now().UTC(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	msgs := make([]store.Message, 0, len(contents))
	var parent *uuid.UUID
	for _, body := range contents {
		m, err := q.CreateMessage(ctx, store.CreateMessageParams{
			ID: uuid.New(), ContextID: cx.ID, ParentID: parent,
			Role: "user", Content: body,
		})
		if err != nil {
			t.Fatalf("CreateMessage: %v", err)
		}
		msgs = append(msgs, m)
		id := m.ID
		parent = &id
	}

	stub := newStub("stub-v1")
	w := embeddings.NewWorker(pool, embeddings.StaticResolver{Embedder: stub}, embeddings.WorkerConfig{
		BatchSize:    16,
		IdleInterval: 20 * time.Millisecond,
		BusyInterval: 1 * time.Millisecond,
	}, nil)
	return &workerFixture{pool: pool, q: q, userID: u.ID, cxID: cx.ID, msgs: msgs}, w, stub
}

func TestWorker_RunOnceEmbedsPendingRows(t *testing.T) {
	t.Parallel()
	f, w, stub := newWorkerFixture(t, []string{
		"hello", "world", "this is a test message",
	})

	got, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if got != len(f.msgs) {
		t.Errorf("embedded count=%d want %d", got, len(f.msgs))
	}

	// Stub should have been called once with all three inputs.
	if len(stub.calls) != 1 {
		t.Fatalf("stub call count=%d, want 1", len(stub.calls))
	}
	if len(stub.calls[0]) != len(f.msgs) {
		t.Errorf("first batch size=%d, want %d", len(stub.calls[0]), len(f.msgs))
	}

	// After the run, ListUnembeddedMessages should be empty.
	remaining, err := f.q.ListUnembeddedMessages(context.Background(), 100)
	if err != nil {
		t.Fatalf("ListUnembedded: %v", err)
	}
	if len(remaining) != 0 {
		t.Errorf("worker left %d rows unembedded", len(remaining))
	}
}

func TestWorker_RunOnceNoopWhenEmpty(t *testing.T) {
	t.Parallel()
	_, w, stub := newWorkerFixture(t, nil)
	n, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if n != 0 {
		t.Errorf("empty queue returned n=%d", n)
	}
	if len(stub.calls) != 0 {
		t.Errorf("stub called on empty queue")
	}
}

func TestWorker_EmbedderErrorRecovers_RowsStayUnembedded(t *testing.T) {
	t.Parallel()
	f, w, stub := newWorkerFixture(t, []string{"alpha", "beta"})

	// First call fails inside the per-user batch — Worker logs it
	// and moves on. RunOnce doesn't surface a hard error because
	// other users' batches might still have succeeded; what
	// matters is that the failed rows stay in the unembedded
	// queue for next-loop retry.
	stub.failNext.Store(true)
	if _, err := w.RunOnce(context.Background()); err != nil {
		t.Errorf("RunOnce should swallow per-user embed errors, got %v", err)
	}
	remaining, err := f.q.ListUnembeddedMessages(context.Background(), 100)
	if err != nil {
		t.Fatalf("ListUnembedded: %v", err)
	}
	if len(remaining) != 2 {
		t.Errorf("failed embed left %d rows; want 2 (both still pending)", len(remaining))
	}

	// Second call succeeds.
	if got, err := w.RunOnce(context.Background()); err != nil || got != 2 {
		t.Errorf("recovery RunOnce got=%d err=%v want got=2 err=nil", got, err)
	}
	remaining, _ = f.q.ListUnembeddedMessages(context.Background(), 100)
	if len(remaining) != 0 {
		t.Errorf("retry left %d unembedded", len(remaining))
	}
}

func TestWorker_RunLoopTerminatesOnContextCancel(t *testing.T) {
	t.Parallel()
	_, w, _ := newWorkerFixture(t, []string{"a", "b"})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		w.Run(ctx)
		close(done)
	}()
	// Give Run a tick to start, then cancel. Should return promptly.
	time.Sleep(10 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return within 2s of cancel")
	}
}

func TestWorker_BatchSizeRespected(t *testing.T) {
	t.Parallel()
	// Five messages, batch size 2 → first batch is 2.
	f, _, stub := newWorkerFixture(t, []string{"m1", "m2", "m3", "m4", "m5"})

	// Re-construct the worker with batch 2 against the SAME pool so it
	// sees the fixture's seeded rows. (Each testutil.Pool(t) is a
	// fresh isolated DB — passing the fixture's pool keeps the data
	// visible to both workers.)
	w := embeddings.NewWorker(f.pool, embeddings.StaticResolver{Embedder: stub},
		embeddings.WorkerConfig{BatchSize: 2}, nil)

	// First RunOnce → 2 embedded.
	n, err := w.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if n != 2 {
		t.Errorf("first batch n=%d want 2", n)
	}
}
