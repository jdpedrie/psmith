package stream

import (
	"context"
	"testing"
	"time"
)

// A stopped compression's summary carries finish_reason user_cancelled, as
// a stopped reply does, so the clients can say "Summary stopped" instead of
// offering a partial summary as finished.
func TestCompressionCancelled_MarksTheSummaryStopped(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(0)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeCompression))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	src.push(textChunk("half a "))
	src.push(textChunk("summary"))
	waitFor(t, func() bool {
		max, _ := f.q.MaxStreamChunkSequence(context.Background(), runID)
		return max >= 1
	}, 2*time.Second, "chunks flushed")
	if err := f.sup.Cancel(context.Background(), runID); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	go src.close()
	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusCancelled
	}, 2*time.Second, "run cancelled")

	r, _ := f.sup.Get(context.Background(), runID)
	if r.ResultMessageID == nil {
		t.Fatal("expected the partial summary to be kept")
	}
	summary, err := f.q.GetMessageByID(context.Background(), *r.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	if summary.Role != "compression_summary" || summary.Content != "half a summary" {
		t.Errorf("summary = %s %q", summary.Role, summary.Content)
	}
	if summary.FinishReason == nil || *summary.FinishReason != "user_cancelled" {
		t.Errorf("finish_reason = %v, want user_cancelled", summary.FinishReason)
	}
}
