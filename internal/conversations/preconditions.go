package conversations

import (
	"context"
	"errors"
	"fmt"

	"connectrpc.com/connect"
	"github.com/google/uuid"
)

// requireNoActiveStream returns FailedPrecondition when conversationID has any
// stream_run with status='running'. This is the server-side enforcement of
// the UI's "all conversation actions disabled while a stream is in flight"
// rule. Applied at the start of every mutating RPC so the rule holds even
// for non-Spalt clients hitting the API directly.
//
// Reads/listings are NOT gated by this — only mutations.
func (s *Service) requireNoActiveStream(ctx context.Context, conversationID uuid.UUID) error {
	has, err := s.queries.HasRunningStreamForConversation(ctx, conversationID)
	if err != nil {
		return connect.NewError(connect.CodeInternal, fmt.Errorf("check active streams: %w", err))
	}
	if has {
		return connect.NewError(connect.CodeFailedPrecondition,
			errors.New("conversation has a stream in flight; cancel it or wait for it to finish"))
	}
	return nil
}

// requireNoPendingCompactionSummary returns FailedPrecondition when the
// context contains any compression_summary message. SendMessage and Compact
// use this to enforce the two-stage compaction flow: a context with a
// pending summary must have it promoted (PromoteCompactionToNewContext) or
// deleted (DeleteMessage) before more turns can land.
func (s *Service) requireNoPendingCompactionSummary(ctx context.Context, contextID uuid.UUID) error {
	has, err := s.queries.HasCompressionSummaryInContext(ctx, contextID)
	if err != nil {
		return connect.NewError(connect.CodeInternal, fmt.Errorf("check pending summary: %w", err))
	}
	if has {
		return connect.NewError(connect.CodeFailedPrecondition,
			errors.New("context has a pending compaction summary; promote it to a new context or delete it before continuing"))
	}
	return nil
}
