// Package stream implements the producer-consumer stream supervisor described
// in docs/architecture.md ("Streaming subsystem"). Each in-flight LLM stream
// is owned by a goroutine that consumes the upstream provider channel,
// persists chunks in batches to Postgres, fans them out to in-process
// subscribers, and materializes a final assistant message when the stream
// terminates.
//
// This is the load-bearing component for iOS-app-backgrounding resilience:
// the server reads the upstream to completion regardless of client state, and
// clients can disconnect/reconnect freely by replaying persisted chunks then
// switching to the live broker.
//
// Package boundaries:
//   - This package owns chunk persistence and fan-out.
//   - It does NOT call the driver itself. The caller (a future SendMessage
//     handler) builds the prefix, calls provider.Send, and hands the
//     resulting <-chan providers.Chunk to Supervisor.Start.
//   - It does NOT build prefixes, run transforms, or talk to providers.
package stream

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/plugins"
)

// StreamPurpose distinguishes assistant-response runs from compression runs.
// They share the chunk-streaming machinery but differ in materialization:
// assistant_response inserts a message into the existing context;
// compression's eventual home is a new context with a role=context summary
// (Round 3 wiring — see materializeCompression).
type StreamPurpose string

const (
	PurposeAssistantResponse StreamPurpose = "assistant_response"
	PurposeCompression       StreamPurpose = "compression"
)

// Tunables. Exposed for test override.
var (
	// flushInterval and flushBatchSize control chunk-persistence granularity.
	// We flush whichever fires first. Values match the architecture doc's
	// "50ms / 16 chunks" guidance.
	//
	// Chunk-loss window: up to ~flushInterval / flushBatchSize chunks may be
	// lost on a process crash mid-batch. Acceptable per the architecture doc:
	// a server-restart-mid-stream produces an `interrupted` run that the user
	// must retry anyway, so optimizing for finer-grained durability buys
	// nothing.
	flushInterval  = 50 * time.Millisecond
	flushBatchSize = 16

	// subscriberBuffer is the per-subscriber channel buffer size. If a slow
	// subscriber fills its buffer the broker drops the subscriber (closes
	// their channel) rather than blocking the supervisor. The subscriber may
	// resubscribe with the last sequence they received.
	subscriberBuffer = 64
)

// run statuses. Mirror the DB CHECK constraint.
const (
	statusRunning     = "running"
	statusCompleted   = "completed"
	statusErrored     = "errored"
	statusCancelled   = "cancelled"
	statusInterrupted = "interrupted"
)

// Chunk is a sequence-tagged provider chunk as emitted to subscribers and
// persisted in stream_chunks.
type Chunk struct {
	Sequence int64
	Type     providers.ChunkType
	Payload  []byte
}

// SubscribeEvent is one item on the channel returned by Subscribe. Exactly
// one of Chunk or Terminal is non-nil per event. The terminal event is sent
// once at the end of the stream (just before the channel closes) and carries
// the final stream_run row.
type SubscribeEvent struct {
	Chunk    *Chunk
	Terminal *store.StreamRun
}

// CompressionMode controls how compression materialization composes the new
// Context's role=context message. Only meaningful for Purpose=Compression runs.
type CompressionMode string

const (
	// CompressionModeReplace makes the new context's role=context message
	// content the summary alone. Prior framing does not carry over.
	CompressionModeReplace CompressionMode = "REPLACE"
	// CompressionModeAppend chains the prior role=context content forward,
	// appending the new summary. Framing accumulates across compressions.
	CompressionModeAppend CompressionMode = "APPEND"
)

