package stream

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/jdpedrie/psmith/internal/modelmeta"
	"github.com/jdpedrie/psmith/internal/providers"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
)

// consume is the supervisor goroutine for one run. It:
//   - reads chunks from params.Source
//   - assigns monotonic sequences and buffers them
//   - flushes the buffer to stream_chunks every flushInterval or when the
//     buffer reaches flushBatchSize
//   - fans out each chunk to live subscribers (after persistence — keeps the
//     "broker only ever sends what's already in DB" invariant)
//   - on Source close / ChunkError / ctx cancellation, materializes the
//     final assistant message and finalizes the stream_run row
//   - closes all subscriber channels and removes the runState from
//     Supervisor.runs in defer
func (s *Supervisor) consume(ctx context.Context, runID uuid.UUID, params StartParams, rs *runState) {
	logger := s.logger.With("run_id", runID)

	// Resolve the source channel. SendFunc mode (preferred for assistant
	// turns) calls openStreamWithRetry which applies retry + per-attempt
	// timeout; on exhaustion it returns a synthetic error stream so the
	// rest of consume runs the normal aggregation path and materialises
	// an errored assistant message inline. Source mode is the legacy /
	// test path: the channel is consumed as-is with no retry.
	source := params.Source
	if params.SendFunc != nil {
		opened, err := openStreamWithRetry(ctx, params.SendFunc, s.logger)
		if err != nil {
			source = syntheticErrorStream(err)
		} else {
			source = reinjectFirstChunk(opened)
		}
	}

	// Aggregators for materialization.
	var (
		contentBuilder  strings.Builder
		thinkingBuilder strings.Builder
		thinkingFirstAt time.Time // wall-clock of first thinking_delta seen
		thinkingLastAt  time.Time // wall-clock of last thinking_delta seen
		seenError       *chunkErrorPayload
		usage           *providers.Usage
		nextSequence    int64
		toolCalls       = newToolCallAggregator()
	)

	buffer := make([]Chunk, 0, flushBatchSize)
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()

	// Idle timeout: reset on every chunk. If the upstream goes silent
	// for IdleTimeout (no chunks at all) after streaming starts, we
	// cancel the run and finalise as errored. The first-chunk wait is
	// governed separately by openOnce's PerAttemptTimeout — by the time
	// we get here, the first chunk has already been delivered (via
	// reinjectFirstChunk).
	idleTimer := time.NewTimer(IdleTimeout)
	defer idleTimer.Stop()
	resetIdle := func() {
		if !idleTimer.Stop() {
			select {
			case <-idleTimer.C:
			default:
			}
		}
		idleTimer.Reset(IdleTimeout)
	}

	// Flush helper. Persists buffered chunks in sequence, then fans them
	// out to live subscribers. Persistence-then-fanout is the invariant
	// that lets new subscribers replay-from-DB-then-live-tail without
	// missing or duplicating chunks.
	//
	// Persistence is best-effort per chunk: a transient INSERT failure is
	// logged but does not stop the run (we still fan out to subscribers
	// and continue draining Source). The architecture explicitly accepts
	// chunk-loss-on-crash; per-chunk DB failures fall in the same bucket.
	flush := func() {
		if len(buffer) == 0 {
			return
		}
		// Persistence uses context.Background so an in-flight flush
		// completes even when ctx is being cancelled (Cancel call).
		// We still want the cancelled-stream's already-streamed chunks
		// in the DB so subscribers can read partial content.
		persistCtx, persistCancel := context.WithTimeout(context.Background(), 5*time.Second)
		for _, ch := range buffer {
			if err := s.queries.InsertStreamChunk(persistCtx, store.InsertStreamChunkParams{
				StreamRunID: runID,
				Sequence:    ch.Sequence,
				ChunkType:   string(ch.Type),
				Payload:     ch.Payload,
			}); err != nil {
				logger.Error("persist chunk failed", "sequence", ch.Sequence, "err", err)
			}
		}
		persistCancel()

		// Fan out under the broker mutex. Slow-subscriber detection is
		// per-chunk: if any send would block, drop that subscriber.
		rs.mu.Lock()
		// Collect drops without mutating during iteration.
		var drops []chan SubscribeEvent
		for _, ch := range buffer {
			ev := SubscribeEvent{Chunk: &Chunk{
				Sequence: ch.Sequence,
				Type:     ch.Type,
				Payload:  ch.Payload,
			}}
			for _, sub := range rs.subscribers {
				select {
				case sub <- ev:
				default:
					drops = append(drops, sub)
				}
			}
			// Advance fanoutCursor under the lock so newly-registering
			// subscribers can bound their gap-fill DB read against it and
			// avoid duplicate delivery (chunks the broker already fanned
			// out vs chunks the broker is about to fan out).
			rs.fanoutCursor = ch.Sequence
		}
		// Remove drops in-place; close after releasing the mutex.
		if len(drops) > 0 {
			alive := rs.subscribers[:0]
		outer:
			for _, sub := range rs.subscribers {
				for _, d := range drops {
					if d == sub {
						continue outer
					}
				}
				alive = append(alive, sub)
			}
			rs.subscribers = alive
		}
		rs.mu.Unlock()

		for _, d := range drops {
			safeClose(d)
		}

		buffer = buffer[:0]
	}

	// Main consume loop.
	sourceClosed := false
loop:
	for !sourceClosed {
		select {
		case <-ctx.Done():
			// Cancel was called (or supervisor shutdown). Drain any
			// chunks already on Source non-blockingly so we don't
			// silently drop them, then exit.
			for {
				select {
				case ch, ok := <-source:
					if !ok {
						sourceClosed = true
						break loop
					}
					seq := nextSequence
					nextSequence++
					applyAggregator(ch, &contentBuilder, &thinkingBuilder, &thinkingFirstAt, &thinkingLastAt, &seenError, &usage)
					toolCalls.observe(ch)
					buffer = append(buffer, Chunk{
						Sequence: seq,
						Type:     ch.Type,
						Payload:  ch.Payload,
					})
					if len(buffer) >= flushBatchSize {
						flush()
					}
				default:
					break loop
				}
			}
		case ch, ok := <-source:
			if !ok {
				sourceClosed = true
				break
			}
			resetIdle()
			seq := nextSequence
			nextSequence++
			applyAggregator(ch, &contentBuilder, &thinkingBuilder, &thinkingFirstAt, &thinkingLastAt, &seenError, &usage)
			toolCalls.observe(ch)
			buffer = append(buffer, Chunk{
				Sequence: seq,
				Type:     ch.Type,
				Payload:  ch.Payload,
			})
			if len(buffer) >= flushBatchSize {
				flush()
			}
		case <-ticker.C:
			flush()
		case <-idleTimer.C:
			// Upstream went silent for IdleTimeout. Mark the run as
			// errored and cancel the SDK's context so the reinject
			// goroutine drains and source closes. Loop exits via the
			// ctx.Done() drain branch on the next iteration.
			if seenError == nil {
				msg := fmt.Sprintf("upstream stream idle for %s", IdleTimeout)
				payload, _ := json.Marshal(map[string]string{"message": msg})
				seenError = &chunkErrorPayload{
					Message: msg,
					Raw:     json.RawMessage(payload),
				}
			}
			rs.cancel()
		}
	}

	// Final flush before materialization.
	flush()

	// Pick terminal status.
	rs.mu.Lock()
	cancelled := rs.cancelRequested
	rs.mu.Unlock()

	status := statusCompleted
	switch {
	case seenError != nil:
		status = statusErrored
	case cancelled:
		status = statusCancelled
	}

	// Encode error payload — shared by stream_runs.error_payload and (when
	// the run errored) the materialized message row's error_payload column.
	var errPayload []byte
	if seenError != nil {
		if b, err := json.Marshal(seenError); err == nil {
			errPayload = b
		}
	}

	// Materialize. Both PurposeAssistantResponse and PurposeCompression now
	// always write a message row, even on errored/cancelled runs — the row
	// carries the partial content streamed before failure plus errPayload, so
	// the UI can render the failed turn as a first-class history entry the
	// user can review (and eventually retry from). The canonical error copy
	// still lives on stream_runs.error_payload.
	var resultMessageID *uuid.UUID
	var resultContextID *uuid.UUID
	switch params.Purpose {
	case PurposeAssistantResponse:
		var thinkingDurMs *int32
		if !thinkingFirstAt.IsZero() && !thinkingLastAt.IsZero() {
			ms := int32(thinkingLastAt.Sub(thinkingFirstAt).Milliseconds())
			thinkingDurMs = &ms
		}
		mid, err := s.materializeAssistant(runID, params, contentBuilder.String(), thinkingBuilder.String(), thinkingDurMs, usage, errPayload, cancelled, toolCalls.serialise(), logger)
		if err != nil {
			logger.Error("materialize assistant message failed", "err", err)
		} else if mid != uuid.Nil {
			resultMessageID = &mid
		}
	case PurposeCompression:
		// On errored/cancelled compression runs we still write the
		// compression_summary row in the source context — empty (or
		// partial) content + errPayload — so the user sees the failed
		// compaction in their history. New-context creation remains
		// gated on a clean run; the user retries by deleting the failed
		// summary or kicking off a fresh compaction.
		mid, cid, err := s.materializeCompression(params, contentBuilder.String(), usage, errPayload, logger)
		if err != nil {
			logger.Error("materialize compression failed", "err", err)
		} else {
			if mid != uuid.Nil {
				resultMessageID = &mid
			}
			if cid != uuid.Nil {
				resultContextID = &cid
			}
		}
		// Per-run compression hook — used by the conversations
		// service to fan out post-materialise work for compaction
		// turns (today, the Langfuse trace). Skip on errored runs;
		// they don't represent useful turn semantics.
		if mid != uuid.Nil && len(errPayload) == 0 && params.OnCompressionMaterialized != nil {
			params.OnCompressionMaterialized(context.Background(), mid)
		}
	}

	// Any materialized row — assistant, compression, errored — is a
	// conversation mutation other clients should hear about.
	if resultMessageID != nil && s.onRunMaterialized != nil {
		s.onRunMaterialized(params)
	}

	// Finalize. Use context.Background so a cancelled run still gets its
	// terminal row written.
	finalizeCtx, finalizeCancel := context.WithTimeout(context.Background(), 5*time.Second)
	finalRun, err := s.queries.FinalizeStreamRun(finalizeCtx, store.FinalizeStreamRunParams{
		ID:              runID,
		Status:          status,
		ResultMessageID: resultMessageID,
		ResultContextID: resultContextID,
		ErrorPayload:    errPayload,
	})
	finalizeCancel()
	if err != nil {
		logger.Error("finalize stream run failed", "err", err)
		// Best-effort: build a synthetic terminal row from what we know
		// so subscribers still see something.
		providerIDPtr := params.ProviderID
		finalRun = store.StreamRun{
			ID:              runID,
			ConversationID:  params.ConversationID,
			ContextID:       params.ContextID,
			ParentMessageID: params.ParentMessageID,
			ProviderID:      &providerIDPtr,
			ModelID:         params.ModelID,
			Status:          status,
			Purpose:         string(params.Purpose),
			ResultMessageID: resultMessageID,
			ErrorPayload:    errPayload,
		}
	}

	// Mark terminal under the mutex, snapshot subscribers, then close
	// each. New Subscribe calls after this point will see terminated and
	// short-circuit to the terminal-event-from-DB path.
	rs.mu.Lock()
	rs.terminated = true
	rs.terminal = &finalRun
	subs := rs.subscribers
	rs.subscribers = nil
	rs.mu.Unlock()

	for _, sub := range subs {
		// Best-effort terminal send (non-blocking — if the consumer
		// has gone away, we still close).
		select {
		case sub <- SubscribeEvent{Terminal: &finalRun}:
		default:
		}
		safeClose(sub)
	}

	s.runs.Delete(runID)
}

