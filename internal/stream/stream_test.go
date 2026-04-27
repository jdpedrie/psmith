package stream

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/clark/internal/providers"
	"github.com/jdpedrie/clark/internal/store"
	"github.com/jdpedrie/clark/internal/testutil"
)

// --- Fixtures --------------------------------------------------------------

type fixture struct {
	q      *store.Queries
	sup    *Supervisor
	user   store.User
	prov   store.UserModelProvider
	conv   store.Conversation
	ctx    store.Context
	parent uuid.UUID // parent message id (a placeholder user message)
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	pool := testutil.Pool(t)
	q := store.New(pool)

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	sup := New(q, logger)

	bg := context.Background()

	userID := mustUUID(t)
	user, err := q.CreateUser(bg, store.CreateUserParams{
		ID:           userID,
		Username:     "u-" + userID.String()[:8],
		PasswordHash: "x",
	})
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	provID := mustUUID(t)
	prov, err := q.CreateUserModelProvider(bg, store.CreateUserModelProviderParams{
		ID:     provID,
		UserID: user.ID,
		Type:   "openai-compatible",
		Label:  "test",
		Config: []byte(`{}`),
	})
	if err != nil {
		t.Fatalf("CreateUserModelProvider: %v", err)
	}

	profID := mustUUID(t)
	prof, err := q.CreateProfile(bg, store.CreateProfileParams{
		ID:     profID,
		UserID: user.ID,
		Name:   "p",
	})
	if err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	convID := mustUUID(t)
	conv, err := q.CreateConversation(bg, store.CreateConversationParams{
		ID:        convID,
		UserID:    user.ID,
		ProfileID: prof.ID,
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}

	cctxID := mustUUID(t)
	cctx, err := q.CreateContext(bg, store.CreateContextParams{
		ID:                    cctxID,
		ConversationID:        conv.ID,
		ContextActivationTime: time.Now(),
	})
	if err != nil {
		t.Fatalf("CreateContext: %v", err)
	}

	parentID := mustUUID(t)
	if _, err := q.CreateMessage(bg, store.CreateMessageParams{
		ID:        parentID,
		ContextID: cctx.ID,
		Role:      "user",
		Content:   "hello",
	}); err != nil {
		t.Fatalf("CreateMessage(parent): %v", err)
	}

	return &fixture{
		q:      q,
		sup:    sup,
		user:   user,
		prov:   prov,
		conv:   conv,
		ctx:    cctx,
		parent: parentID,
	}
}

func mustUUID(t *testing.T) uuid.UUID {
	t.Helper()
	id, err := uuid.NewV7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	return id
}

// fakeSource emits canned chunks on demand. Caller drives it via push() and
// closes via close().
type fakeSource struct {
	ch chan providers.Chunk
}

func newFakeSource(buffer int) *fakeSource {
	return &fakeSource{ch: make(chan providers.Chunk, buffer)}
}

func (f *fakeSource) push(c providers.Chunk) { f.ch <- c }
func (f *fakeSource) close()                 { close(f.ch) }
func (f *fakeSource) recv() <-chan providers.Chunk {
	return f.ch
}

// startParams builds a StartParams for the fixture targeting an
// assistant-response run.
func (f *fixture) startParams(src <-chan providers.Chunk, purpose StreamPurpose) StartParams {
	parent := f.parent
	return StartParams{
		ConversationID:  f.conv.ID,
		ContextID:       f.ctx.ID,
		ParentMessageID: &parent,
		ProviderID:      f.prov.ID,
		ModelID:         "gpt-test",
		Purpose:         purpose,
		Source:          src,
	}
}

// textChunk builds a text_delta chunk with the canonical {"text":"…"} payload.
func textChunk(s string) providers.Chunk {
	pl, _ := json.Marshal(map[string]string{"text": s})
	return providers.Chunk{Type: providers.ChunkText, Payload: pl}
}

func thinkingChunk(s string) providers.Chunk {
	pl, _ := json.Marshal(map[string]string{"text": s})
	return providers.Chunk{Type: providers.ChunkThinking, Payload: pl}
}

func errorChunk(msg string) providers.Chunk {
	pl, _ := json.Marshal(map[string]string{"text": msg})
	return providers.Chunk{Type: providers.ChunkError, Payload: pl}
}

// waitFor polls cond until true or timeout. Useful where we'd otherwise need
// to busy-wait on the supervisor's async finalization.
func waitFor(t *testing.T, cond func() bool, timeout time.Duration, msg string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("waitFor timeout: %s", msg)
}

// drainAll reads events from sub until it closes or timeout, returning all
// chunks (in order) and the terminal event (or nil if none).
func drainAll(t *testing.T, sub <-chan SubscribeEvent, timeout time.Duration) ([]Chunk, *store.StreamRun) {
	t.Helper()
	var chunks []Chunk
	var terminal *store.StreamRun
	deadline := time.After(timeout)
	for {
		select {
		case ev, ok := <-sub:
			if !ok {
				return chunks, terminal
			}
			if ev.Chunk != nil {
				chunks = append(chunks, *ev.Chunk)
			}
			if ev.Terminal != nil {
				terminal = ev.Terminal
			}
		case <-deadline:
			t.Fatalf("drainAll timeout (got %d chunks, terminal=%v)", len(chunks), terminal != nil)
			return chunks, terminal
		}
	}
}

// --- Tests -----------------------------------------------------------------

func TestStart_PersistsChunksMonotonically(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(8)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	src.push(textChunk("a"))
	src.push(textChunk("b"))
	src.push(textChunk("c"))
	src.close()

	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusCompleted
	}, 2*time.Second, "run completed")

	rows, err := f.q.ListStreamChunks(context.Background(), store.ListStreamChunksParams{
		StreamRunID: runID,
		Sequence:    0,
	})
	if err != nil {
		t.Fatalf("ListStreamChunks: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 persisted chunks, got %d", len(rows))
	}
	for i, r := range rows {
		if r.Sequence != int64(i) {
			t.Errorf("row %d sequence = %d, want %d", i, r.Sequence, i)
		}
		if r.ChunkType != string(providers.ChunkText) {
			t.Errorf("row %d type = %s", i, r.ChunkType)
		}
	}
}

