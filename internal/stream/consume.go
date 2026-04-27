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

	"github.com/jdpedrie/clark/internal/providers"
	"github.com/jdpedrie/clark/internal/store"
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

	// Aggregators for materialization.
	var (
		contentBuilder  strings.Builder
		thinkingBuilder strings.Builder
		seenError       *chunkErrorPayload
		usage           *providers.Usage
		nextSequence    int64
	)

	buffer := make([]Chunk, 0, flushBatchSize)
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()

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
				case ch, ok := <-params.Source:
					if !ok {
						sourceClosed = true
						break loop
					}
					seq := nextSequence
					nextSequence++
					applyAggregator(ch, &contentBuilder, &thinkingBuilder, &seenError, &usage)
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
		case ch, ok := <-params.Source:
			if !ok {
				sourceClosed = true
				break
			}
			seq := nextSequence
			nextSequence++
			applyAggregator(ch, &contentBuilder, &thinkingBuilder, &seenError, &usage)
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

	// Materialize. PurposeCompression dual-writes a compression_summary in
	// the OLD context (audit + usage/cost) plus a new Context with a
	// role=context message containing the calculated REPLACE/APPEND content.
	var resultMessageID *uuid.UUID
	var resultContextID *uuid.UUID
	switch params.Purpose {
	case PurposeAssistantResponse:
		mid, err := s.materializeAssistant(runID, params, contentBuilder.String(), thinkingBuilder.String(), usage, logger)
		if err != nil {
			logger.Error("materialize assistant message failed", "err", err)
		} else if mid != uuid.Nil {
			resultMessageID = &mid
		}
	case PurposeCompression:
		// Only materialize compression artifacts on a clean stream — errored /
		// cancelled / interrupted runs leave the chunks recorded but no new
		// context is created. User retries.
		if status == statusCompleted {
			mid, cid, err := s.materializeCompression(params, contentBuilder.String(), usage, logger)
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
		}
	}

	// Encode error payload.
	var errPayload []byte
	if seenError != nil {
		if b, err := json.Marshal(seenError); err == nil {
			errPayload = b
		}
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
		finalRun = store.StreamRun{
			ID:              runID,
			ConversationID:  params.ConversationID,
			ContextID:       params.ContextID,
			ParentMessageID: params.ParentMessageID,
			ProviderID:      params.ProviderID,
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
// the first ChunkError seen, and captures the latest usage payload.
func applyAggregator(ch providers.Chunk, content, thinking *strings.Builder, seenError **chunkErrorPayload, usage **providers.Usage) {
	switch ch.Type {
	case providers.ChunkText:
		content.WriteString(extractDeltaText(ch.Payload))
	case providers.ChunkThinking:
		thinking.WriteString(extractDeltaText(ch.Payload))
	case providers.ChunkUsage:
		var u providers.Usage
		if err := json.Unmarshal(ch.Payload, &u); err == nil {
			*usage = &u
		}
	case providers.ChunkError:
		if *seenError == nil {
			msg := extractDeltaText(ch.Payload)
			if msg == "" {
				// Fallback: stringify the raw payload.
				msg = string(ch.Payload)
			}
			*seenError = &chunkErrorPayload{
				Message: msg,
				Raw:     json.RawMessage(ch.Payload),
			}
		}
	}
}

// materializeAssistant inserts an assistant message row capturing the
// stream's accumulated content and thinking. Returns the new message id, or
// uuid.Nil if no row was written (currently only on insert failure — we
// always write a row, even with empty content, so the user can see "the
// model produced nothing").
//
// The thinking JSON shape is a single concatenated block of the form
// {"type":"text","text":"…"}; richer per-provider shapes (Anthropic signed
// blocks, OpenAI reasoning items) are NOT reconstructed here — they require
// driver cooperation and are deferred to the (future) inbound transform
// pipeline. See "Materialization" in the task spec.
func (s *Supervisor) materializeAssistant(runID uuid.UUID, params StartParams, content, thinking string, usage *providers.Usage, logger interface{ Error(string, ...any) }) (uuid.UUID, error) {
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

	providerID := params.ProviderID
	modelID := params.ModelID

	insertCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Compute usage params and per-component cost from the user_model snapshot.
	usageParams := buildUsageParams(insertCtx, s.queries, providerID, modelID, usage, logger)

	if _, err := s.queries.CreateAssistantMessageWithUsage(insertCtx, store.CreateAssistantMessageWithUsageParams{
		ID:                   msgID,
		ContextID:            params.ContextID,
		ParentID:             params.ParentMessageID,
		Role:                 "assistant",
		Content:              content,
		RawContent:           nil,
		Thinking:             thinkingJSON,
		ThinkingProviderType: nil,
		ThinkingRenderedText: nil,
		ProviderID:           &providerID,
		ModelID:              &modelID,
		InputTokens:          usageParams.InputTokens,
		OutputTokens:         usageParams.OutputTokens,
		CacheReadTokens:      usageParams.CacheReadTokens,
		CacheWriteTokens:     usageParams.CacheWriteTokens,
		ReasoningTokens:      usageParams.ReasoningTokens,
		ProviderUsageRaw:     usageParams.ProviderUsageRaw,
		InputCostUsd:         usageParams.InputCostUsd,
		OutputCostUsd:        usageParams.OutputCostUsd,
		CacheReadCostUsd:     usageParams.CacheReadCostUsd,
		CacheWriteCostUsd:    usageParams.CacheWriteCostUsd,
		TotalCostUsd:         usageParams.TotalCostUsd,
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

	// Fire the post-materialization hook (auto-title generation, etc.) in a
	// detached goroutine so the supervisor's terminal handling is unaffected
	// by hook latency or failure.
	if s.onAssistantMaterialized != nil {
		go s.onAssistantMaterialized(context.Background(), params, msgID)
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
	TotalCostUsd      pgtype.Numeric
}

// buildUsageParams converts a *providers.Usage (which may be nil) plus the
// user_model pricing snapshot into the column values for CreateAssistantMessageWithUsage.
// On any DB error fetching the user_model, costs are left null and tokens are still recorded.
func buildUsageParams(ctx context.Context, q *store.Queries, providerID uuid.UUID, modelID string, usage *providers.Usage, logger interface{ Error(string, ...any) }) usageColumns {
	out := usageColumns{}
	if usage == nil {
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
		// leave costs null. Not a hard failure — assistant message still
		// gets written.
		if !errors.Is(err, pgx.ErrNoRows) {
			logger.Error("usage: fetch user_model failed", "err", err)
		}
		return out
	}

	out.InputCostUsd = costFromTokens(usage.InputTokens, row.InputPricePerMillion)
	out.OutputCostUsd = costFromTokens(usage.OutputTokens, row.OutputPricePerMillion)
	out.CacheReadCostUsd = costFromTokens(usage.CacheReadTokens, row.CacheReadPerMillion)
	out.CacheWriteCostUsd = costFromTokens(usage.CacheWriteTokens, row.CacheWritePerMillion)
	out.TotalCostUsd = sumNumerics(out.InputCostUsd, out.OutputCostUsd, out.CacheReadCostUsd, out.CacheWriteCostUsd)
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
// record, not a wire turn. Its presence in the context is also a "pending
// compaction" marker that gates SendMessage / Compact via the
// requireNoPendingCompactionSummary precondition.
//
// The new Context creation is now a separate, user-driven step
// (PromoteCompactionToNewContext on ConversationsService), so the user can
// review and edit the summary before committing to the split.
//
// Returns (compressionSummaryID, uuid.Nil, error). The second return slot is
// retained for backwards compat with the consume loop's existing two-id
// handling; it is always uuid.Nil now.
func (s *Supervisor) materializeCompression(params StartParams, summary string, usage *providers.Usage, logger interface{ Error(string, ...any) }) (uuid.UUID, uuid.UUID, error) {
	insertCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	summaryID, err := uuid.NewV7()
	if err != nil {
		return uuid.Nil, uuid.Nil, fmt.Errorf("uuid: %w", err)
	}
	providerID := params.ProviderID
	modelID := params.ModelID
	usageParams := buildUsageParams(insertCtx, s.queries, providerID, modelID, usage, logger)
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
	}); err != nil {
		return uuid.Nil, uuid.Nil, fmt.Errorf("insert compression_summary: %w", err)
	}
	return summaryID, uuid.Nil, nil
}
