package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/reeve/internal/langfuse"
	"github.com/jdpedrie/reeve/internal/stream"
)

// emitLangfuseAssistantTurn fires one Langfuse Trace + Generation
// pair for the just-materialised assistant message, plus one Span
// per tool call dispatched during the run. Per-user gating happens
// inside the Emitter — when the conversation owner hasn't
// configured Langfuse, EmitTurn / EmitSpan are silent no-ops with
// no DB hop, no allocation.
//
// Called from the per-run postMaterialize closure inside
// SendMessage so this method has access to the drained tool-span
// buffer; callers that don't have spans (every existing test, the
// process-wide title hook) should use EmitLangfuseTurn instead.
//
// Best-effort: any error fetching the message rows is logged and
// dropped — losing a trace beats blocking the next SendMessage.
func (s *Service) emitLangfuseAssistantTurn(
	ctx context.Context,
	userID uuid.UUID,
	conversationID uuid.UUID,
	contextID uuid.UUID,
	providerID uuid.UUID,
	assistantMsgID uuid.UUID,
	spans []ToolSpan,
) {
	if s.langfuse == nil || assistantMsgID == uuid.Nil {
		return
	}

	conv, err := s.queries.GetConversationByID(ctx, conversationID)
	if err != nil {
		s.logger.Debug("langfuse: skipping emit, conversation lookup failed",
			"err", err, "conversation_id", conversationID)
		return
	}

	asst, err := s.queries.GetMessageByID(ctx, assistantMsgID)
	if err != nil {
		s.logger.Debug("langfuse: skipping emit, assistant message lookup failed",
			"err", err, "msg_id", assistantMsgID)
		return
	}
	// Errored runs aren't useful in the timeline and would just add
	// noise — skip both the parent trace AND any buffered spans.
	if len(asst.ErrorPayload) > 0 {
		return
	}

	var userInput string
	startTime := asst.CreatedAt
	if asst.ParentID != nil {
		parent, err := s.queries.GetMessageByID(ctx, *asst.ParentID)
		if err == nil {
			userInput = parent.Content
			startTime = parent.CreatedAt
		} else if !errors.Is(err, pgx.ErrNoRows) {
			s.logger.Debug("langfuse: parent message lookup failed",
				"err", err, "parent_id", *asst.ParentID)
		}
	}
	endTime := asst.CreatedAt

	var providerLabel string
	if providerID != uuid.Nil {
		if provRow, err := s.queries.GetUserModelProvider(ctx, providerID); err == nil {
			providerLabel = provRow.Label
		}
	}

	traceID := assistantMsgID.String()
	tags := []string{}
	if providerLabel != "" {
		tags = append(tags, providerLabel)
	}
	if asst.ModelID != nil && *asst.ModelID != "" {
		tags = append(tags, *asst.ModelID)
	}
	metadata := map[string]any{
		"conversation_id":  conv.ID.String(),
		"context_id":       contextID.String(),
		"profile_id":       conv.ProfileID.String(),
		"assistant_msg_id": assistantMsgID.String(),
	}
	if asst.ProviderID != nil {
		metadata["provider_id"] = asst.ProviderID.String()
	}
	if asst.ModelID != nil {
		metadata["model_id"] = *asst.ModelID
	}
	if providerLabel != "" {
		metadata["provider_label"] = providerLabel
	}

	traceName := truncateLangfuseName(strings.TrimSpace(userInput), 80)
	if traceName == "" {
		traceName = "(reeve turn)"
	}

	trace := langfuse.Trace{
		ID:        traceID,
		Name:      traceName,
		UserID:    conv.UserID.String(),
		SessionID: conv.ID.String(),
		Input:     userInput,
		Output:    asst.Content,
		StartTime: startTime,
		EndTime:   endTime,
		Metadata:  metadata,
		Tags:      tags,
	}

	genName := "generation"
	if asst.ModelID != nil && *asst.ModelID != "" {
		genName = *asst.ModelID
	}
	gen := langfuse.Generation{
		ID:               assistantMsgID.String() + ":gen",
		TraceID:          traceID,
		Name:             genName,
		Input:            userInput,
		Output:           asst.Content,
		StartTime:        startTime,
		EndTime:          endTime,
		PromptTokens:     int32PtrToInt(asst.InputTokens),
		CompletionTokens: int32PtrToInt(asst.OutputTokens),
		TotalTokens:      sumTotalTokens(asst.InputTokens, asst.OutputTokens),
		CostUSD:          numericToFloat64Ptr(asst.TotalCostUsd),
		Metadata:         metadata,
	}
	if asst.ModelID != nil {
		gen.Model = *asst.ModelID
	}

	s.langfuse.EmitTurn(userID.String(), trace, gen)

	// Tool spans nest under the same trace via traceID. Each tool
	// dispatch fires its own span with input = model-emitted args,
	// output = plugin's JSON return, error level when the call
	// failed. The Langfuse UI renders these as a timeline below the
	// generation so users can see what each tool did + how long it
	// took.
	for i, sp := range spans {
		span := langfuse.Span{
			ID:        fmt.Sprintf("%s:span:%d", assistantMsgID.String(), i),
			TraceID:   traceID,
			Name:      sp.ToolName,
			StartTime: sp.StartedAt,
			EndTime:   sp.EndedAt,
			Input:     rawJSONOrString(sp.Input),
			Output:    rawJSONOrString(sp.Output),
			Metadata: map[string]any{
				"tool_name":      sp.ToolName,
				"conversation_id": conv.ID.String(),
			},
		}
		if sp.ErrorMsg != "" {
			span.Level = "ERROR"
			span.StatusMessage = sp.ErrorMsg
		}
		s.langfuse.EmitSpan(userID.String(), span)
	}
}

