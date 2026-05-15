package conversations

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/reeve/internal/langfuse"
	"github.com/jdpedrie/reeve/internal/stream"
)

// EmitLangfuseTurn is a per-supervisor AssistantMaterializedHook that
// fires one Trace + one Generation event for the just-materialised
// assistant message. Wired in cmd/reeved alongside MaybeGenerateTitle
// via OnAssistantPersisted (see the composed hook below).
//
// Per-user gating happens inside the Emitter — when the conversation
// owner hasn't configured Langfuse, EmitTurn is a silent no-op (no DB
// hop, no allocation). When they have, the input is the immediate
// user prompt, the output is the assistant's text, and metadata
// carries context_id + profile_id + provider/model so the user can
// filter in the Langfuse UI.
//
// Best-effort: any error fetching the message rows is logged and
// dropped — losing one trace beats blocking title generation or
// other post-materialise work.
func (s *Service) EmitLangfuseTurn(ctx context.Context, params stream.StartParams, assistantMsgID uuid.UUID) {
	if s.langfuse == nil || assistantMsgID == uuid.Nil {
		return
	}

	// Conversation → owner user, used to look up the per-user
	// Langfuse credentials cached on the Emitter.
	conv, err := s.queries.GetConversationByID(ctx, params.ConversationID)
	if err != nil {
		s.logger.Debug("langfuse: skipping emit, conversation lookup failed",
			"err", err, "conversation_id", params.ConversationID)
		return
	}

	asst, err := s.queries.GetMessageByID(ctx, assistantMsgID)
	if err != nil {
		s.logger.Debug("langfuse: skipping emit, assistant message lookup failed",
			"err", err, "msg_id", assistantMsgID)
		return
	}

	// Pull the prompting user message (if any) for the input side
	// of the generation. For the very first turn after a
	// compression, the parent may be a role=context message —
	// that's still useful as input. Errored runs are skipped:
	// they didn't represent a real model exchange and would just
	// add noise to the Langfuse timeline.
	if len(asst.ErrorPayload) > 0 {
		return
	}

	var userInput string
	if asst.ParentID != nil {
		parent, err := s.queries.GetMessageByID(ctx, *asst.ParentID)
		if err == nil {
			userInput = parent.Content
		} else if !errors.Is(err, pgx.ErrNoRows) {
			s.logger.Debug("langfuse: parent message lookup failed",
				"err", err, "parent_id", *asst.ParentID)
		}
	}

	// Resolve the human label for the provider so the trace
	// metadata reads cleanly in the Langfuse UI ("Anthropic"
	// rather than the UUID).
	var providerLabel string
	if params.ProviderID != uuid.Nil {
		if provRow, err := s.queries.GetUserModelProvider(ctx, params.ProviderID); err == nil {
			providerLabel = provRow.Label
		}
	}

	endTime := asst.CreatedAt
	startTime := endTime
	if asst.ParentID != nil {
		// Parent (user message) timestamp gives us the floor of
		// "when did this turn start." Not perfect but better than
		// reporting zero latency.
		if parent, err := s.queries.GetMessageByID(ctx, *asst.ParentID); err == nil {
			startTime = parent.CreatedAt
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
		"conversation_id":    conv.ID.String(),
		"context_id":         params.ContextID.String(),
		"profile_id":         conv.ProfileID.String(),
		"assistant_msg_id":   assistantMsgID.String(),
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

	s.langfuse.EmitTurn(conv.UserID.String(), trace, gen)
}

// OnAssistantPersisted is the composed hook cmd/reeved registers on
// the supervisor. Fans out to MaybeGenerateTitle + EmitLangfuseTurn
// in parallel goroutines so a slow auto-titler doesn't gate Langfuse
// emit (and vice versa). Mirrors the existing per-run hook design —
// the supervisor only knows about one callback and the conversations
// service owns the fan-out internally.
func (s *Service) OnAssistantPersisted(ctx context.Context, params stream.StartParams, assistantMsgID uuid.UUID) {
	go s.MaybeGenerateTitle(ctx, params, assistantMsgID)
	go s.EmitLangfuseTurn(ctx, params, assistantMsgID)
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

// truncateLangfuseName trims a string to n bytes for use as a
// Langfuse trace name. The Langfuse UI shows names in a narrow
// column; long inputs read better as ellipsis-truncated. Lives
// here (not as a generic helper) because the existing `truncate`
// in service_plugins_e2e_test.go has different semantics; keeping
// them apart avoids accidental coupling.
func truncateLangfuseName(s string, n int) string {
	if n <= 0 || len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
