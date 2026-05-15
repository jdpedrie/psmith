// Package langfuse is Reeve's Langfuse observability emitter.
//
// Wire shape: POST <host>/api/public/ingestion with HTTP basic auth
// (public_key:secret_key), body = a JSON envelope wrapping a list of
// "events". Each event has a `type` discriminator, an `id` (UUIDv7
// in our case so the timeline orders cleanly), a `timestamp`, and a
// `body` whose schema depends on the type.
//
// We emit two event types per Reeve assistant turn:
//
//   - trace-create  → opens the trace (the unit users browse in the
//     Langfuse UI). One per Reeve assistant turn. Carries the
//     conversation_id as session_id, so all turns from one chat
//     group together; tags + metadata carry context_id, profile_id,
//     model_id, provider_label.
//
//   - generation-create → the actual LLM call. Records input wire
//     prefix, output text, model_id, usage tokens, and the
//     pre-computed dollar cost. Sits inside the trace.
//
// The emitter buffers events and flushes asynchronously: every
// FlushInterval, when the buffer reaches FlushBatchSize, or when
// Stop is called. POST failures are logged at warn (no retries today
// — losing a few traces is a survivable degradation; a Reeve restart
// drops anything unflushed).
//
// Per-user credentials live on user_langfuse_config (one row per
// user). The supervisor hook resolves the calling user's row at
// emit time and skips emit when enabled=false or credentials are
// blank — the integration is fully opt-in and zero-overhead when
// not configured.
package langfuse

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Config carries the per-user Langfuse credentials + toggle. Mirrors
// the shape persisted in user_langfuse_config; the service layer
// decrypts SecretKey before constructing this.
type Config struct {
	Host      string
	PublicKey string
	SecretKey string
	Enabled   bool
}

// Valid reports whether the config is complete enough to attempt an
// emit. Empty credentials = silently disabled; the supervisor hook
// short-circuits without an error.
func (c Config) Valid() bool {
	return c.Enabled && c.Host != "" && c.PublicKey != "" && c.SecretKey != ""
}

// Trace describes a single Langfuse trace event. One per Reeve
// assistant turn. The fields are a subset of Langfuse's trace shape
// — we send the bits Reeve has data for, leave the rest unset.
type Trace struct {
	ID        string         // unique trace id (we use stream_run_id)
	Name      string         // human-friendly label, shown in the trace list
	UserID    string         // optional Langfuse user identity
	SessionID string         // groups traces in the UI; we use conversation_id
	Input     any            // marshaled to JSON; the wire prefix the model saw
	Output    string         // the assistant's final text
	StartTime time.Time
	EndTime   time.Time
	Metadata  map[string]any // arbitrary structured fields (context_id, profile_id, …)
	Tags      []string       // free-form labels users can filter on
}

// Generation describes a single Langfuse generation event — one
// LLM call. Lives inside a Trace.
type Generation struct {
	ID                  string         // unique generation id (UUIDv7)
	TraceID             string         // matches Trace.ID
	Name                string
	Model               string
	ModelParameters     map[string]any
	Input               any            // wire prefix
	Output              string         // assistant text
	StartTime           time.Time
	EndTime             time.Time
	PromptTokens        *int
	CompletionTokens    *int
	TotalTokens         *int
	CostUSD             *float64
	Metadata            map[string]any
}

// Emitter is a non-blocking, batching client for Langfuse ingestion.
// Construct one with NewEmitter, drop events on it via Trace /
// Generation, and call Stop on shutdown. Per-user credentials are
// passed in at emit time so a single Emitter serves every user
// without a static credential dependency.
type Emitter struct {
	httpClient    *http.Client
	logger        *slog.Logger
	flushInterval time.Duration
	flushBatch    int
	maxQueue      int

	mu          sync.Mutex
	queue       []envelopeEvent
	configsByUser map[string]Config // per-user creds keyed by user_id

	stopOnce sync.Once
	stopCh   chan struct{}
	doneCh   chan struct{}
}

// EmitterConfig tunes the batching / flush behaviour. Defaults are
// chosen for a personal-use deployment; busier servers can crank
// FlushBatchSize up.
type EmitterConfig struct {
	FlushInterval  time.Duration
	FlushBatchSize int
	MaxQueueSize   int
	HTTPClient     *http.Client
}