// applyAggregator updates the running content/thinking aggregates, records
// the first ChunkError seen, captures the latest usage payload, and stamps
// the first/last wall-clock times a thinking_delta was seen — used at
// materialization to derive `messages.thinking_duration_ms` for the UI's
// "Thought for X.Ys" badge.
func applyAggregator(ch providers.Chunk, content, thinking *strings.Builder, thinkingFirstAt, thinkingLastAt *time.Time, seenError **chunkErrorPayload, usage **providers.Usage) {
	switch ch.Type {
	case providers.ChunkText:
		content.WriteString(extractDeltaText(ch.Payload))
	case providers.ChunkContentReset:
		// The compression continuation wrapper detected a document
		// restart: everything accumulated so far is superseded by
		// the text that follows. Resetting here is what keeps the
		// MATERIALIZED summary clean even though the live stream
		// already carried the superseded text.
		content.Reset()
	case providers.ChunkThinking:
		thinking.WriteString(extractDeltaText(ch.Payload))
		now := time.Now()
		if thinkingFirstAt.IsZero() {
			*thinkingFirstAt = now
		}
		*thinkingLastAt = now
	case providers.ChunkUsage:
		var u providers.Usage
		if err := json.Unmarshal(ch.Payload, &u); err == nil {
			*usage = &u
		}
	case providers.ChunkError:
		if *seenError == nil {
			// ChunkError payloads carry `.message` (per the provider
			// driver contract — see internal/providers/google/send.go +
			// openai/anthropic emit shapes). extractDeltaText looks for
			// `.text` and would miss the actual error string, leaving
			// us with the raw JSON stringified into Message — that's
			// what lands in messages.error_payload and breaks the UI's
			// errorTextFromPayload extraction.
			msg := extractErrorMessage(ch.Payload)
			*seenError = &chunkErrorPayload{
				Message: msg,
				Raw:     json.RawMessage(ch.Payload),
			}
		}
	}
}

