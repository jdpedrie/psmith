package stream

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jdpedrie/reeve/internal/providers"
)

// Send retry / first-chunk timeout policy for upstream stream-opening.
// Vars (not consts) so tests can shrink to milliseconds without
// patching production behaviour.
//
// The architecture doc's "Streaming subsystem" section calls for
// transparent retry on pre-first-token failures (network blips, 5xx,
// rate limits) and a hard cap on how long an attempt can spend before
// producing a chunk. These vars codify both.
var (
	// MaxSendAttempts: how many times the supervisor calls SendFunc
	// before surfacing the failure as an errored assistant message. 3
	// covers a transient blip without making the user wait ages on a
	// permanently-broken upstream.
	MaxSendAttempts = 3

	// PerAttemptTimeout: the time each attempt has to (a) return from
	// the driver's Send call and (b) deliver the first chunk on the
	// returned channel. 60s is generous — most providers' first-byte
	// latency is sub-second; even thinking models start emitting
	// reasoning_summary deltas well under a minute. If we go past 60s
	// without ANY chunk, the upstream is almost certainly stuck and a
	// retry has better odds than continuing to wait.
	PerAttemptTimeout = 60 * time.Second

	// InitialBackoff: wait before the second attempt. Doubles each
	// subsequent retry (1s, 2s). 3 attempts → up to ~3s of pure
	// waiting between failures, plus up to 60s per attempt — worst
	// case ~3 minutes for the user-visible errored row to land.
	InitialBackoff = 1 * time.Second
)

// SendFunc opens an upstream stream. The supervisor calls it (with
// retry + timeout, see openStreamWithRetry) inside its run goroutine.
type SendFunc func(ctx context.Context) (<-chan providers.Chunk, error)

// sentSourceResult bundles a successfully-opened upstream stream's
// first chunk + remaining channel + the cancel func that controls the
// upstream HTTP context. The supervisor takes ownership of cancel and
// invokes it when streaming finishes so the SDK's underlying request
// cleans up.
type sentSourceResult struct {
	first  providers.Chunk
	stream <-chan providers.Chunk
	cancel context.CancelFunc
}

// openStreamWithRetry runs the SendFunc up to MaxSendAttempts times
// with exponential backoff, applying PerAttemptTimeout to each attempt
// as a single budget covering both the call AND the wait for the first
// chunk. Returns a successfully-opened stream (with the first chunk
// already consumed and ready for re-injection via reinjectFirstChunk)
// on success, or the last error on exhaustion.
//
// "Applicable failures" intentionally aren't classified — every error
// is retried. Permanent errors (auth, 4xx) burn through MaxSendAttempts
// in a few seconds; transient errors (5xx, network blips, rate limits)
// get up to two recoveries. The bound is the safety net.
func openStreamWithRetry(parent context.Context, sf SendFunc, logger *slog.Logger) (*sentSourceResult, error) {
	var lastErr error
	backoff := InitialBackoff
	for attempt := 1; attempt <= MaxSendAttempts; attempt++ {
		result, err := openOnce(parent, sf)
		if err == nil {
			return result, nil
		}
		lastErr = err
		if logger != nil {
			logger.Warn("upstream send attempt failed",
				"attempt", attempt,
				"max_attempts", MaxSendAttempts,
				"err", err)
		}
		if attempt == MaxSendAttempts {
			break
		}
		select {
		case <-time.After(backoff):
		case <-parent.Done():
			return nil, parent.Err()
		}
		backoff *= 2
	}
	return nil, fmt.Errorf("upstream send failed after %d attempts: %w", MaxSendAttempts, lastErr)
}

// openOnce: one attempt — call SendFunc with a PerAttemptTimeout
// deadline, wait for the first chunk under that same deadline, and (on
// success) hand the caller a result that owns the now-deadline-free
// continuation. Cancel is called for any error path.
func openOnce(parent context.Context, sf SendFunc) (*sentSourceResult, error) {
	attemptCtx, cancel := context.WithTimeout(parent, PerAttemptTimeout)
	ch, err := sf(attemptCtx)
	if err != nil {
		cancel()
		return nil, err
	}
	select {
	case first, ok := <-ch:
		if !ok {
			cancel()
			return nil, errors.New("upstream closed before first chunk")
		}
		// If the first thing the upstream produced is an error chunk,
		// the SDK swallowed an HTTP-level failure (4xx/5xx response
		// body, network reset before any data) and surfaced it via
		// the channel rather than the Send return. That counts as a
		// failed attempt — retry it. We pull the human-readable
		// message out of the chunk payload so the surfaced error is
		// useful (matches the stream supervisor's `chunkErrorPayload`
		// shape: `{"message": "..."}`).
		if first.Type == providers.ChunkError {
			cancel()
			go drainChannel(ch)
			return nil, errors.New(extractChunkErrorMessage(first))
		}
		// Success: caller takes ownership of cancel + remainder.
		return &sentSourceResult{first: first, stream: ch, cancel: cancel}, nil
	case <-attemptCtx.Done():
		cancel()
		// Drain async so the SDK doesn't block on a buffered send.
		go drainChannel(ch)
		if errors.Is(parent.Err(), context.Canceled) {
			return nil, parent.Err()
		}
		return nil, fmt.Errorf("timeout: no first chunk within %s", PerAttemptTimeout)
	}
}

func drainChannel(ch <-chan providers.Chunk) {
	for range ch {
	}
}

// extractChunkErrorMessage pulls the `.message` field out of a
// ChunkError payload. Drivers emit `{"message": "...", ...}` per the
// supervisor's chunkErrorPayload shape; a malformed payload falls back
// to a generic message rather than panicking.
func extractChunkErrorMessage(c providers.Chunk) string {
	var p struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(c.Payload, &p); err == nil && p.Message != "" {
		return p.Message
	}
	if len(c.Payload) > 0 {
		return string(c.Payload)
	}
	return "upstream returned error chunk"
}

// reinjectFirstChunk merges the first chunk + remainder into a single
// channel the supervisor's main consume loop reads uniformly. The
// goroutine forwards the first chunk, then bridges the original
// stream, then closes — and on close runs the cancel function so the
// upstream HTTP context is released.
func reinjectFirstChunk(result *sentSourceResult) <-chan providers.Chunk {
	out := make(chan providers.Chunk, 64)
	go func() {
		defer close(out)
		defer result.cancel()
		out <- result.first
		for c := range result.stream {
			out <- c
		}
	}()
	return out
}

// syntheticErrorStream returns a channel that emits a single
// ChunkError followed by a ChunkDone, then closes. Used when
// openStreamWithRetry exhausts all attempts — we want the supervisor's
// normal aggregator to materialise an errored assistant message (with
// the failure inline in `messages.error_payload`) instead of having
// the SendMessage RPC return a server error and lose the user's
// already-inserted row in the void.
func syntheticErrorStream(err error) <-chan providers.Chunk {
	out := make(chan providers.Chunk, 2)
	payload, _ := json.Marshal(map[string]string{"message": err.Error()})
	out <- providers.Chunk{Type: providers.ChunkError, Payload: payload}
	out <- providers.Chunk{Type: providers.ChunkDone, Payload: []byte("{}")}
	close(out)
	return out
}