func TestSubscribe_AfterCompletion_Replays(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(8)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	src.push(textChunk("hello "))
	src.push(textChunk("world"))
	src.close()

	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusCompleted
	}, 2*time.Second, "run completed")

	sub, err := f.sup.Subscribe(context.Background(), runID, 0)
	if err != nil {
		t.Fatalf("Subscribe: %v", err)
	}
	chunks, terminal := drainAll(t, sub, 2*time.Second)

	if len(chunks) != 2 {
		t.Fatalf("expected 2 replayed chunks, got %d", len(chunks))
	}
	if string(chunks[0].Payload) == "" || string(chunks[1].Payload) == "" {
		t.Errorf("payload missing")
	}
	if terminal == nil || terminal.Status != statusCompleted {
		t.Fatalf("expected terminal with status completed, got %+v", terminal)
	}
}

func TestSubscribe_LiveTail_OrderedThenTerminal(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(0) // unbuffered to force interleaving

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	sub, err := f.sup.Subscribe(context.Background(), runID, 0)
	if err != nil {
		t.Fatalf("Subscribe: %v", err)
	}

	// Feed chunks from a separate goroutine so the test can drain the
	// subscriber concurrently.
	go func() {
		src.push(textChunk("alpha "))
		src.push(textChunk("beta "))
		src.push(textChunk("gamma"))
		src.close()
	}()

	chunks, terminal := drainAll(t, sub, 3*time.Second)
	if len(chunks) != 3 {
		t.Fatalf("expected 3 chunks, got %d", len(chunks))
	}
	for i, c := range chunks {
		if c.Sequence != int64(i) {
			t.Errorf("chunk %d sequence = %d", i, c.Sequence)
		}
	}
	if terminal == nil || terminal.Status != statusCompleted {
		t.Fatalf("terminal missing or wrong status: %+v", terminal)
	}
}