// EmitLangfuseTurn is the legacy zero-spans entry point. Kept so
// the process-wide hook surface (OnAssistantPersisted, used for
// auto-title) stays compatible; new call sites should prefer
// emitLangfuseAssistantTurn which threads buffered tool spans.
//
// In practice this is now unused as a process-wide hook (the
// per-run hook does the assistant emit so it can include spans),
// but kept exported for testing and potential future re-wiring.
func (s *Service) EmitLangfuseTurn(ctx context.Context, params stream.StartParams, assistantMsgID uuid.UUID) {
	if s.langfuse == nil {
		return
	}
	conv, err := s.queries.GetConversationByID(ctx, params.ConversationID)
	if err != nil {
		return
	}
	s.emitLangfuseAssistantTurn(ctx, conv.UserID, params.ConversationID, params.ContextID, params.ProviderID, assistantMsgID, nil)
}

// emitLangfuseTitleCall fires a separate Langfuse trace tagged
// "title" for an auto-title generation. Same session as the parent
// conversation so users see all activity together; trace ID is
// derived from the assistant message ID + a "title" suffix so it
// doesn't collide with the assistant turn's own trace.
//
// Skipped silently when Langfuse isn't configured or the call
// happened before a successful generation.
func (s *Service) emitLangfuseTitleCall(
	userID uuid.UUID,
	conversationID uuid.UUID,
	assistantMsgID uuid.UUID,
	providerID uuid.UUID,
	modelID string,
	transcript string,
	output string,
	startedAt, endedAt time.Time,
) {
	if s.langfuse == nil {
		return
	}
	traceID := assistantMsgID.String() + ":title"
	metadata := map[string]any{
		"conversation_id": conversationID.String(),
		"trigger":         "auto_title",
		"model_id":        modelID,
	}
	if providerID != uuid.Nil {
		metadata["provider_id"] = providerID.String()
	}
	trace := langfuse.Trace{
		ID:        traceID,
		Name:      "title · " + truncateLangfuseName(output, 60),
		UserID:    userID.String(),
		SessionID: conversationID.String(),
		Input:     transcript,
		Output:    output,
		StartTime: startedAt,
		EndTime:   endedAt,
		Metadata:  metadata,
		Tags:      []string{"title"},
	}
	gen := langfuse.Generation{
		ID:        traceID + ":gen",
		TraceID:   traceID,
		Name:      modelID,
		Model:     modelID,
		Input:     transcript,
		Output:    output,
		StartTime: startedAt,
		EndTime:   endedAt,
		Metadata:  metadata,
	}
	s.langfuse.EmitTurn(userID.String(), trace, gen)
}