// extractErrorMessage pulls the human-readable string out of a ChunkError
// payload. Drivers emit `{"message":"...", ...}`; we tolerate `.text` and
// bare strings too so a driver that emitted the wrong shape still surfaces
// SOMETHING readable rather than stringified JSON.
func extractErrorMessage(payload json.RawMessage) string {
	if len(payload) == 0 {
		return ""
	}
	var withMsg struct {
		Message string `json:"message"`
		Text    string `json:"text"`
	}
	if err := json.Unmarshal(payload, &withMsg); err == nil {
		if withMsg.Message != "" {
			return withMsg.Message
		}
		if withMsg.Text != "" {
			return withMsg.Text
		}
	}
	var s string
	if err := json.Unmarshal(payload, &s); err == nil && s != "" {
		return s
	}
	return ""
}

// materializeAssistant inserts an assistant message row capturing the
// stream's accumulated content and thinking. Returns the new message id, or
// uuid.Nil if no row was written (currently only on insert failure — we
// always write a row, even with empty content, so the user can see "the
// model produced nothing").
//
// errPayload is non-nil only for errored runs; in that case the message
// carries the same JSON-encoded chunkErrorPayload that lands on
// stream_runs.error_payload, so the UI can render the failure inline as a
// first-class history entry (partial content + error text + provider/model).
//
// The thinking JSON shape is a single concatenated block of the form
// {"type":"text","text":"…"}; richer per-provider shapes (Anthropic signed
// blocks, OpenAI reasoning items) are NOT reconstructed here — they require
// driver cooperation and are deferred to the (future) inbound transform
// pipeline. See "Materialization" in the task spec.
func (s *Supervisor) materializeAssistant(runID uuid.UUID, params StartParams, content, thinking string, thinkingDurationMs *int32, usage *providers.Usage, errPayload []byte, cancelled bool, toolCallsJSON []byte, logger interface{ Error(string, ...any) }) (uuid.UUID, error) {
	// We always write a row, even with empty content, so the user can
	// see that an attempt was made and so result_message_id is non-null
	// for downstream UX.
	msgID, err := uuid.NewV7()
	if err != nil {
		return uuid.Nil, err
	}

	var thinkingJSON []byte
	if thinking != "" {
		blob, err := json.Marshal([]thinkingBlock{{Type: "text", Text: thinking}})
		if err == nil {
			thinkingJSON = blob
		}
	}

	// Populate thinking_provider_type + thinking_rendered_text from the
	// driver. The provider_type tells future cross-provider sends how to
	// route the stored thinking ("native if same provider, plaintext-inject
	// otherwise"); the rendered_text gives the UI a deterministic plaintext
	// view that survives the wire round-trip without re-parsing per-driver
	// JSONB. Both NULL when there's no thinking content.
	var thinkingProviderType *string
	var thinkingRenderedText *string
	if len(thinkingJSON) > 0 && params.Provider != nil {
		t := params.Provider.Type()
		thinkingProviderType = &t
		rendered := params.Provider.RenderThinkingToText(thinkingJSON)
		if rendered != "" {
			thinkingRenderedText = &rendered
		}
	}

	providerID := params.ProviderID
	modelID := params.ModelID

	insertCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Compute usage params and per-component cost from the user_model snapshot.
	// toolCost may be nil when no tool reported a cost; buildUsageParams folds
	// it into the total when set so the existing per-message cost chip
	// captures total spend without a UI refactor.
	var toolCost *float64
	if params.ToolCostProvider != nil {
		toolCost = params.ToolCostProvider()
	}
	usageParams := buildUsageParams(insertCtx, s.queries, providerID, modelID, usage, toolCost, logger)

	// AssistantContentTransformer plugins rewrite the just-finalised
	// assistant text BEFORE the row is inserted. The persisted bytes
	// match the post-transform output, so subsequent history builds
	// and display reads see the rewritten content forever.
	if !params.Pipeline.Empty() {
		content = params.Pipeline.TransformAssistantContent(content)
	}

	var finishReason *string
	if usage != nil {
		finishReason = usage.FinishReason
	}
	// User-cancelled runs override whatever the upstream said (or didn't
	// say) — we want a deterministic "Stopped: user cancelled" hint on
	// the row regardless of whether the driver got a chance to emit a
	// final usage chunk before ctx cancellation tore the stream down.
	if cancelled {
		s := "user_cancelled"
		finishReason = &s
	}
	if _, err := s.queries.CreateAssistantMessageWithUsage(insertCtx, store.CreateAssistantMessageWithUsageParams{
		ID:                    msgID,
		ContextID:             params.ContextID,
		ParentID:              params.ParentMessageID,
		Role:                  "assistant",
		Content:               content,
		RawContent:            nil,
		Thinking:              thinkingJSON,
		ThinkingProviderType:  thinkingProviderType,
		ThinkingRenderedText:  thinkingRenderedText,
		ThinkingDurationMs:    thinkingDurationMs,
		ProviderID:            &providerID,
		ModelID:               &modelID,
		InputTokens:           usageParams.InputTokens,
		OutputTokens:          usageParams.OutputTokens,
		CacheReadTokens:       usageParams.CacheReadTokens,
		CacheWriteTokens:      usageParams.CacheWriteTokens,
		ReasoningTokens:       usageParams.ReasoningTokens,
		ProviderUsageRaw:      usageParams.ProviderUsageRaw,
		InputCostUsd:          usageParams.InputCostUsd,
		OutputCostUsd:         usageParams.OutputCostUsd,
		CacheReadCostUsd:      usageParams.CacheReadCostUsd,
		CacheWriteCostUsd:     usageParams.CacheWriteCostUsd,
		ToolCostUsd:           usageParams.ToolCostUsd,
		TotalCostUsd:          usageParams.TotalCostUsd,
		ErrorPayload:          errPayload,
		ExplicitCacheAttached: params.ExplicitCacheAttached,
		ToolCalls:             toolCallsJSON,
		FinishReason:          finishReason,
	}); err != nil {
		// If the context row was deleted out from under us (cascade),
		// log and skip — the run still gets finalized.
		if errors.Is(err, pgx.ErrNoRows) {
			logger.Error("materialize: target context missing", "context_id", params.ContextID)
			return uuid.Nil, err
		}
		return uuid.Nil, err
	}

	// Advance the per-context cursor to the just-materialized assistant message
	// so the next SendMessage (without an explicit parent) parents off the
	// assistant turn rather than the prior user message. Best-effort: if the
	// context row vanished mid-flight, skip silently — the message itself
	// already cascaded out.
	if _, err := s.queries.UpdateContextCurrentLeaf(insertCtx, store.UpdateContextCurrentLeafParams{
		ID:                   params.ContextID,
		CurrentLeafMessageID: &msgID,
	}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		logger.Error("materialize: advance current_leaf failed", "context_id", params.ContextID, "err", err)
	}

	// Append to the per-provider cost ledger when the turn actually
	// cost something. Best-effort: a failed insert is logged and
	// doesn't block the rest of materialisation. Errored runs still
	// log if total_cost_usd > 0 — the provider charged for whatever
	// tokens it produced, regardless of whether the answer was useful.
	logCostEvent(insertCtx, s.queries, providerID, modelID, &msgID, usageParams.TotalCostUsd, logger)

	// Per-run materialization hook — used by the conversations
	// service to persist tool-result attachments collected during
	// the tool loop. Runs synchronously inside this goroutine
	// (the persist work has to finish before the supervisor
	// closes the run + frees the collector slice); any returned
	// error is the caller's to log.
	if params.OnAssistantMaterialized != nil && len(errPayload) == 0 {
		params.OnAssistantMaterialized(context.Background(), msgID)
	}

	// Fire the post-materialization hook (auto-title generation, etc.) in a
	// detached goroutine so the supervisor's terminal handling is unaffected
	// by hook latency or failure. Skip on errored runs — there's no useful
	// assistant turn for the title generator to read off, and we'd just
	// burn another LLM call against a model that already failed.
	if s.onAssistantMaterialized != nil && len(errPayload) == 0 {
		go s.onAssistantMaterialized(context.Background(), params, msgID)
	}

	// Fire MessageLifecycleHook plugins (fire-and-forget). Same skip rule
	// as the title hook above — errored runs don't fan out (the row
	// exists for UI surfacing but downstream processing — embedding,
	// auto-tag — would be working with garbage content).
	if !params.Pipeline.Empty() && len(errPayload) == 0 {
		params.Pipeline.FireMessagePersisted(context.Background(), plugins.PersistedMessage{
			ID:         msgID.String(),
			ContextID:  params.ContextID.String(),
			Role:       "assistant",
			Content:    content,
			ProviderID: providerID.String(),
			ModelID:    modelID,
		}, s.logger)
	}
	return msgID, nil
}

