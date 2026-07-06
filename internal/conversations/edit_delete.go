package conversations

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/profiles"
	"github.com/jdpedrie/psmith/internal/store"
)

// nowUTC is a small helper so the call sites read cleanly. time.Now().UTC()
// inline works too; this just gives the intent a name.
func nowUTC() time.Time { return time.Now().UTC() }

// EditMessage mutates a message's content (and optionally its role) in place.
// See proto for the full contract; key constraints:
//   - role is only editable between user and assistant (special roles can't
//     be transmuted into or out of)
//   - rejected when the conversation has any in-flight stream_run
//   - sets edited_at = NOW unconditionally
func (s *Service) EditMessage(ctx context.Context, req *connect.Request[psmithv1.EditMessageRequest]) (*connect.Response[psmithv1.EditMessageResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}

	msg, err := s.queries.GetMessageByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	// Ownership through context → conversation; same not-found masking as
	// GetMessage so cross-user requests look like missing rows.
	_, conv, err := s.fetchOwnedContext(ctx, msg.ContextID, caller.ID)
	if err != nil {
		var ce *connect.Error
		if errors.As(err, &ce) && ce.Code() == connect.CodeNotFound {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
		}
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	// Role override validation.
	var roleOverride *string
	if req.Msg.Role != nil {
		newRoleStr, err := messageRoleToStorage(*req.Msg.Role)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, err)
		}
		if !roleEditable(msg.Role) {
			return nil, connect.NewError(connect.CodeInvalidArgument,
				fmt.Errorf("role of a %s message cannot be changed", msg.Role))
		}
		if !roleEditable(newRoleStr) {
			return nil, connect.NewError(connect.CodeInvalidArgument,
				fmt.Errorf("cannot change role to %s; only user/assistant flips are allowed", newRoleStr))
		}
		roleOverride = &newRoleStr
	}

	updated, err := s.queries.UpdateMessageContentRole(ctx, store.UpdateMessageContentRoleParams{
		ID:      id,
		Content: req.Msg.Content,
		Role:    roleOverride,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("update message: %w", err))
	}

	pipeline, _ := s.resolvePipelineForConversation(ctx, conv)
	proto := messageToProto(updated)
	applyDisplay(proto, pipeline)
	return connect.NewResponse(&psmithv1.EditMessageResponse{Message: proto}), nil
}

// DeleteMessage removes a message. cascade=false stitches direct children to
// the deleted row's parent (filling the gap); cascade=true relies on the
// FK's ON DELETE CASCADE to drop the entire descendant subtree.
//
// Rejected when the conversation has any in-flight stream_run. The client is
// responsible for confirming the destructive action (especially cascade=true).
func (s *Service) DeleteMessage(ctx context.Context, req *connect.Request[psmithv1.DeleteMessageRequest]) (*connect.Response[psmithv1.DeleteMessageResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}

	msg, err := s.queries.GetMessageByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	_, conv, err := s.fetchOwnedContext(ctx, msg.ContextID, caller.ID)
	if err != nil {
		var ce *connect.Error
		if errors.As(err, &ce) && ce.Code() == connect.CodeNotFound {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
		}
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	if req.Msg.Cascade {
		// FK's ON DELETE CASCADE on parent_id removes the descendant subtree.
		if err := s.queries.DeleteMessageByID(ctx, id); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("delete (cascade): %w", err))
		}
		return connect.NewResponse(&psmithv1.DeleteMessageResponse{}), nil
	}

	// Stitch path: reparent direct children to msg.ParentID, THEN delete.
	// Wrap in a TX so a concurrent insert doesn't slip a child between the
	// two statements (it would then point at a deleted parent and the FK
	// CASCADE would still catch it harmlessly, but the TX makes the intent
	// explicit and atomic).
	if s.pool == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("DeleteMessage(cascade=false) requires pool dependency"))
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	qtx := s.queries.WithTx(tx)

	if err := qtx.ReparentChildren(ctx, store.ReparentChildrenParams{
		ParentID:   &id,
		ParentID_2: msg.ParentID,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("reparent children: %w", err))
	}
	if err := qtx.DeleteMessageByID(ctx, id); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("delete (stitch): %w", err))
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}
	return connect.NewResponse(&psmithv1.DeleteMessageResponse{}), nil
}

