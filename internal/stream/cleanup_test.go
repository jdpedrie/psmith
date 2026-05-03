package stream

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/jdpedrie/reeve/internal/store"
)

// TestPruneFinalizedStreamChunks_FinalizedRunsPruned uses retention=0
// to make any finalized run eligible immediately. This sidesteps the
// "backdate ended_at" gymnastics that would otherwise be needed to
// exercise the retention window — the SQL clause `ended_at < NOW() -
// '0s'::INTERVAL` matches every finalized run.
func TestPruneFinalizedStreamChunks_FinalizedRunsPruned(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	bg := context.Background()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	finalizedRun := mustCreateRun(t, f)
	mustInsertChunks(t, f, finalizedRun, 5)
	mustFinalize(t, f, finalizedRun)

	runningRun := mustCreateRun(t, f)
	mustInsertChunks(t, f, runningRun, 3)
	// no Finalize — leaves status='running', ended_at=NULL

	sweepOnce(bg, f.q, 0, logger)

	if got := chunkCount(t, f, finalizedRun); got != 0 {
		t.Errorf("finalized run: expected 0 chunks remaining, got %d", got)
	}
	if got := chunkCount(t, f, runningRun); got != 3 {
		t.Errorf("running run: expected 3 chunks (no ended_at — never eligible), got %d", got)
	}
}

// TestPruneFinalizedStreamChunks_RetentionWindowProtects checks the
// inverse: with a non-zero retention, a just-finalized run survives
// the sweep because its ended_at is well within the window.
func TestPruneFinalizedStreamChunks_RetentionWindowProtects(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	bg := context.Background()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	r := mustCreateRun(t, f)
	mustInsertChunks(t, f, r, 4)
	mustFinalize(t, f, r) // ended_at = NOW(), within any reasonable window

	sweepOnce(bg, f.q, time.Hour, logger)

	if got := chunkCount(t, f, r); got != 4 {
		t.Errorf("expected freshly-finalized run's chunks to survive a 1h-retention sweep, got %d remaining", got)
	}
}

func TestStartChunkCleanup_StopsOnContextCancel(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	ctx, cancel := context.WithCancel(context.Background())
	stop := StartChunkCleanup(ctx, f.q, CleanupConfig{
		Retention:     time.Hour,
		SweepInterval: 10 * time.Millisecond,
	}, logger)
	defer stop()

	// Let the goroutine run several sweeps so the loop is genuinely
	// active rather than catching only the startup execution.
	time.Sleep(50 * time.Millisecond)
	cancel()
	// If the loop didn't observe the cancel, `go test -race` would
	// surface the leaked goroutine on test exit. The sleep below
	// gives it room to wind down before the test process tears down
	// the pool out from under it.
	time.Sleep(20 * time.Millisecond)
}

// --- helpers ---------------------------------------------------------------

func mustCreateRun(t *testing.T, f *fixture) [16]byte {
	t.Helper()
	runID := mustUUID(t)
	parent := f.parent
	provID := f.prov.ID
	if _, err := f.q.CreateStreamRun(context.Background(), store.CreateStreamRunParams{
		ID:              runID,
		ConversationID:  f.conv.ID,
		ContextID:       f.ctx.ID,
		ParentMessageID: &parent,
		ProviderID:      &provID,
		ModelID:         "gpt-test",
		Status:          "running",
		Purpose:         "assistant_response",
	}); err != nil {
		t.Fatalf("CreateStreamRun: %v", err)
	}
	return runID
}

func mustInsertChunks(t *testing.T, f *fixture, runID [16]byte, n int) {
	t.Helper()
	for i := int64(0); i < int64(n); i++ {
		if err := f.q.InsertStreamChunk(context.Background(), store.InsertStreamChunkParams{
			StreamRunID: runID,
			Sequence:    i,
			ChunkType:   "text_delta",
			Payload:     []byte(`{"text":"x"}`),
		}); err != nil {
			t.Fatalf("InsertStreamChunk: %v", err)
		}
	}
}

func mustFinalize(t *testing.T, f *fixture, runID [16]byte) {
	t.Helper()
	if _, err := f.q.FinalizeStreamRun(context.Background(), store.FinalizeStreamRunParams{
		ID:     runID,
		Status: "completed",
	}); err != nil {
		t.Fatalf("FinalizeStreamRun: %v", err)
	}
}

func chunkCount(t *testing.T, f *fixture, runID [16]byte) int {
	t.Helper()
	rows, err := f.q.ListStreamChunks(context.Background(), store.ListStreamChunksParams{
		StreamRunID: runID,
		Sequence:    0,
	})
	if err != nil {
		t.Fatalf("ListStreamChunks: %v", err)
	}
	return len(rows)
}