// usageColumns mirrors the usage/cost columns on the messages table so we
// can keep the cost-calculation logic out of the main materialization path.
type usageColumns struct {
	InputTokens       *int32
	OutputTokens      *int32
	CacheReadTokens   *int32
	CacheWriteTokens  *int32
	ReasoningTokens   *int32
	ProviderUsageRaw  []byte
	InputCostUsd      pgtype.Numeric
	OutputCostUsd     pgtype.Numeric
	CacheReadCostUsd  pgtype.Numeric
	CacheWriteCostUsd pgtype.Numeric
	ToolCostUsd       pgtype.Numeric
	TotalCostUsd      pgtype.Numeric
}

// buildUsageParams converts a *providers.Usage (which may be nil) plus the
// user_model pricing snapshot into the column values for CreateAssistantMessageWithUsage.
// On any DB error fetching the user_model, costs are left null and tokens are still recorded.
//
// toolCost is the run's accumulated tool-side spend (sum of every
// ToolResult.CostUSD seen during the tool loop). Nil = no tool reported a
// cost; non-nil values are written to ToolCostUsd and folded into
// TotalCostUsd alongside token costs.
func buildUsageParams(ctx context.Context, q *store.Queries, providerID uuid.UUID, modelID string, usage *providers.Usage, toolCost *float64, logger interface{ Error(string, ...any) }) usageColumns {
	out := usageColumns{}
	if toolCost != nil {
		out.ToolCostUsd = floatToNumeric(*toolCost)
	}
	if usage == nil {
		// Even with no token usage, a tool may have spent money. The
		// total then equals just the tool cost.
		out.TotalCostUsd = sumNumerics(out.ToolCostUsd)
		return out
	}
	out.InputTokens = intToPtrInt32(usage.InputTokens)
	out.OutputTokens = intToPtrInt32(usage.OutputTokens)
	out.CacheReadTokens = intToPtrInt32(usage.CacheReadTokens)
	out.CacheWriteTokens = intToPtrInt32(usage.CacheWriteTokens)
	out.ReasoningTokens = intToPtrInt32(usage.ReasoningTokens)
	out.ProviderUsageRaw = []byte(usage.ProviderRaw)

	row, err := q.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: providerID,
		ModelID:             modelID,
	})
	if err != nil {
		// If the model row vanished (deleted, etc.), record tokens but
		// leave token costs null. Tool cost still flows through.
		if !errors.Is(err, pgx.ErrNoRows) {
			logger.Error("usage: fetch user_model failed", "err", err)
		}
		out.TotalCostUsd = sumNumerics(out.ToolCostUsd)
		return out
	}

	// Context-size-tiered pricing: when the model row carries tiers
	// and the request's prompt (input + cache read + cache write)
	// exceeds a tier threshold, the WHOLE request prices at that tier
	// (provider semantics — grok-4.5-style). Nil tier subfields fall
	// back to the base columns.
	inPrice := row.InputPricePerMillion
	outPrice := row.OutputPricePerMillion
	crPrice := row.CacheReadPerMillion
	cwPrice := row.CacheWritePerMillion
	if len(row.PricingTiers) > 0 {
		var tiers []modelmeta.PricingTier
		if err := json.Unmarshal(row.PricingTiers, &tiers); err == nil {
			prompt := 0
			for _, t := range []*int{usage.InputTokens, usage.CacheReadTokens, usage.CacheWriteTokens} {
				if t != nil {
					prompt += *t
				}
			}
			if tier := modelmeta.EffectiveTier(tiers, prompt); tier != nil {
				if tier.InputPerMillion != nil {
					inPrice = tier.InputPerMillion
				}
				if tier.OutputPerMillion != nil {
					outPrice = tier.OutputPerMillion
				}
				if tier.CacheReadPerMillion != nil {
					crPrice = tier.CacheReadPerMillion
				}
				if tier.CacheWritePerMillion != nil {
					cwPrice = tier.CacheWritePerMillion
				}
			}
		}
	}

	out.InputCostUsd = costFromTokens(usage.InputTokens, inPrice)
	out.OutputCostUsd = costFromTokens(usage.OutputTokens, outPrice)
	out.CacheReadCostUsd = costFromTokens(usage.CacheReadTokens, crPrice)
	out.CacheWriteCostUsd = costFromTokens(usage.CacheWriteTokens, cwPrice)
	out.TotalCostUsd = sumNumerics(out.InputCostUsd, out.OutputCostUsd, out.CacheReadCostUsd, out.CacheWriteCostUsd, out.ToolCostUsd)
	return out
}

