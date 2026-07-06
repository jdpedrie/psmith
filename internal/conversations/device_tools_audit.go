package conversations

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/internal/devicetools"
	"github.com/jdpedrie/psmith/internal/store"
)

// recordDeviceToolCompletion is the broker's CompletionHook —
// fires once per Invoke (success, error, or timeout) and inserts an
// audit row into device_tool_calls. Best-effort by design: errors
// are logged + dropped so a flaky DB can't poison the tool
// dispatch.
//
// `message_id` is intentionally left NULL for now. The assistant
// message that fired the tool_use doesn't exist as a persisted row
// when the call happens — it lives in the active stream and
// materialises only after the round completes. Future work: stash
// the materialised id on the event when materialisation lands
// (the supervisor's OnAssistantMaterialized hook could backfill).
func (s *Service) recordDeviceToolCompletion(ev devicetools.CompletionEvent) {
	// Background ctx — the broker's caller ctx is gone by the
	// time the hook fires for a timeout case. Bounded by the
	// pgxpool's own connection acquire timeout.
	ctx := context.Background()

	conv, err := s.queries.GetConversationByID(ctx, ev.ConversationID)
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			s.logger.Warn("device-tool audit: load conversation failed",
				"conversation_id", ev.ConversationID,
				"call_id", ev.CallID, "error", err)
		}
		// pgx.ErrNoRows means the conversation got deleted
		// while a tool was in flight. Drop the audit row
		// silently — there's no user to attribute to.
		return
	}

	var errMsg *string
	if ev.ErrorMessage != "" {
		m := ev.ErrorMessage
		errMsg = &m
	}
	if _, err := s.queries.InsertDeviceToolCall(ctx, store.InsertDeviceToolCallParams{
		ID:             ev.CallID,
		UserID:         conv.UserID,
		ConversationID: ev.ConversationID,
		MessageID:      nil, // see docstring
		ToolName:       ev.ToolName,
		InputJson:      ev.Input,
		OutputJson:     ev.Output,
		Status:         ev.Status,
		ErrorMessage:   errMsg,
		InvokedAt:      ev.InvokedAt,
		CompletedAt:    ev.CompletedAt,
	}); err != nil {
		s.logger.Warn("device-tool audit: insert failed",
			"call_id", ev.CallID, "tool", ev.ToolName, "error", err)
		return
	}
}

var _ = uuid.Nil // keep import even when no caller in this file uses uuid
