package stream

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jdpedrie/clark/internal/providers"
)

// shrinkRetryConfigForTest swaps the package-global retry vars to
// millisecond-scale so the loop runs in real-time-but-fast. Restored on
// cleanup.
func shrinkRetryConfigForTest(t *testing.T, attempts int, attemptTimeout time.Duration) {
	t.Helper()
	prevAttempts := MaxSendAttempts
	prevTimeout := PerAttemptTimeout
	prevBackoff := InitialBackoff
	MaxSendAttempts = attempts
	PerAttemptTimeout = attemptTimeout
	InitialBackoff = 1 * time.Millisecond
	t.Cleanup(func() {
		MaxSendAttempts = prevAttempts
		PerAttemptTimeout = prevTimeout
		InitialBackoff = prevBackoff
	})
}

// makeStreamWithChunks: closed channel pre-loaded with the given
// chunks plus a Done. Used to simulate "Send produced a complete
// stream immediately."
func makeStreamWithChunks(chunks ...providers.Chunk) <-chan providers.Chunk {
	ch := make(chan providers.Chunk, len(chunks)+1)
	for _, c := range chunks {
		ch <- c
	}
	ch <- providers.Chunk{Type: providers.ChunkDone, Payload: []byte("{}")}
	close(ch)
	return ch
}

// scriptedSend builds a SendFunc whose attempt-N behaviour comes from
// `script`. Tracks call count for assertions.
type scriptedSend struct {
	calls  atomic.Int32
	script func(attempt int) (<-chan providers.Chunk, error)
}

func (s *scriptedSend) fn() SendFunc {
	return func(_ context.Context) (<-chan providers.Chunk, error) {
		n := int(s.calls.Add(1))
		return s.script(n)
	}
}

// TestOpenStreamRetry_TransientRecovery: SendFunc fails twice (with
// retriable errors), succeeds on the third attempt. The helper should
// return the successful stream — and the call count proves we actually
// retried.
func TestOpenStreamRetry_TransientRecovery(t *testing.T) {
	shrinkRetryConfigForTest(t, 3, 200*time.Millisecond)

	s := &scriptedSend{}
	s.script = func(attempt int) (<-chan providers.Chunk, error) {
		if attempt < 3 {
			return nil, errors.New("upstream busy")
		}
		return makeStreamWithChunks(
			providers.Chunk{Type: providers.ChunkText, Payload: []byte(`{"text":"hi"}`)},
		), nil
	}

	res, err := openStreamWithRetry(context.Background(), s.fn(), slog.Default())
	if err != nil {
		t.Fatalf("expected success after retry; got %v", err)
	}
	defer res.cancel()
	if got := s.calls.Load(); got != 3 {
		t.Errorf("Send called %d times; want 3", got)
	}
	if res.first.Type != providers.ChunkText {
		t.Errorf("first chunk type %q want text_delta", res.first.Type)
	}
}

// TestOpenStreamRetry_Exhausted: SendFunc fails on every attempt. After
// MaxSendAttempts the helper gives up.
func TestOpenStreamRetry_Exhausted(t *testing.T) {
	shrinkRetryConfigForTest(t, 3, 200*time.Millisecond)

	s := &scriptedSend{}
	s.script = func(int) (<-chan providers.Chunk, error) {
		return nil, errors.New("permanently broken")
	}

	if _, err := openStreamWithRetry(context.Background(), s.fn(), slog.Default()); err == nil {
		t.Fatal("expected error after exhaustion")
	}
	if got := s.calls.Load(); got != 3 {
		t.Errorf("Send called %d times; want 3", got)
	}
}