// StartParams is the input to Supervisor.Start.
type StartParams struct {
	ConversationID  uuid.UUID
	ContextID       uuid.UUID
	ParentMessageID *uuid.UUID
	ProviderID      uuid.UUID
	ModelID         string
	Purpose         StreamPurpose

	// CompressionMode is only consulted when Purpose=PurposeCompression.
	// Defaults to REPLACE when unset.
	CompressionMode CompressionMode

	// Source is the live channel from the driver. The supervisor owns
	// reading from this channel for the run's lifetime; the caller must not
	// concurrently read from it after handing it over. Either Source or
	// SendFunc must be set; SendFunc takes precedence (it's the path that
	// gets retry + per-attempt 60s timeout). Source remains for tests +
	// callers that don't want retry semantics.
	Source <-chan providers.Chunk

	// SendFunc opens the upstream stream. The supervisor calls it inside
	// its run goroutine with retry + per-attempt 60s timeout (see
	// openStreamWithRetry). On exhaustion the supervisor materialises an
	// errored assistant message — the user's typed text is never lost.
	// Mutually exclusive with Source.
	SendFunc SendFunc

	// Provider is the constructed driver instance. The supervisor uses it at
	// materialization to populate thinking_provider_type (`Provider.Type()`)
	// and thinking_rendered_text (`Provider.RenderThinkingToText`) on the
	// assistant message row. Optional: nil falls back to dropping both
	// columns to NULL — the same behaviour as before this hook existed.
	Provider providers.Provider

	// ExplicitCacheAttached records whether Reeve attached an explicit
	// Gemini cachedContents reference to the request that produced this
	// run. Stamped onto the materialized assistant message's
	// explicit_cache_attached column for forensics. nil → don't write
	// the column (non-google driver, toggle off, or this surface
	// doesn't apply); &true → cache attached; &false → toggle was on
	// but no cache was attached (most commonly: prefix below the
	// per-model minimum).
	ExplicitCacheAttached *bool

	// Pipeline is the resolved chat-plugin pipeline for this run.
	// Threaded into the supervisor so materialization can apply
	// AssistantContentTransformer (rewrite content before insert) and
	// fire MessageLifecycleHook (post-insert, in detached goroutines).
	// Optional: nil pipeline = no plugin transforms / no lifecycle
	// hooks fired.
	Pipeline plugins.Pipeline

	// OnAssistantMaterialized fires after the assistant row is
	// inserted, with the new message id. Per-run hook (in
	// addition to Supervisor.onAssistantMaterialized) — the
	// conversations service uses it to persist tool-result
	// attachments accumulated during the tool loop, since those
	// have to bind to the just-inserted message id. Runs in the
	// supervisor's goroutine after materialization completes;
	// errors are logged and don't propagate.
	OnAssistantMaterialized func(ctx context.Context, assistantMsgID uuid.UUID)
}

// ErrNotFound is returned by Get/Subscribe/Cancel when the run doesn't
// exist. Wrap-compatible via errors.Is.
var ErrNotFound = errors.New("stream run not found")

// AssistantMaterializedHook is invoked, in a fresh detached goroutine, after
// the supervisor successfully materializes an assistant message at the end
// of a PurposeAssistantResponse run. params is the run's StartParams (so
// callbacks can resolve provider/conversation/context); messageID is the
// just-inserted assistant message row.
//
// Used for cross-cutting post-materialization work that the supervisor
// shouldn't own directly — e.g. triggering auto-title generation, sending
// push notifications. Errors inside the callback are the callback's
// responsibility; the supervisor doesn't propagate them.
type AssistantMaterializedHook func(ctx context.Context, params StartParams, messageID uuid.UUID)

// Supervisor manages in-flight stream runs.
type Supervisor struct {
	queries *store.Queries
	logger  *slog.Logger

	// onAssistantMaterialized, if set, fires after each successful
	// materialization of an assistant message. See AssistantMaterializedHook.
	onAssistantMaterialized AssistantMaterializedHook

	// runs holds the per-run live state for runs whose supervisor goroutine
	// is currently active. Keyed by run ID. Entries are removed in the
	// goroutine's defer after subscribers are closed.
	runs sync.Map // uuid.UUID -> *runState
}

// New constructs a Supervisor.
// SetOnAssistantMaterialized installs a hook called after each successful
// assistant-message materialization. Pass nil to clear. Wired by the
// conversations service at server startup so it can trigger auto-title
// generation without the supervisor needing to know about catalog/profile
// concerns.
func (s *Supervisor) SetOnAssistantMaterialized(cb AssistantMaterializedHook) {
	s.onAssistantMaterialized = cb
}

func New(queries *store.Queries, logger *slog.Logger) *Supervisor {
	if logger == nil {
		logger = slog.Default()
	}
	return &Supervisor{queries: queries, logger: logger}
}

// runState is the per-run live broker + cancel handle held in Supervisor.runs
// while a stream is in flight.
type runState struct {
	mu sync.Mutex

	// subscribers holds live subscriber channels. Owned by the broker.
	// Subscribers are added on registration, removed when the broker drops
	// them (slow consumer) or when the supervisor finalizes (close-all).
	subscribers []chan SubscribeEvent

	// terminated flips true once the supervisor goroutine has finished
	// finalization (or is about to). Subscribers attempting to register
	// after this flip are rejected; they get the terminal event +
	// channel close synchronously by Subscribe.
	terminated bool
	terminal   *store.StreamRun // set when terminated == true

	// cancelRequested indicates Cancel() was called. The supervisor reads
	// it under the mutex when picking its terminal status. Must be set
	// before invoking cancel().
	cancelRequested bool

	// cancel cancels the supervisor goroutine's context, which closes the
	// upstream stream (providers honor ctx). Used by Supervisor.Cancel.
	cancel context.CancelFunc

	// fanoutCursor is the highest chunk sequence the broker has fanned out
	// so far. -1 means "nothing fanned yet." Used by Subscribe to bound the
	// gap-fill DB read so it cannot include chunks the broker is about to
	// fan out (which would cause duplicate delivery). Updated under mu after
	// each fanout batch.
	fanoutCursor int64
}