// costFromTokens returns numeric cost = tokens * pricePerMillion / 1_000_000.
// Both inputs nullable; if either is nil, returns invalid pgtype.Numeric.
func costFromTokens(tokens *int, pricePerMillion *float64) pgtype.Numeric {
	if tokens == nil || pricePerMillion == nil {
		return pgtype.Numeric{}
	}
	v := float64(*tokens) * (*pricePerMillion) / 1_000_000.0
	return floatToNumeric(v)
}

// floatToNumeric parses a float into pgtype.Numeric via string round-trip,
// the cleanest path that covers fractional values without big.Int gymnastics.
func floatToNumeric(v float64) pgtype.Numeric {
	var n pgtype.Numeric
	if err := n.Scan(strconv.FormatFloat(v, 'f', 6, 64)); err != nil {
		return pgtype.Numeric{}
	}
	return n
}

// sumNumerics returns the sum of valid components; nil if all components are invalid.
func sumNumerics(parts ...pgtype.Numeric) pgtype.Numeric {
	total := 0.0
	any := false
	for _, p := range parts {
		if !p.Valid {
			continue
		}
		f, err := p.Float64Value()
		if err != nil || !f.Valid {
			continue
		}
		total += f.Float64
		any = true
	}
	if !any {
		return pgtype.Numeric{}
	}
	return floatToNumeric(total)
}