func TestSubscribe_TwoConcurrent_BothReceiveAll(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(8)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	sub1, err := f.sup.Subscribe(context.Background(), runID, 0)
	if err != nil {
		t.Fatalf("Subscribe(1): %v", err)
	}
	sub2, err := f.sup.Subscribe(context.Background(), runID, 0)
	if err != nil {
		t.Fatalf("Subscribe(2): %v", err)
	}

	go func() {
		for i := 0; i < 5; i++ {
			src.push(textChunk("x"))
		}
		src.close()
	}()

	var (
		wg               sync.WaitGroup
		chunks1, chunks2 []Chunk
		term1, term2     *store.StreamRun
	)
	wg.Add(2)
	go func() {
		defer wg.Done()
		chunks1, term1 = drainAll(t, sub1, 3*time.Second)
	}()
	go func() {
		defer wg.Done()
		chunks2, term2 = drainAll(t, sub2, 3*time.Second)
	}()
	wg.Wait()

	if len(chunks1) != 5 || len(chunks2) != 5 {
		t.Fatalf("subscriber1=%d subscriber2=%d, want 5 each", len(chunks1), len(chunks2))
	}
	if term1 == nil || term2 == nil {
		t.Fatalf("missing terminal: t1=%v t2=%v", term1, term2)
	}
}

func TestSubscribe_NonexistentRun(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.sup.Subscribe(context.Background(), uuid.Must(uuid.NewV7()), 0)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestCancel_InFlight_MaterializesPartial(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(0)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Push a few chunks and let them flush before cancelling.
	src.push(textChunk("partial "))
	src.push(textChunk("content"))

	// Wait for them to land in DB (flush interval is 50ms).
	waitFor(t, func() bool {
		max, _ := f.q.MaxStreamChunkSequence(context.Background(), runID)
		return max >= 1
	}, 2*time.Second, "chunks flushed")

	if err := f.sup.Cancel(context.Background(), runID); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	// Cancel closes the run's ctx, which causes the supervisor to drain
	// Source non-blockingly and finalize. We must close Source ourselves
	// here since fakeSource doesn't honor ctx.
	go src.close()

	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusCancelled
	}, 2*time.Second, "run cancelled")

	r, err := f.sup.Get(context.Background(), runID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if r.ResultMessageID == nil {
		t.Fatalf("expected materialized message id")
	}
	msg, err := f.q.GetMessageByID(context.Background(), *r.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	if msg.Content != "partial content" {
		t.Errorf("content = %q, want %q", msg.Content, "partial content")
	}
	if msg.Role != "assistant" {
		t.Errorf("role = %q", msg.Role)
	}
}

func TestSourceClean_Completes_WithThinking(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(8)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	src.push(thinkingChunk("let me think... "))
	src.push(thinkingChunk("ok "))
	src.push(textChunk("the answer is "))
	src.push(textChunk("42"))
	src.close()

	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusCompleted
	}, 2*time.Second, "run completed")

	r, err := f.sup.Get(context.Background(), runID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if r.ResultMessageID == nil {
		t.Fatal("expected result_message_id")
	}
	msg, err := f.q.GetMessageByID(context.Background(), *r.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	if msg.Content != "the answer is 42" {
		t.Errorf("content = %q", msg.Content)
	}
	if len(msg.Thinking) == 0 {
		t.Fatal("thinking JSON empty")
	}
	var blocks []map[string]any
	if err := json.Unmarshal(msg.Thinking, &blocks); err != nil {
		t.Fatalf("decode thinking: %v", err)
	}
	if len(blocks) != 1 || blocks[0]["text"] != "let me think... ok " {
		t.Errorf("thinking blocks: %+v", blocks)
	}
}

func TestChunkError_MidStream_PartialMaterialized(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(8)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	src.push(textChunk("starting "))
	src.push(errorChunk("provider blew up"))
	src.close()

	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusErrored
	}, 2*time.Second, "run errored")

	r, err := f.sup.Get(context.Background(), runID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(r.ErrorPayload) == 0 {
		t.Fatal("expected error_payload populated")
	}
	var ep chunkErrorPayload
	if err := json.Unmarshal(r.ErrorPayload, &ep); err != nil {
		t.Fatalf("decode error payload: %v", err)
	}
	if ep.Message != "provider blew up" {
		t.Errorf("message = %q", ep.Message)
	}
	if r.ResultMessageID == nil {
		t.Fatal("expected partial message materialized")
	}
	msg, err := f.q.GetMessageByID(context.Background(), *r.ResultMessageID)
	if err != nil {
		t.Fatalf("GetMessageByID: %v", err)
	}
	if msg.Content != "starting " {
		t.Errorf("content = %q", msg.Content)
	}
}