// TestOpenStreamRetry_FirstChunkTimeout: SendFunc returns a channel
// that never produces. Per-attempt timeout fires; the helper retries;
// all attempts time out; the helper surfaces a timeout error.
func TestOpenStreamRetry_FirstChunkTimeout(t *testing.T) {
	shrinkRetryConfigForTest(t, 3, 50*time.Millisecond)

	s := &scriptedSend{}
	s.script = func(int) (<-chan providers.Chunk, error) {
		return make(chan providers.Chunk), nil
	}

	start := time.Now()
	_, err := openStreamWithRetry(context.Background(), s.fn(), slog.Default())
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected timeout error")
	}
	if got := s.calls.Load(); got != 3 {
		t.Errorf("Send called %d times; want 3", got)
	}
	if elapsed < 100*time.Millisecond {
		t.Errorf("retry loop returned suspiciously fast (%v) — timeout may not be firing", elapsed)
	}
}

// TestOpenStreamRetry_FirstChunkArrivesJustInTime: SendFunc returns
// successfully and the channel produces a chunk just before the
// timeout. Should accept the chunk and return success on the first
// attempt — no retry, the upstream is healthy.
func TestOpenStreamRetry_FirstChunkArrivesJustInTime(t *testing.T) {
	shrinkRetryConfigForTest(t, 3, 200*time.Millisecond)

	s := &scriptedSend{}
	s.script = func(int) (<-chan providers.Chunk, error) {
		ch := make(chan providers.Chunk, 2)
		go func() {
			time.Sleep(50 * time.Millisecond)
			ch <- providers.Chunk{Type: providers.ChunkText, Payload: []byte(`{"text":"x"}`)}
			ch <- providers.Chunk{Type: providers.ChunkDone, Payload: []byte("{}")}
			close(ch)
		}()
		return ch, nil
	}

	res, err := openStreamWithRetry(context.Background(), s.fn(), slog.Default())
	if err != nil {
		t.Fatalf("expected success; got %v", err)
	}
	defer res.cancel()
	if got := s.calls.Load(); got != 1 {
		t.Errorf("Send called %d times; want 1 (no retry needed)", got)
	}
}

// TestSyntheticErrorStream: the synthetic stream emitted on retry
// exhaustion produces error+done in the supervisor's expected shape.
func TestSyntheticErrorStream(t *testing.T) {
	t.Parallel()
	ch := syntheticErrorStream(errors.New("boom"))

	var got []providers.Chunk
	for c := range ch {
		got = append(got, c)
	}
	if len(got) != 2 {
		t.Fatalf("got %d chunks; want 2 (error, done)", len(got))
	}
	if got[0].Type != providers.ChunkError {
		t.Errorf("chunk[0].type %q want error", got[0].Type)
	}
	if got[1].Type != providers.ChunkDone {
		t.Errorf("chunk[1].type %q want done", got[1].Type)
	}
	var ep struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(got[0].Payload, &ep); err != nil {
		t.Fatalf("unmarshal error payload: %v", err)
	}
	if ep.Message != "boom" {
		t.Errorf("error payload message=%q want boom", ep.Message)
	}
}

// TestReinjectFirstChunk: bridge emits the first chunk, then the rest,
// then closes — and runs the cancel func when done.
func TestReinjectFirstChunk(t *testing.T) {
	t.Parallel()

	var cancelled atomic.Bool
	stream := make(chan providers.Chunk, 2)
	stream <- providers.Chunk{Type: providers.ChunkText, Payload: []byte(`{"text":"second"}`)}
	stream <- providers.Chunk{Type: providers.ChunkDone, Payload: []byte("{}")}
	close(stream)

	first := providers.Chunk{Type: providers.ChunkText, Payload: []byte(`{"text":"first"}`)}
	merged := reinjectFirstChunk(&sentSourceResult{
		first:  first,
		stream: stream,
		cancel: func() { cancelled.Store(true) },
	})

	var got []providers.Chunk
	for c := range merged {
		got = append(got, c)
	}
	if len(got) != 3 {
		t.Fatalf("got %d chunks; want 3", len(got))
	}
	if got[0].Type != providers.ChunkText || string(got[0].Payload) != `{"text":"first"}` {
		t.Errorf("chunk[0] not the re-injected first; got %+v", got[0])
	}
	if !cancelled.Load() {
		t.Error("cancel func should have fired when stream closed")
	}
}