func (c *EmitterConfig) defaults() {
	if c.FlushInterval == 0 {
		c.FlushInterval = 5 * time.Second
	}
	if c.FlushBatchSize == 0 {
		c.FlushBatchSize = 32
	}
	if c.MaxQueueSize == 0 {
		c.MaxQueueSize = 1024
	}
	if c.HTTPClient == nil {
		c.HTTPClient = &http.Client{Timeout: 15 * time.Second}
	}
}

// NewEmitter constructs an Emitter and starts its background flush
// goroutine. The returned emitter is ready to accept events
// immediately; Stop blocks until the buffer drains.
func NewEmitter(logger *slog.Logger, cfg EmitterConfig) *Emitter {
	cfg.defaults()
	if logger == nil {
		logger = slog.Default()
	}
	e := &Emitter{
		httpClient:    cfg.HTTPClient,
		logger:        logger,
		flushInterval: cfg.FlushInterval,
		flushBatch:    cfg.FlushBatchSize,
		maxQueue:      cfg.MaxQueueSize,
		configsByUser: make(map[string]Config),
		stopCh:        make(chan struct{}),
		doneCh:        make(chan struct{}),
	}
	go e.run()
	return e
}

// SetUserConfig caches the per-user Langfuse config so subsequent
// emits route correctly. Called by the conversations service after
// loading the row from user_langfuse_config; called again whenever
// the user updates settings. Pass an empty Config to forget the
// user (e.g. on Delete).
func (e *Emitter) SetUserConfig(userID string, cfg Config) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if cfg == (Config{}) {
		delete(e.configsByUser, userID)
		return
	}
	e.configsByUser[userID] = cfg
}

// EmitTurn is the high-level convenience: queue both the trace and
// the generation for one assistant turn in a single call. The
// supervisor hook in the conversations service is the only caller
// today; new call sites should prefer this over hand-building the
// two events.
//
// userID gates per-user routing; the emitter looks up cached
// credentials and silently drops the events when none are
// configured (or enabled=false).
func (e *Emitter) EmitTurn(userID string, trace Trace, generation Generation) {
	if userID == "" {
		return
	}
	e.mu.Lock()
	cfg, ok := e.configsByUser[userID]
	e.mu.Unlock()
	if !ok || !cfg.Valid() {
		return
	}
	e.enqueue(userID, eventTrace(trace), eventGeneration(generation))
}

// enqueue appends events to the buffer and triggers a flush when the
// batch threshold is reached. Drops events when the queue is full
// (and logs a warning) — losing a trace is preferable to blocking
// the supervisor goroutine.
func (e *Emitter) enqueue(userID string, evts ...envelopeEventBody) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, b := range evts {
		if len(e.queue) >= e.maxQueue {
			e.logger.Warn("langfuse: queue full, dropping event",
				"queued", len(e.queue), "max", e.maxQueue, "type", b.Type)
			return
		}
		e.queue = append(e.queue, envelopeEvent{
			userID: userID,
			body:   b,
		})
	}
}

// Stop drains the buffer and exits the background goroutine. Idempotent.
func (e *Emitter) Stop(ctx context.Context) {
	e.stopOnce.Do(func() {
		close(e.stopCh)
	})
	select {
	case <-e.doneCh:
	case <-ctx.Done():
	}
}

func (e *Emitter) run() {
	defer close(e.doneCh)
	ticker := time.NewTicker(e.flushInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			e.flush()
		case <-e.stopCh:
			e.flush()
			return
		}
	}
}

func (e *Emitter) flush() {
	e.mu.Lock()
	if len(e.queue) == 0 {
		e.mu.Unlock()
		return
	}
	pending := e.queue
	e.queue = nil
	configs := make(map[string]Config, len(e.configsByUser))
	for k, v := range e.configsByUser {
		configs[k] = v
	}
	e.mu.Unlock()

	// Group by user — Langfuse credentials are per-user and we POST
	// each batch with a single auth pair.
	byUser := map[string][]envelopeEventBody{}
	for _, evt := range pending {
		byUser[evt.userID] = append(byUser[evt.userID], evt.body)
	}
	for userID, batch := range byUser {
		cfg, ok := configs[userID]
		if !ok || !cfg.Valid() {
			continue
		}
		if err := e.send(cfg, batch); err != nil {
			e.logger.Warn("langfuse: send failed",
				"err", err, "user_id", userID, "events", len(batch))
		}
	}
}