// PromoteCompactionToNewContext is the second half of the two-stage
// compaction flow. The compression_summary message produced by Compact sits
// in its source context awaiting user review/edit. This RPC creates a NEW
// Context (parent_context_id = source, activation_time = now,
// current_leaf = NULL) and seeds it with a single role=context message
// whose content is computed from the (possibly user-edited) summary using
// the profile's compression_mode (REPLACE | APPEND).
//
// Idempotency is intentionally NOT enforced — calling twice creates two new
// contexts seeded from the same summary, both becoming sequential active
// contexts (one then the other; the latter wins). Useful as "compact and
// branch into two directions."
func (s *Service) PromoteCompactionToNewContext(ctx context.Context, req *connect.Request[psmithv1.PromoteCompactionToNewContextRequest]) (*connect.Response[psmithv1.PromoteCompactionToNewContextResponse], error) {
	caller := auth.MustFromContext(ctx)

	mid, err := uuid.Parse(req.Msg.MessageId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid message_id: %w", err))
	}
	summaryMsg, err := s.queries.GetMessageByID(ctx, mid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if summaryMsg.Role != roleCompressionSummary {
		return nil, connect.NewError(connect.CodeInvalidArgument,
			fmt.Errorf("message is not a compression_summary (role=%s)", summaryMsg.Role))
	}
	sourceCtx, conv, err := s.fetchOwnedContext(ctx, summaryMsg.ContextID, caller.ID)
	if err != nil {
		var ce *connect.Error
		if errors.As(err, &ce) && ce.Code() == connect.CodeNotFound {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
		}
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	// Resolve compression_mode from profile chain (defaulting to REPLACE).
	prof, err := s.queries.GetProfileByID(ctx, conv.ProfileID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load profile: %w", err))
	}
	resolved, err := profiles.Resolve(ctx, s.queries, prof)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("resolve profile: %w", err))
	}
	mode := "REPLACE"
	if resolved.CompressionMode != nil && *resolved.CompressionMode == "APPEND" {
		mode = "APPEND"
	}

	// Compute the framing content for the new context's role=context message.
	framing := summaryMsg.Content
	if mode == "APPEND" {
		prior, err := s.queries.GetContextRoleMessageInContext(ctx, sourceCtx.ID)
		if err == nil {
			framing = prior.Content + "\n\n" + summaryMsg.Content
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("lookup prior context msg: %w", err))
		}
	}

	// Single TX so the new context + its seeded messages land atomically.
	if s.pool == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("PromoteCompactionToNewContext requires pool dependency"))
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	qtx := s.queries.WithTx(tx)

	newCtxID, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	parentID := sourceCtx.ID
	newCtx, err := qtx.CreateContext(ctx, store.CreateContextParams{
		ID:                    newCtxID,
		ConversationID:        conv.ID,
		ParentContextID:       &parentID,
		ContextActivationTime: nowUTC(),
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("create new context: %w", err))
	}

	// Snapshot the profile system message into the new context, mirroring
	// what CreateConversation does. The framing (role=context) message is
	// parented to the system message when one exists.
	var framingParentID *uuid.UUID
	if resolved.SystemMessage != nil && *resolved.SystemMessage != "" {
		sysID, err := uuid.NewV7()
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if _, err := qtx.CreateMessage(ctx, store.CreateMessageParams{
			ID:        sysID,
			ContextID: newCtx.ID,
			ParentID:  nil,
			Role:      roleSystem,
			Content:   *resolved.SystemMessage,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("seed role=system: %w", err))
		}
		framingParentID = &sysID
	}

	framingID, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if _, err := qtx.CreateMessage(ctx, store.CreateMessageParams{
		ID:        framingID,
		ContextID: newCtx.ID,
		ParentID:  framingParentID,
		Role:      roleContext,
		Content:   framing,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("seed role=context: %w", err))
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}

	return connect.NewResponse(&psmithv1.PromoteCompactionToNewContextResponse{
		Context: contextToProto(newCtx),
	}), nil
}