// emitLangfuseCompressionTurn fires a separate Langfuse trace
// tagged "compression" for a Compact run. The summaryMsgID is the
// just-materialised compression_summary message; its row carries
// the usage / cost data the generation event needs.
//
// Same session as the parent conversation so the compression
// shows up in the chat timeline alongside the regular turns.
func (s *Service) emitLangfuseCompressionTurn(
	ctx context.Context,
	userID uuid.UUID,
	conversationID uuid.UUID,
	contextID uuid.UUID,
	summaryMsgID uuid.UUID,
) {
	if s.langfuse == nil || summaryMsgID == uuid.Nil {
		return
	}
	row, err := s.queries.GetMessageByID(ctx, summaryMsgID)
	if err != nil {
		s.logger.Debug("langfuse: compression message lookup failed", "err", err, "msg_id", summaryMsgID)
		return
	}
	if len(row.ErrorPayload) > 0 {
		// Errored compactions don't carry useful turn semantics;
		// skip the trace.
		return
	}
	traceID := summaryMsgID.String() + ":compaction"
	metadata := map[string]any{
		"conversation_id":      conversationID.String(),
		"context_id":           contextID.String(),
		"compression_msg_id":   summaryMsgID.String(),
	}
	if row.ProviderID != nil {
		metadata["provider_id"] = row.ProviderID.String()
	}
	if row.ModelID != nil {
		metadata["model_id"] = *row.ModelID
	}
	startTime := row.CreatedAt
	endTime := row.CreatedAt
	trace := langfuse.Trace{
		ID:        traceID,
		Name:      "compression · " + truncateLangfuseName(row.Content, 60),
		UserID:    userID.String(),
		SessionID: conversationID.String(),
		Output:    row.Content,
		StartTime: startTime,
		EndTime:   endTime,
		Metadata:  metadata,
		Tags:      []string{"compression"},
	}
	gen := langfuse.Generation{
		ID:               traceID + ":gen",
		TraceID:          traceID,
		Name:             "compression",
		Output:           row.Content,
		StartTime:        startTime,
		EndTime:          endTime,
		PromptTokens:     int32PtrToInt(row.InputTokens),
		CompletionTokens: int32PtrToInt(row.OutputTokens),
		TotalTokens:      sumTotalTokens(row.InputTokens, row.OutputTokens),
		CostUSD:          numericToFloat64Ptr(row.TotalCostUsd),
		Metadata:         metadata,
	}
	if row.ModelID != nil {
		gen.Model = *row.ModelID
	}
	s.langfuse.EmitTurn(userID.String(), trace, gen)
}

// OnAssistantPersisted is the composed process-wide supervisor
// hook. Today it just fans out auto-title generation in a
// detached goroutine — the Langfuse emit moved to the per-run
// hook in SendMessage so it can include the buffered tool spans.
func (s *Service) OnAssistantPersisted(ctx context.Context, params stream.StartParams, assistantMsgID uuid.UUID) {
	go s.MaybeGenerateTitle(ctx, params, assistantMsgID)
}

// --- small helpers ---

func int32PtrToInt(v *int32) *int {
	if v == nil {
		return nil
	}
	out := int(*v)
	return &out
}

func sumTotalTokens(in, out *int32) *int {
	if in == nil && out == nil {
		return nil
	}
	var sum int
	if in != nil {
		sum += int(*in)
	}
	if out != nil {
		sum += int(*out)
	}
	return &sum
}

func truncateLangfuseName(s string, n int) string {
	if n <= 0 || len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// rawJSONOrString prefers to emit raw JSON (so Langfuse renders
// the structured input/output natively) and falls back to a
// string when the bytes don't parse. Empty input returns nil so
// the field is omitted.
func rawJSONOrString(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	var probe any
	if err := json.Unmarshal(b, &probe); err == nil {
		return probe
	}
	return string(b)
}