// Start kicks off a new stream run. Synchronously creates the stream_runs
// row and spawns the supervisor goroutine. Returns the new run ID
// immediately so the caller can return it to the client.
//
// Start uses ctx only for the initial INSERT. The supervisor goroutine
// derives its own context (rooted in context.Background, cancellable via
// Cancel) so that an iOS client that fires the request and immediately
// backgrounds — cancelling its own context — does not stop the upstream
// consumer.
func (s *Supervisor) Start(ctx context.Context, params StartParams) (uuid.UUID, error) {
	if params.Source == nil && params.SendFunc == nil {
		return uuid.Nil, errors.New("stream: must set either Source or SendFunc")
	}
	switch params.Purpose {
	case PurposeAssistantResponse, PurposeCompression:
	default:
		return uuid.Nil, fmt.Errorf("stream: unknown purpose %q", params.Purpose)
	}

	id, err := uuid.NewV7()
	if err != nil {
		return uuid.Nil, fmt.Errorf("stream: generate run id: %w", err)
	}
	providerIDForInsert := params.ProviderID
	if _, err := s.queries.CreateStreamRun(ctx, store.CreateStreamRunParams{
		ID:              id,
		ConversationID:  params.ConversationID,
		ContextID:       params.ContextID,
		ParentMessageID: params.ParentMessageID,
		ProviderID:      &providerIDForInsert,
		ModelID:         params.ModelID,
		Status:          statusRunning,
		Purpose:         string(params.Purpose),
	}); err != nil {
		return uuid.Nil, fmt.Errorf("stream: create run: %w", err)
	}

	// Detached context — see Start docstring.
	runCtx, cancel := context.WithCancel(context.Background())
	rs := &runState{cancel: cancel, fanoutCursor: -1}
	s.runs.Store(id, rs)

	go s.consume(runCtx, id, params, rs)

	return id, nil
}

// Subscribe replays persisted chunks from fromSequence forward, then either
// live-tails the broker (if the run is still running) or sends the terminal
// event and closes (if already terminal). Closes the returned channel when
// the run terminates or ctx is cancelled.
//
// fromSequence semantics: pass 0 to receive the entire run from the start.
// Pass `lastSeen + 1` to resume after a transient disconnect.
//
// Backpressure: the returned channel has a small buffer (subscriberBuffer).
// If the consumer falls behind and the buffer fills while the broker is
// fanning out a chunk, the broker drops this subscriber — the channel is
// closed early without a terminal event. The consumer should detect
// close-without-terminal as "I fell behind" and resubscribe with the last
// sequence they received.
func (s *Supervisor) Subscribe(ctx context.Context, runID uuid.UUID, fromSequence int64) (<-chan SubscribeEvent, error) {
	persistedRun, err := s.queries.GetStreamRunByID(ctx, runID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("stream: run %s: %w", runID, ErrNotFound)
		}
		return nil, fmt.Errorf("stream: load run %s: %w", runID, err)
	}

	out := make(chan SubscribeEvent, subscriberBuffer)
	go s.subscribe(ctx, runID, fromSequence, persistedRun, out)
	return out, nil
}