func intToPtrInt32(p *int) *int32 {
	if p == nil {
		return nil
	}
	v := int32(*p)
	return &v
}

// materializeCompression handles PurposeCompression terminal materialization.
// As of the two-stage compaction reshape, this writes ONLY the
// `role=compression_summary` message in the OLD Context, carrying the
// assistant summary as content plus the usage/cost from this run.
// History-builder skips this row by design — it's a permanent audit/cost
// record, not a wire turn.
//
// On a clean (errPayload == nil) run the resulting summary's presence in the
// context gates SendMessage / Compact via the requireNoPendingCompactionSummary
// precondition; the user retries by either deleting the summary or calling
// PromoteCompactionToNewContext.
//
// On an errored or cancelled run errPayload is non-nil and the row is written
// with whatever partial content streamed before the failure (often empty) so
// the user sees the failed compaction in their history. Errored summaries
// are NOT treated as pending — the UI can let the user dismiss them and
// keep sending in the source context.
//
// Returns (compressionSummaryID, uuid.Nil, error). The second return slot is
// retained for backwards compat with the consume loop's existing two-id
// handling; it is always uuid.Nil now.
func (s *Supervisor) materializeCompression(params StartParams, summary string, usage *providers.Usage, errPayload []byte, logger interface{ Error(string, ...any) }) (uuid.UUID, uuid.UUID, error) {
	insertCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	summaryID, err := uuid.NewV7()
	if err != nil {
		return uuid.Nil, uuid.Nil, fmt.Errorf("uuid: %w", err)
	}
	providerID := params.ProviderID
	modelID := params.ModelID
	// Compression turns never call tools today — pass nil for toolCost.
	usageParams := buildUsageParams(insertCtx, s.queries, providerID, modelID, usage, nil, logger)
	// finish_reason makes a truncated compaction diagnosable: a summary
	// that stopped at the output cap carries max_tokens/length/MAX_TOKENS
	// here, where a clean stop carries end_turn/stop/STOP. Without it a
	// capped summary is indistinguishable from a complete one.
	var finishReason *string
	if usage != nil {
		finishReason = usage.FinishReason
	}
	if _, err := s.queries.CreateAssistantMessageWithUsage(insertCtx, store.CreateAssistantMessageWithUsageParams{
		ID:                summaryID,
		ContextID:         params.ContextID,
		ParentID:          params.ParentMessageID,
		Role:              "compression_summary",
		Content:           summary,
		ProviderID:        &providerID,
		ModelID:           &modelID,
		InputTokens:       usageParams.InputTokens,
		OutputTokens:      usageParams.OutputTokens,
		CacheReadTokens:   usageParams.CacheReadTokens,
		CacheWriteTokens:  usageParams.CacheWriteTokens,
		ReasoningTokens:   usageParams.ReasoningTokens,
		ProviderUsageRaw:  usageParams.ProviderUsageRaw,
		InputCostUsd:      usageParams.InputCostUsd,
		OutputCostUsd:     usageParams.OutputCostUsd,
		CacheReadCostUsd:  usageParams.CacheReadCostUsd,
		CacheWriteCostUsd: usageParams.CacheWriteCostUsd,
		TotalCostUsd:      usageParams.TotalCostUsd,
		ErrorPayload:      errPayload,
		FinishReason:      finishReason,
	}); err != nil {
		return uuid.Nil, uuid.Nil, fmt.Errorf("insert compression_summary: %w", err)
	}

	// Compression turns count toward the cost ledger too — the user
	// pays for tokens regardless of whether the turn was Q&A or
	// summarisation.
	logCostEvent(insertCtx, s.queries, providerID, modelID, &summaryID, usageParams.TotalCostUsd, logger)

	// Advance the per-context cursor to the just-materialized
	// compression_summary so ListMessageAncestorChain (the standard list path)
	// includes it in the rendered conversation. Without this the chain walks
	// up from the previous assistant turn and the summary — sitting as a
	// child of that turn — never appears in the UI. Best-effort: if the
	// context vanished mid-flight, the message itself already cascaded out,
	// so a no-rows result is benign.
	if _, err := s.queries.UpdateContextCurrentLeaf(insertCtx, store.UpdateContextCurrentLeafParams{
		ID:                   params.ContextID,
		CurrentLeafMessageID: &summaryID,
	}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		logger.Error("materialize compression: advance current_leaf failed", "context_id", params.ContextID, "err", err)
	}

	// Fire MessageLifecycleHook plugins for the compression_summary row.
	// Skip on errored runs (same rationale as materializeAssistant).
	if !params.Pipeline.Empty() && len(errPayload) == 0 {
		params.Pipeline.FireMessagePersisted(context.Background(), plugins.PersistedMessage{
			ID:         summaryID.String(),
			ContextID:  params.ContextID.String(),
			Role:       "compression_summary",
			Content:    summary,
			ProviderID: providerID.String(),
			ModelID:    modelID,
		}, s.logger)
	}
	return summaryID, uuid.Nil, nil
}

// logCostEvent appends a row to the cost_events ledger when the
// just-materialised turn carried a non-zero total cost. Best-effort —
// a failure here is logged and doesn't block materialisation, since
// the message itself (carrying its own cost columns) is the source of
// truth for per-row accounting and the ledger only exists for the
// rolled-up settings view.
func logCostEvent(ctx context.Context, q *store.Queries, providerID uuid.UUID, modelID string, messageID *uuid.UUID, totalCost pgtype.Numeric, logger interface{ Error(string, ...any) }) {
	if !totalCost.Valid {
		return
	}
	f, err := totalCost.Float64Value()
	if err != nil || !f.Valid || f.Float64 <= 0 {
		return
	}
	if err := q.InsertCostEvent(ctx, store.InsertCostEventParams{
		ProviderID: providerID,
		ModelID:    modelID,
		AmountUsd:  totalCost,
		MessageID:  messageID,
	}); err != nil {
		logger.Error("cost_events: insert failed", "provider_id", providerID, "err", err)
	}
}