func (e *Emitter) send(cfg Config, batch []envelopeEventBody) error {
	host := strings.TrimRight(cfg.Host, "/")
	url := host + "/api/public/ingestion"

	body := envelope{Batch: batch}
	payload, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.SetBasicAuth(cfg.PublicKey, cfg.SecretKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := e.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("post: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		// Langfuse responds 207 Multi-Status when a partial batch
		// has problems; 4xx for credential / payload issues. Either
		// way, a non-2xx is signal we can't fix here — log and move
		// on so we don't block the queue.
		return fmt.Errorf("status %s", resp.Status)
	}
	return nil
}

// --- Wire shapes ---

// envelope is the top-level body Langfuse expects on the ingestion
// endpoint. `batch` is a list of typed events.
type envelope struct {
	Batch []envelopeEventBody `json:"batch"`
}

// envelopeEventBody is one row in the batch. Type discriminates the
// schema of `body`. We hand-roll this rather than using a sealed
// interface so the JSON shape stays one-to-one with Langfuse's docs.
type envelopeEventBody struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Timestamp time.Time `json:"timestamp"`
	Body      any       `json:"body"`
}

// envelopeEvent pairs an ingestion payload with the user it
// belongs to. The flusher uses userID to look up credentials.
type envelopeEvent struct {
	userID string
	body   envelopeEventBody
}

// eventTrace builds a trace-create event from a Trace.
func eventTrace(t Trace) envelopeEventBody {
	id, _ := uuid.NewV7()
	return envelopeEventBody{
		ID:        id.String(),
		Type:      "trace-create",
		Timestamp: time.Now().UTC(),
		Body: traceBody{
			ID:        t.ID,
			Name:      t.Name,
			UserID:    t.UserID,
			SessionID: t.SessionID,
			Input:     t.Input,
			Output:    t.Output,
			Timestamp: t.StartTime.UTC(),
			Metadata:  t.Metadata,
			Tags:      t.Tags,
		},
	}
}

// eventGeneration builds a generation-create event from a Generation.
func eventGeneration(g Generation) envelopeEventBody {
	id, _ := uuid.NewV7()
	usage := generationUsage{
		Input:    g.PromptTokens,
		Output:   g.CompletionTokens,
		Total:    g.TotalTokens,
		Unit:     "TOKENS",
		TotalCost: g.CostUSD,
	}
	return envelopeEventBody{
		ID:        id.String(),
		Type:      "generation-create",
		Timestamp: time.Now().UTC(),
		Body: generationBody{
			ID:              g.ID,
			TraceID:         g.TraceID,
			Name:            g.Name,
			StartTime:       g.StartTime.UTC(),
			EndTime:         g.EndTime.UTC(),
			Model:           g.Model,
			ModelParameters: g.ModelParameters,
			Input:           g.Input,
			Output:          g.Output,
			Usage:           usage,
			Metadata:        g.Metadata,
		},
	}
}

type traceBody struct {
	ID        string         `json:"id"`
	Name      string         `json:"name,omitempty"`
	UserID    string         `json:"userId,omitempty"`
	SessionID string         `json:"sessionId,omitempty"`
	Input     any            `json:"input,omitempty"`
	Output    string         `json:"output,omitempty"`
	Timestamp time.Time      `json:"timestamp"`
	Metadata  map[string]any `json:"metadata,omitempty"`
	Tags      []string       `json:"tags,omitempty"`
}

type generationBody struct {
	ID              string          `json:"id"`
	TraceID         string          `json:"traceId"`
	Name            string          `json:"name,omitempty"`
	StartTime       time.Time       `json:"startTime"`
	EndTime         time.Time       `json:"endTime"`
	Model           string          `json:"model,omitempty"`
	ModelParameters map[string]any  `json:"modelParameters,omitempty"`
	Input           any             `json:"input,omitempty"`
	Output          string          `json:"output,omitempty"`
	Usage           generationUsage `json:"usage,omitempty"`
	Metadata        map[string]any  `json:"metadata,omitempty"`
}

type generationUsage struct {
	Input     *int     `json:"input,omitempty"`
	Output    *int     `json:"output,omitempty"`
	Total     *int     `json:"total,omitempty"`
	Unit      string   `json:"unit,omitempty"`
	TotalCost *float64 `json:"totalCost,omitempty"`
}

// ErrInvalidConfig is returned by helpers that synchronously
// validate a Config. The Emitter itself doesn't return this; it
// silently drops events from invalid configs and logs once.
var ErrInvalidConfig = errors.New("langfuse: config is incomplete or disabled")