// subscribe is the goroutine body for Subscribe. It:
//  1. Looks up the live runState. If the run already terminated, sends the
//     terminal event from the persisted row (replay handled by the caller's
//     re-subscribe; once a run is dead it stays in the DB).
//  2. Otherwise: takes the broker lock and atomically (a) reads the current
//     fanoutCursor, (b) replays persisted chunks in [fromSequence, cursor]
//     to the subscriber, and (c) registers the subscriber with the broker.
//     Anything > cursor will reach the subscriber via live broker fan-out.
//
// The "everything under one lock" shape prevents the duplicate-delivery race:
// without the lock, the broker could fan out chunks N..M to other subscribers
// (advancing its internal cursor) between our DB read and our registration —
// then re-deliver those same chunks to us via fan-out post-registration,
// even though we already saw them in DB.
//
// On client disconnect mid-stream we deregister so the broker stops fanning
// to us; the broker will still close the channel when it finalizes (or skip
// us if we already removed ourselves).
func (s *Supervisor) subscribe(ctx context.Context, runID uuid.UUID, fromSequence int64, persistedRun store.StreamRun, out chan SubscribeEvent) {
	defer func() {
		// Recover-safety: never leak the channel open.
		if r := recover(); r != nil {
			s.logger.Error("stream subscribe panic", "run_id", runID, "recover", r)
			safeClose(out)
		}
	}()

	// If the run is no longer live (broker goroutine deleted its runState
	// after finalize), short-circuit to a terminal-from-DB delivery.
	rsAny, ok := s.runs.Load(runID)
	if !ok {
		// Replay then terminal — the broker isn't going to fan anything else
		// out, so all events will come from DB.
		s.replayPersistedChunks(ctx, runID, fromSequence, out)
		s.sendTerminal(ctx, persistedRun, out)
		return
	}
	rs := rsAny.(*runState)

	// Live path. Hold the broker lock for the entire replay+register window.
	// While we hold the lock the broker cannot fan out new chunks, so the
	// chunks we read from DB up to fanoutCursor are exactly the chunks the
	// broker has already delivered (to other subscribers) — and the chunks
	// after fanoutCursor are reserved for live fan-out, which will reach us
	// because we register before releasing.
	rs.mu.Lock()
	if rs.terminated {
		t := persistedRun
		if rs.terminal != nil {
			t = *rs.terminal
		}
		rs.mu.Unlock()
		// Replay any chunks the subscriber missed before they
		// reconnected — without this, a client that dropped mid-stream
		// and retried just as the run terminated would receive Terminal
		// with a half-built buffer, and its UI would briefly show
		// stale-partial content before the chain reload reveals the
		// full materialised assistant turn.
		s.replayPersistedChunks(ctx, runID, fromSequence, out)
		s.sendTerminal(ctx, t, out)
		return
	}
	cursor := rs.fanoutCursor

	if cursor >= fromSequence {
		rows, err := s.queries.ListStreamChunks(ctx, store.ListStreamChunksParams{
			StreamRunID: runID,
			Sequence:    fromSequence,
		})
		if err != nil {
			rs.mu.Unlock()
			s.logger.Error("stream replay failed", "run_id", runID, "err", err)
			safeClose(out)
			return
		}
		for _, row := range rows {
			if row.Sequence > cursor {
				break // rest belong to the live broker.
			}
			ev := SubscribeEvent{Chunk: &Chunk{
				Sequence: row.Sequence,
				Type:     providers.ChunkType(row.ChunkType),
				Payload:  row.Payload,
			}}
			select {
			case out <- ev:
			default:
				// Slow consumer — bail before joining broker so the
				// broker never sees us.
				rs.mu.Unlock()
				safeClose(out)
				return
			}
		}
	}

	// Register; broker fan-outs after this point start at cursor+1.
	rs.subscribers = append(rs.subscribers, out)
	rs.mu.Unlock()

	// Wait for ctx cancellation. Broker sends + close are handled in the
	// supervisor goroutine. On client disconnect, deregister so the
	// broker stops fanning out to a dead consumer; the broker will close
	// the channel on its own when it finalizes (or skip us if we already
	// removed ourselves; close is keyed on broker's own list).
	<-ctx.Done()
	rs.removeSubscriber(out)
	// On client cancel mid-stream we close the channel ourselves so the
	// caller's range loop exits. removeSubscriber prevents a double-close
	// from the broker.
	safeClose(out)
}

// sendTerminal sends the terminal event for an already-finalized run and
// closes out.
func (s *Supervisor) sendTerminal(ctx context.Context, r store.StreamRun, out chan SubscribeEvent) {
	defer safeClose(out)
	rcopy := r
	sendOrCancel(ctx, out, SubscribeEvent{Terminal: &rcopy})
}

// replayPersistedChunks forwards every persisted chunk with
// `sequence >= fromSequence` from `stream_chunks` to out. Used by both
// terminal-from-DB branches of `subscribe` so a re-subscribing client
// receives whatever it missed before the run terminated, instead of
// jumping straight to Terminal with a half-built local buffer. A send
// failure (slow consumer / cancelled ctx) closes out and returns; the
// caller MUST NOT close out again.
//
// Best-effort: a DB read error is logged and treated as "no chunks to
// replay" so the run still terminates cleanly on the client.
func (s *Supervisor) replayPersistedChunks(ctx context.Context, runID uuid.UUID, fromSequence int64, out chan SubscribeEvent) {
	rows, err := s.queries.ListStreamChunks(ctx, store.ListStreamChunksParams{
		StreamRunID: runID,
		Sequence:    fromSequence,
	})
	if err != nil {
		s.logger.Error("stream replay failed", "run_id", runID, "err", err)
		return
	}
	for _, row := range rows {
		ev := SubscribeEvent{Chunk: &Chunk{
			Sequence: row.Sequence,
			Type:     providers.ChunkType(row.ChunkType),
			Payload:  row.Payload,
		}}
		if !sendOrCancel(ctx, out, ev) {
			return
		}
	}
}