// CreateContextManual creates a fresh active context in an existing
// conversation without going through compression. Mirrors the
// "create context + seed framing + commit" half of
// PromoteCompactionToNewContext, with two differences:
//   - the framing comes from the prior context (APPEND) or is omitted
//     entirely (REPLACE / unspecified) — there's no compression_summary
//     to derive it from
//   - an optional initial user message is seeded so the user lands in
//     the new context with a turn already typed
func (s *Service) CreateContextManual(ctx context.Context, req *connect.Request[psmithv1.CreateContextManualRequest]) (*connect.Response[psmithv1.CreateContextManualResponse], error) {
	caller := auth.MustFromContext(ctx)

	convID, err := uuid.Parse(req.Msg.ConversationId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid conversation_id: %w", err))
	}
	conv, err := s.fetchOwnedConversation(ctx, convID, caller.ID)
	if err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	// Source context = currently-active. APPEND inherits its role=context
	// message verbatim; REPLACE / unspecified leaves the new context
	// without one (system + user_message only).
	activeCtx, err := s.queries.GetActiveContextByConversation(ctx, conv.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("conversation has no active context"))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load active context: %w", err))
	}

	prof, err := s.queries.GetProfileByID(ctx, conv.ProfileID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load profile: %w", err))
	}
	resolved, err := profiles.Resolve(ctx, s.queries, prof)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("resolve profile: %w", err))
	}

	var framing string
	if req.Msg.Mode == psmithv1.CompressionMode_COMPRESSION_MODE_APPEND {
		prior, err := s.queries.GetContextRoleMessageInContext(ctx, activeCtx.ID)
		if err == nil {
			framing = prior.Content
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("lookup prior context msg: %w", err))
		}
	}

	if s.pool == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("CreateContextManual requires pool dependency"))
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	qtx := s.queries.WithTx(tx)

	newCtxID, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	parentID := activeCtx.ID
	newCtx, err := qtx.CreateContext(ctx, store.CreateContextParams{
		ID:                    newCtxID,
		ConversationID:        conv.ID,
		ParentContextID:       &parentID,
		ContextActivationTime: nowUTC(),
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("create new context: %w", err))
	}

	// Seed system message snapshot (mirrors CreateConversation /
	// PromoteCompactionToNewContext).
	var leafID *uuid.UUID
	if resolved.SystemMessage != nil && *resolved.SystemMessage != "" {
		sysID, err := uuid.NewV7()
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if _, err := qtx.CreateMessage(ctx, store.CreateMessageParams{
			ID:        sysID,
			ContextID: newCtx.ID,
			ParentID:  nil,
			Role:      roleSystem,
			Content:   *resolved.SystemMessage,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("seed role=system: %w", err))
		}
		leafID = &sysID
	}

	// Optional role=context message (APPEND mode only, and only if the
	// prior context actually had one).
	if framing != "" {
		framingID, err := uuid.NewV7()
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if _, err := qtx.CreateMessage(ctx, store.CreateMessageParams{
			ID:        framingID,
			ContextID: newCtx.ID,
			ParentID:  leafID,
			Role:      roleContext,
			Content:   framing,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("seed role=context: %w", err))
		}
		leafID = &framingID
	}

	// Optional initial user message.
	var userMsgProto *psmithv1.Message
	initialUser := req.Msg.InitialUserMessage
	if initialUser != "" {
		userID, err := uuid.NewV7()
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		userRow, err := qtx.CreateMessage(ctx, store.CreateMessageParams{
			ID:        userID,
			ContextID: newCtx.ID,
			ParentID:  leafID,
			Role:      roleUser,
			Content:   initialUser,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("seed role=user: %w", err))
		}
		userMsgProto = messageToProto(userRow)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}

	return connect.NewResponse(&psmithv1.CreateContextManualResponse{
		Context:     contextToProto(newCtx),
		UserMessage: userMsgProto,
	}), nil
}

// roleEditable reports whether a stored role can be the source or target of
// EditMessage's role override (only user and assistant qualify).
func roleEditable(role string) bool {
	return role == roleUser || role == roleAssistant
}

// messageRoleToStorage maps the wire enum to the storage string used in the
// messages.role CHECK constraint. Returns an error for unspecified or
// unknown values; callers funnel that into InvalidArgument.
func messageRoleToStorage(r psmithv1.MessageRole) (string, error) {
	switch r {
	case psmithv1.MessageRole_MESSAGE_ROLE_SYSTEM:
		return roleSystem, nil
	case psmithv1.MessageRole_MESSAGE_ROLE_CONTEXT:
		return roleContext, nil
	case psmithv1.MessageRole_MESSAGE_ROLE_USER:
		return roleUser, nil
	case psmithv1.MessageRole_MESSAGE_ROLE_ASSISTANT:
		return roleAssistant, nil
	case psmithv1.MessageRole_MESSAGE_ROLE_COMPRESSION_SUMMARY:
		return roleCompressionSummary, nil
	default:
		return "", fmt.Errorf("unspecified or unknown role")
	}
}