func TestRecoverInterrupted(t *testing.T) {
	t.Parallel()
	f := newFixture(t)

	runID := mustUUID(t)
	parent := f.parent
	if _, err := f.q.CreateStreamRun(context.Background(), store.CreateStreamRunParams{
		ID:              runID,
		ConversationID:  f.conv.ID,
		ContextID:       f.ctx.ID,
		ParentMessageID: &parent,
		ProviderID:      f.prov.ID,
		ModelID:         "gpt-test",
		Status:          statusRunning,
		Purpose:         string(PurposeAssistantResponse),
	}); err != nil {
		t.Fatalf("seed run: %v", err)
	}

	if err := f.sup.RecoverInterrupted(context.Background()); err != nil {
		t.Fatalf("RecoverInterrupted: %v", err)
	}

	r, err := f.sup.Get(context.Background(), runID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if r.Status != statusInterrupted {
		t.Errorf("status = %q, want %q", r.Status, statusInterrupted)
	}
	if r.EndedAt == nil {
		t.Errorf("ended_at should be set")
	}
}

func TestGet_Unknown_ReturnsErrNotFound(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	_, err := f.sup.Get(context.Background(), uuid.Must(uuid.NewV7()))
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestCancel_AlreadyCompleted_Idempotent(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(4)

	runID, err := f.sup.Start(context.Background(), f.startParams(src.recv(), PurposeAssistantResponse))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	src.push(textChunk("done"))
	src.close()

	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusCompleted
	}, 2*time.Second, "completed")

	// Cancel after completion should be a no-op.
	if err := f.sup.Cancel(context.Background(), runID); err != nil {
		t.Fatalf("Cancel after completion: %v", err)
	}
	r, _ := f.sup.Get(context.Background(), runID)
	if r.Status != statusCompleted {
		t.Errorf("status changed after late Cancel: %q", r.Status)
	}
}

func TestCancel_Unknown_ReturnsErrNotFound(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	err := f.sup.Cancel(context.Background(), uuid.Must(uuid.NewV7()))
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

// TestStart_Compression_MaterializesSummaryOnly — post the two-stage
// reshape, the supervisor's PurposeCompression path writes ONLY the
// compression_summary row in the source context. New-context creation now
// happens via ConversationsService.PromoteCompactionToNewContext (a
// user-driven second step).
func TestStart_Compression_MaterializesSummaryOnly(t *testing.T) {
	t.Parallel()
	f := newFixture(t)
	src := newFakeSource(4)

	params := f.startParams(src.recv(), PurposeCompression)
	runID, err := f.sup.Start(context.Background(), params)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	src.push(textChunk("compressed summary"))
	src.close()

	waitFor(t, func() bool {
		r, _ := f.sup.Get(context.Background(), runID)
		return r.Status == statusCompleted
	}, 2*time.Second, "compression completed")

	r, _ := f.sup.Get(context.Background(), runID)
	if r.ResultMessageID == nil {
		t.Fatal("expected result_message_id (compression_summary) to be set")
	}
	if r.ResultContextID != nil {
		t.Errorf("result_context_id should be NULL (no new context until promote); got %s", *r.ResultContextID)
	}

	summary, err := f.q.GetMessageByID(context.Background(), *r.ResultMessageID)
	if err != nil {
		t.Fatalf("fetch compression_summary: %v", err)
	}
	if summary.Role != "compression_summary" {
		t.Errorf("expected role=compression_summary, got %q", summary.Role)
	}
	if summary.Content != "compressed summary" {
		t.Errorf("summary content mismatch: %q", summary.Content)
	}
	if summary.ContextID != f.ctx.ID {
		t.Errorf("summary should live in source context (%s), got %s", f.ctx.ID, summary.ContextID)
	}

	// No new context was created.
	all, err := f.q.ListContextsByConversation(context.Background(), f.conv.ID)
	if err != nil {
		t.Fatalf("ListContextsByConversation: %v", err)
	}
	if len(all) != 1 {
		t.Errorf("expected 1 context post-compression (the source); got %d", len(all))
	}

	// Chunks still persisted.
	rows, err := f.q.ListStreamChunks(context.Background(), store.ListStreamChunksParams{
		StreamRunID: runID,
	})
	if err != nil {
		t.Fatalf("ListStreamChunks: %v", err)
	}
	if len(rows) != 1 {
		t.Errorf("expected 1 persisted chunk, got %d", len(rows))
	}
}