// removeSubscriber drops ch from the broker. Idempotent.
func (rs *runState) removeSubscriber(ch chan SubscribeEvent) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	rs.removeLocked(ch)
}

// removeLocked must be called with rs.mu held.
func (rs *runState) removeLocked(ch chan SubscribeEvent) {
	for i, c := range rs.subscribers {
		if c == ch {
			rs.subscribers = append(rs.subscribers[:i], rs.subscribers[i+1:]...)
			return
		}
	}
}

// sendOrCancel sends ev to out, returning false if ctx was cancelled first.
func sendOrCancel(ctx context.Context, out chan SubscribeEvent, ev SubscribeEvent) bool {
	select {
	case out <- ev:
		return true
	case <-ctx.Done():
		return false
	}
}

// safeClose closes ch if it's still open. Recovers from the close-of-closed
// panic so multiple coordination paths can defensively close.
func safeClose(ch chan SubscribeEvent) {
	defer func() { _ = recover() }()
	close(ch)
}

// Cancel marks an in-flight run as cancelled and stops the upstream
// consumer. The supervisor goroutine will materialize whatever was
// assembled with status=cancelled. Idempotent — calling Cancel on a
// terminal run returns nil.
func (s *Supervisor) Cancel(ctx context.Context, runID uuid.UUID) error {
	if rsAny, ok := s.runs.Load(runID); ok {
		rs := rsAny.(*runState)
		// cancelRequested must be set before invoking cancel so the
		// supervisor's terminal-status decision sees it.
		rs.mu.Lock()
		rs.cancelRequested = true
		rs.mu.Unlock()
		rs.cancel()
		return nil
	}
	if _, err := s.queries.GetStreamRunByID(ctx, runID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("stream: run %s: %w", runID, ErrNotFound)
		}
		return fmt.Errorf("stream: load run %s: %w", runID, err)
	}
	return nil
}

// Get returns the current state of a stream run.
func (s *Supervisor) Get(ctx context.Context, runID uuid.UUID) (store.StreamRun, error) {
	r, err := s.queries.GetStreamRunByID(ctx, runID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return store.StreamRun{}, fmt.Errorf("stream: run %s: %w", runID, ErrNotFound)
		}
		return store.StreamRun{}, err
	}
	return r, nil
}

// RecoverInterrupted scans for stream_runs in 'running' state at startup
// and flips them to 'interrupted'. Call once during server boot — the
// upstream sockets died with the process and can't be resumed.
func (s *Supervisor) RecoverInterrupted(ctx context.Context) error {
	if err := s.queries.MarkRunningAsInterrupted(ctx); err != nil {
		return fmt.Errorf("stream: recover interrupted runs: %w", err)
	}
	return nil
}

// chunkErrorPayload is the JSON shape we persist into stream_runs.error_payload
// when an upstream ChunkError terminates a run.
type chunkErrorPayload struct {
	Message string          `json:"message"`
	Raw     json.RawMessage `json:"raw,omitempty"`
}

// thinkingBlock is what materialization writes into messages.thinking when
// any thinking_delta chunks were observed. Single concatenated block — see
// "Materialization" in the task description.
type thinkingBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// chunkTextPayload / chunkThinkingPayload — minimal payload shapes used to
// extract delta text. Drivers send richer JSON; we only need the .text
// field, and tolerate other fields. Bytes that don't unmarshal as a JSON
// object are treated as raw strings (back-compat / future-proof).
type deltaPayload struct {
	Text string `json:"text"`
}

// extractDeltaText pulls the .text field out of a chunk payload. Tolerant of
// missing field / non-object payloads (returns "").
func extractDeltaText(payload json.RawMessage) string {
	if len(payload) == 0 {
		return ""
	}
	var dp deltaPayload
	if err := json.Unmarshal(payload, &dp); err == nil && dp.Text != "" {
		return dp.Text
	}
	// Fallback: try as bare string.
	var s string
	if err := json.Unmarshal(payload, &s); err == nil {
		return s
	}
	return ""
}
