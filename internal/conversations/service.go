// Package conversations implements the ConversationsService Connect handler.
// It owns CRUD and the read surface for conversations, contexts, and messages,
// plus the SendMessage / Compact integrations that wire history-builder +
// stream supervisor + provider drivers.
package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/types/known/timestamppb"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/gen/clark/v1/clarkv1connect"
	"github.com/jdpedrie/clark/internal/auth"
	"github.com/jdpedrie/clark/internal/history"
	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/profiles"
	"github.com/jdpedrie/clark/internal/providers"
	"github.com/jdpedrie/clark/internal/store"
	"github.com/jdpedrie/clark/internal/stream"
	"github.com/jdpedrie/clark/plugins"
)

// MaxListPageSize caps page_size in ListConversations regardless of what the
// client requests.
const MaxListPageSize = 100

// Service implements clarkv1connect.ConversationsServiceHandler.
//
// catalog, supervisor, logger may be nil when only CRUD is exercised
// (e.g., older tests). SendMessage / Compact require all three plus pool
// (for the per-context-row lock that serializes concurrent sends).
type Service struct {
	clarkv1connect.UnimplementedConversationsServiceHandler
	queries    *store.Queries
	pool       *pgxpool.Pool
	catalog    modelmeta.Catalog
	supervisor *stream.Supervisor
	logger     *slog.Logger
}

// NewService builds a Service. catalog/supervisor/logger/pool may be nil for
// tests that only exercise CRUD; SendMessage and Compact require all four.
// pool is used to begin transactions for the SendMessage critical section
// (resolve-parent → insert-user-message → advance-cursor) so concurrent
// sends on the same context serialize correctly via SELECT FOR UPDATE on
// the contexts row.
func NewService(queries *store.Queries, pool *pgxpool.Pool, catalog modelmeta.Catalog, supervisor *stream.Supervisor, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{
		queries:    queries,
		pool:       pool,
		catalog:    catalog,
		supervisor: supervisor,
		logger:     logger,
	}
}

// --- CreateConversation ---

func (s *Service) CreateConversation(ctx context.Context, req *connect.Request[clarkv1.CreateConversationRequest]) (*connect.Response[clarkv1.CreateConversationResponse], error) {
	caller := auth.MustFromContext(ctx)

	profileID, err := uuid.Parse(req.Msg.ProfileId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid profile_id: %w", err))
	}

	// Profile must exist and belong to the caller. Use NotFound for cross-user
	// access to avoid leaking existence; InvalidArgument for the not-exists
	// case so it's distinguishable from a "you don't own this" path that
	// looked the same to begin with — actually, treat both as InvalidArgument
	// here to keep symmetry with profiles.fetchOwned-style cross-user denial.
	// Per the task brief: nonexistent profile = InvalidArgument or NotFound;
	// cross-user must look like NotFound. We collapse both into NotFound on
	// the profile lookup to maintain consistency with the rest of the
	// service.
	profile, err := s.queries.GetProfileByID(ctx, profileID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("profile not found"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if profile.UserID != caller.ID {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("profile not found"))
	}

	// Resolve via the parent chain so we snapshot inherited fields.
	resolved, err := profiles.Resolve(ctx, s.queries, profile)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("resolve profile: %w", err))
	}

	settingsJSON, err := settingsToJSON(req.Msg.Settings)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Resolve the plugin pipeline so seed messages can populate display_content.
	pipeline, err := s.resolvePluginPipeline(ctx, profileID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	convoID, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	convoRow, err := s.queries.CreateConversation(ctx, store.CreateConversationParams{
		ID:        convoID,
		UserID:    caller.ID,
		ProfileID: profileID,
		Title:     req.Msg.Title,
		Settings:  settingsJSON,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	contextID, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	now := time.Now().UTC()
	contextRow, err := s.queries.CreateContext(ctx, store.CreateContextParams{
		ID:                    contextID,
		ConversationID:        convoID,
		ParentContextID:       nil,
		ContextActivationTime: now,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Snapshot seed messages from the resolved profile.
	seeds := make([]*clarkv1.Message, 0, 2)
	var systemMsgID *uuid.UUID
	if resolved.SystemMessage != nil && *resolved.SystemMessage != "" {
		id, err := uuid.NewV7()
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		row, err := s.queries.CreateMessage(ctx, store.CreateMessageParams{
			ID:        id,
			ContextID: contextID,
			ParentID:  nil,
			Role:      roleSystem,
			Content:   *resolved.SystemMessage,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		systemMsgID = &row.ID
		seedProto := messageToProto(row)
		applyDisplay(seedProto, pipeline)
		seeds = append(seeds, seedProto)
	}
	if resolved.DefaultUserMessage != nil && *resolved.DefaultUserMessage != "" {
		id, err := uuid.NewV7()
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		row, err := s.queries.CreateMessage(ctx, store.CreateMessageParams{
			ID:        id,
			ContextID: contextID,
			ParentID:  systemMsgID, // null when there's no system message
			Role:      roleContext,
			Content:   *resolved.DefaultUserMessage,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		seedProto := messageToProto(row)
		applyDisplay(seedProto, pipeline)
		seeds = append(seeds, seedProto)
	}

	convoProto, err := conversationToProto(convoRow, contextRow.ID.String())
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.CreateConversationResponse{
		Conversation:   convoProto,
		InitialContext: contextToProto(contextRow),
		SeedMessages:   seeds,
	}), nil
}

// --- ListConversations ---

func (s *Service) ListConversations(ctx context.Context, req *connect.Request[clarkv1.ListConversationsRequest]) (*connect.Response[clarkv1.ListConversationsResponse], error) {
	caller := auth.MustFromContext(ctx)

	// page_token is documented as ignored for v1 — all rows fit in one page.
	// page_size is honored as a cap (clamped to MaxListPageSize).
	rows, err := s.queries.ListConversationsByUser(ctx, caller.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	limit := int(req.Msg.PageSize)
	if limit <= 0 || limit > MaxListPageSize {
		limit = MaxListPageSize
	}
	if len(rows) > limit {
		rows = rows[:limit]
	}

	out := make([]*clarkv1.Conversation, 0, len(rows))
	for _, r := range rows {
		// active_context_id is left empty in list responses — clients can
		// fetch the full conversation via GetConversation when they need it.
		// Avoids N+1 round trips on the list path.
		p, err := conversationToProto(r, "")
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		out = append(out, p)
	}
	return connect.NewResponse(&clarkv1.ListConversationsResponse{Conversations: out}), nil
}

// --- GetConversation ---

func (s *Service) GetConversation(ctx context.Context, req *connect.Request[clarkv1.GetConversationRequest]) (*connect.Response[clarkv1.GetConversationResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}
	row, err := s.fetchOwnedConversation(ctx, id, caller.ID)
	if err != nil {
		return nil, err
	}

	active, err := s.queries.GetActiveContextByConversation(ctx, row.ID)
	if err != nil {
		// A conversation should always have at least one context (created in
		// CreateConversation). A missing one indicates schema corruption or a
		// failed create — surface as Internal.
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeInternal, errors.New("conversation has no contexts"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	convoProto, err := conversationToProto(row, active.ID.String())
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.GetConversationResponse{
		Conversation:  convoProto,
		ActiveContext: contextToProto(active),
	}), nil
}

// --- UpdateConversation ---

func (s *Service) UpdateConversation(ctx context.Context, req *connect.Request[clarkv1.UpdateConversationRequest]) (*connect.Response[clarkv1.UpdateConversationResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}
	if _, err := s.fetchOwnedConversation(ctx, id, caller.ID); err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, id); err != nil {
		return nil, err
	}

	// Replace semantics: nil = leave alone, non-nil = replace. Empty string
	// title is treated as "set to empty" (which is allowed because title is
	// nullable; an empty string passes through to the column).
	if req.Msg.Title != nil {
		if err := s.queries.UpdateConversationTitle(ctx, store.UpdateConversationTitleParams{
			ID:    id,
			Title: req.Msg.Title,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	if req.Msg.Settings != nil {
		blob, err := settingsToJSON(req.Msg.Settings)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if err := s.queries.UpdateConversationSettings(ctx, store.UpdateConversationSettingsParams{
			ID:       id,
			Settings: blob,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	updated, err := s.queries.GetConversationByID(ctx, id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	active, err := s.queries.GetActiveContextByConversation(ctx, id)
	activeID := ""
	if err == nil {
		activeID = active.ID.String()
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	proto, err := conversationToProto(updated, activeID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.UpdateConversationResponse{Conversation: proto}), nil
}

// --- DeleteConversation ---

func (s *Service) DeleteConversation(ctx context.Context, req *connect.Request[clarkv1.DeleteConversationRequest]) (*connect.Response[clarkv1.DeleteConversationResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}
	if _, err := s.fetchOwnedConversation(ctx, id, caller.ID); err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, id); err != nil {
		return nil, err
	}
	if err := s.queries.DeleteConversation(ctx, id); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.DeleteConversationResponse{}), nil
}

// --- ListContexts ---

func (s *Service) ListContexts(ctx context.Context, req *connect.Request[clarkv1.ListContextsRequest]) (*connect.Response[clarkv1.ListContextsResponse], error) {
	caller := auth.MustFromContext(ctx)

	convoID, err := uuid.Parse(req.Msg.ConversationId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid conversation_id: %w", err))
	}
	if _, err := s.fetchOwnedConversation(ctx, convoID, caller.ID); err != nil {
		return nil, err
	}

	rows, err := s.queries.ListContextsByConversation(ctx, convoID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*clarkv1.Context, 0, len(rows))
	for _, r := range rows {
		out = append(out, listContextRowToProto(r))
	}
	return connect.NewResponse(&clarkv1.ListContextsResponse{Contexts: out}), nil
}

// --- ActivateContext ---

func (s *Service) ActivateContext(ctx context.Context, req *connect.Request[clarkv1.ActivateContextRequest]) (*connect.Response[clarkv1.ActivateContextResponse], error) {
	caller := auth.MustFromContext(ctx)

	id, err := uuid.Parse(req.Msg.ContextId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid context_id: %w", err))
	}
	_, conv, err := s.fetchOwnedContext(ctx, id, caller.ID)
	if err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	updated, err := s.queries.UpdateContextActivationTime(ctx, store.UpdateContextActivationTimeParams{
		ID:                    id,
		ContextActivationTime: time.Now().UTC(),
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.ActivateContextResponse{Context: contextToProto(updated)}), nil
}

// --- SetCurrentLeaf ---

// SetCurrentLeaf moves the per-context "currently viewing" cursor to the
// specified message. Used by the branch-navigation flow: after a user picks an
// alternate child fork in the UI, the client calls this so the next
// SendMessage parents off the chosen branch (multi-device clients converge on
// the same view).
//
// Pass message_id == "" to clear the cursor (next SendMessage falls back to
// latest by created_at).
func (s *Service) SetCurrentLeaf(ctx context.Context, req *connect.Request[clarkv1.SetCurrentLeafRequest]) (*connect.Response[clarkv1.SetCurrentLeafResponse], error) {
	caller := auth.MustFromContext(ctx)

	cxID, err := uuid.Parse(req.Msg.ContextId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid context_id: %w", err))
	}
	cxRow, conv, err := s.fetchOwnedContext(ctx, cxID, caller.ID)
	if err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	var leafPtr *uuid.UUID
	if req.Msg.MessageId != "" {
		mid, err := uuid.Parse(req.Msg.MessageId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid message_id: %w", err))
		}
		msg, err := s.queries.GetMessageByID(ctx, mid)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
			}
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		// Validate the message belongs to this context — prevents cross-context
		// cursor pointers that would confuse parent resolution and ListMessages.
		if msg.ContextID != cxRow.ID {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("message_id is in a different context"))
		}
		leafPtr = &mid
	}

	updated, err := s.queries.UpdateContextCurrentLeaf(ctx, store.UpdateContextCurrentLeafParams{
		ID:                   cxRow.ID,
		CurrentLeafMessageID: leafPtr,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.SetCurrentLeafResponse{Context: contextToProto(updated)}), nil
}

// --- UpdateContext ---

// UpdateContext edits a context's mutable metadata. Currently just `title`.
// Replace semantics: nil leaves alone, non-nil sets (empty string clears).
// Conversation-lock applies (no in-flight stream).
func (s *Service) UpdateContext(ctx context.Context, req *connect.Request[clarkv1.UpdateContextRequest]) (*connect.Response[clarkv1.UpdateContextResponse], error) {
	caller := auth.MustFromContext(ctx)

	cxID, err := uuid.Parse(req.Msg.ContextId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid context_id: %w", err))
	}
	cxRow, conv, err := s.fetchOwnedContext(ctx, cxID, caller.ID)
	if err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	if req.Msg.Title != nil {
		title := req.Msg.Title
		if *title == "" {
			title = nil // clear
		}
		if err := s.queries.UpdateContextTitle(ctx, store.UpdateContextTitleParams{
			ID: cxID, Title: title,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		// Refresh local copy so the response reflects the new title.
		cxRow.Title = title
	}

	return connect.NewResponse(&clarkv1.UpdateContextResponse{Context: contextToProto(cxRow)}), nil
}

// --- ListMessages ---

func (s *Service) ListMessages(ctx context.Context, req *connect.Request[clarkv1.ListMessagesRequest]) (*connect.Response[clarkv1.ListMessagesResponse], error) {
	caller := auth.MustFromContext(ctx)

	contextID, err := uuid.Parse(req.Msg.ContextId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid context_id: %w", err))
	}
	activeCtx, conv, err := s.fetchOwnedContext(ctx, contextID, caller.ID)
	if err != nil {
		return nil, err
	}
	pipeline, err := s.resolvePipelineForConversation(ctx, conv)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Resolve the leaf to walk the ancestor chain from. Priority:
	//   1. caller-supplied leaf_message_id (validated below)
	//   2. context.current_leaf_message_id (the active tip after each send)
	//   3. GetContextLeafMessage — for contexts whose leaf hasn't been set yet
	//      (e.g. freshly promoted compaction contexts that only have seed rows)
	// Messages are always returned via the recursive ancestor-chain CTE so the
	// order reflects the parent→child relationship, not insertion timestamps.
	var leafID uuid.UUID
	if req.Msg.LeafMessageId != nil {
		leafID, err = uuid.Parse(*req.Msg.LeafMessageId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid leaf_message_id: %w", err))
		}
		// Validate the leaf belongs to this context before walking the chain.
		leaf, err := s.queries.GetMessageByID(ctx, leafID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, connect.NewError(connect.CodeNotFound, errors.New("leaf_message_id not found"))
			}
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if leaf.ContextID != contextID {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("leaf_message_id does not belong to context_id"))
		}
	} else if activeCtx.CurrentLeafMessageID != nil {
		leafID = *activeCtx.CurrentLeafMessageID
	} else {
		// No explicit leaf and no tracked tip — find the natural leaf of the
		// context's message tree (the message that nothing else points at as a
		// parent). Returns no rows for a truly empty context.
		leaf, err := s.queries.GetContextLeafMessage(ctx, contextID)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return connect.NewResponse(&clarkv1.ListMessagesResponse{}), nil
			}
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		leafID = leaf.ID
	}

	rows, err := s.queries.ListMessageAncestorChain(ctx, leafID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*clarkv1.Message, 0, len(rows))
	for _, r := range rows {
		proto := chainRowToProto(r)
		applyDisplay(proto, pipeline)
		out = append(out, proto)
	}
	return connect.NewResponse(&clarkv1.ListMessagesResponse{Messages: out}), nil
}

// --- GetMessage ---

func (s *Service) GetMessage(ctx context.Context, req *connect.Request[clarkv1.GetMessageRequest]) (*connect.Response[clarkv1.GetMessageResponse], error) {
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
	// Walk message → context → conversation to verify ownership.
	_, conv, err := s.fetchOwnedContext(ctx, msg.ContextID, caller.ID)
	if err != nil {
		// Map underlying NotFound (cross-user/missing context) to a message-shaped error.
		var ce *connect.Error
		if errors.As(err, &ce) && ce.Code() == connect.CodeNotFound {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("message not found"))
		}
		return nil, err
	}
	pipeline, err := s.resolvePipelineForConversation(ctx, conv)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	proto := messageToProto(msg)
	applyDisplay(proto, pipeline)
	return connect.NewResponse(&clarkv1.GetMessageResponse{Message: proto}), nil
}

// --- helpers ---

// fetchOwnedConversation loads a conversation and asserts ownership by the
// caller. Returns NotFound for missing or cross-user rows; existence is not
// leaked.
func (s *Service) fetchOwnedConversation(ctx context.Context, id, userID uuid.UUID) (store.Conversation, error) {
	row, err := s.queries.GetConversationByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return store.Conversation{}, connect.NewError(connect.CodeNotFound, errors.New("conversation not found"))
		}
		return store.Conversation{}, connect.NewError(connect.CodeInternal, err)
	}
	if row.UserID != userID {
		return store.Conversation{}, connect.NewError(connect.CodeNotFound, errors.New("conversation not found"))
	}
	return row, nil
}

// fetchOwnedContext loads a context and the conversation it belongs to,
// asserting that the caller owns the conversation. Returns NotFound on
// missing-or-cross-user with a "context not found" message — same don't-leak
// posture as fetchOwnedConversation.
func (s *Service) fetchOwnedContext(ctx context.Context, id, userID uuid.UUID) (store.Context, store.Conversation, error) {
	row, err := s.queries.GetContextByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return store.Context{}, store.Conversation{}, connect.NewError(connect.CodeNotFound, errors.New("context not found"))
		}
		return store.Context{}, store.Conversation{}, connect.NewError(connect.CodeInternal, err)
	}
	convo, err := s.queries.GetConversationByID(ctx, row.ConversationID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Orphaned context — schema invariant violated; treat as not found.
			return store.Context{}, store.Conversation{}, connect.NewError(connect.CodeNotFound, errors.New("context not found"))
		}
		return store.Context{}, store.Conversation{}, connect.NewError(connect.CodeInternal, err)
	}
	if convo.UserID != userID {
		return store.Context{}, store.Conversation{}, connect.NewError(connect.CodeNotFound, errors.New("context not found"))
	}
	return row, convo, nil
}

// ---------------------------------------------------------------------------
// SendMessage / Compact / CountContextTokens (Round 3 integration)
// ---------------------------------------------------------------------------

// SendMessage initiates a turn. Synchronously creates the user message and the
// stream_run, then returns. Client subscribes to the stream via StreamsService.
func (s *Service) SendMessage(ctx context.Context, req *connect.Request[clarkv1.SendMessageRequest]) (*connect.Response[clarkv1.SendMessageResponse], error) {
	if s.supervisor == nil || s.catalog == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("SendMessage requires supervisor + catalog dependencies"))
	}
	if req.Msg.Content == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("content is required"))
	}
	user := auth.MustFromContext(ctx)

	convID, err := uuid.Parse(req.Msg.ConversationId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid conversation_id: %w", err))
	}
	conv, err := s.fetchOwnedConversation(ctx, convID, user.ID)
	if err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	activeCtx, err := s.queries.GetActiveContextByConversation(ctx, conv.ID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("conversation has no active context"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := s.requireNoPendingCompactionSummary(ctx, activeCtx.ID); err != nil {
		return nil, err
	}

	// Resolve provider/model from request → conversation settings → profile defaults.
	providerID, modelID, err := s.resolveProviderModel(ctx, conv, req.Msg)
	if err != nil {
		return nil, err
	}

	// Validate the provider belongs to the caller and the model is enabled on it.
	provRow, err := s.queries.GetUserModelProvider(ctx, providerID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("provider not found"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if provRow.UserID != user.ID {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("provider not found"))
	}
	enabledModel, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: providerID,
		ModelID:             modelID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("model %q is not enabled on this provider", modelID))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Critical section: resolve parent → insert user message → advance cursor,
	// all serialized via SELECT FOR UPDATE on the contexts row. Without this,
	// concurrent SendMessages on the same context race: the second's
	// resolveParent fallback can read the first's just-inserted user row
	// before the first's cursor advances, producing a chain instead of
	// siblings. The lock is held only for these three DB operations — the
	// slow driver.Send (HTTP to upstream LLM) happens after Commit so we
	// never block other requests on network I/O.
	if s.pool == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("SendMessage requires pool dependency"))
	}
	userMsgID, err := uuid.NewV7()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	var userMsgRow store.Message
	{
		tx, err := s.pool.Begin(ctx)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
		}
		// Defer rollback; commit-success is a no-op rollback by pgx.
		defer func() { _ = tx.Rollback(context.Background()) }()
		qtx := s.queries.WithTx(tx)

		// Lock the contexts row. Re-read activeCtx through the TX so we see
		// any concurrent UpdateContextCurrentLeaf committed before we got the lock.
		lockedCtx, err := qtx.GetContextByIDForUpdate(ctx, activeCtx.ID)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("lock context: %w", err))
		}

		// Resolve the parent message id. Chain (under the row lock):
		//   1. caller-specified parent_message_id (explicit fork or continue)
		//   2. context.current_leaf_message_id (server-tracked cursor)
		//   3. latest message in the active context (fallback for fresh contexts)
		parentMessageID, err := s.resolveParent(ctx, qtx, lockedCtx, req.Msg.ParentMessageId)
		if err != nil {
			return nil, err
		}

		row, err := qtx.CreateMessage(ctx, store.CreateMessageParams{
			ID:        userMsgID,
			ContextID: lockedCtx.ID,
			ParentID:  parentMessageID,
			Role:      "user",
			Content:   req.Msg.Content,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		userMsgRow = row

		// Advance the per-context cursor to the just-inserted user message.
		// Inside the TX so the next concurrent SendMessage observing this
		// row will see the advanced cursor.
		if _, err := qtx.UpdateContextCurrentLeaf(ctx, store.UpdateContextCurrentLeafParams{
			ID:                   lockedCtx.ID,
			CurrentLeafMessageID: &row.ID,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("advance cursor: %w", err))
		}

		if err := tx.Commit(ctx); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
		}
	}

	// Build the driver instance for this provider.
	driver, err := providers.Build(provRow.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, provRow.Config)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build driver: %w", err))
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("driver %q is not a stateless provider; stateful harness sends are not yet wired", provRow.Type))
	}

	// Resolve the chat-plugin pipeline once, then thread it into history.Build
	// (for SystemPrompter + HistoryTransformer) and into the SendMessage
	// response (for DisplayTransformer on the just-inserted user message).
	pipeline, err := s.resolvePipelineForConversation(ctx, conv)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("resolve plugin pipeline: %w", err))
	}

	// Build the wire prefix from history, ending at the just-inserted user message.
	includeThinking := s.resolveIncludeThinking(ctx, conv)
	wireMessages, err := history.Build(ctx, s.queries, history.Params{
		Conversation:     conv,
		LeafMessageID:    &userMsgRow.ID,
		DestProviderType: provRow.Type,
		IncludeThinking:  includeThinking,
		Plugins:          pipeline,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("build history: %w", err))
	}

	// Resolve effective call settings: defaults from the enabled model, overlaid by per-turn request settings.
	callSettings := mergeCallSettings(decodeCallSettingsBytes(enabledModel.DefaultSettings), protoCallSettingsToProvider(req.Msg.CallSettings))

	// Detach the driver from the HTTP request context so the upstream stream
	// outlives the request — the supervisor goroutine owns the consumption
	// lifecycle and only StreamsService.Cancel should kill an in-flight run.
	// We keep the request ctx's values (auth, logging) via WithoutCancel.
	driverCtx := context.WithoutCancel(ctx)
	srcCh, err := stateless.Send(driverCtx, providers.SendRequest{
		ModelID:  modelID,
		Messages: wireMessages,
		Settings: callSettings,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("driver send: %w", err))
	}

	// Hand the chunk channel to the supervisor; it persists chunks, fans out to subscribers,
	// and materializes the assistant message when the stream terminates.
	// Cache observability: hash the prefix and (if there's a previous turn for
	// this context) compute the stable-prefix length + trailing-edge depth.
	// Failure here is non-fatal — diagnostics, not correctness — so we log and
	// continue rather than aborting the send.
	cacheObs, cacheErr := observePrefixCache(ctx, s.queries, activeCtx.ID, wireMessages)
	if cacheErr != nil {
		s.logger.Warn("cache observation failed", "err", cacheErr, "context_id", activeCtx.ID)
	}

	runID, err := s.supervisor.Start(ctx, stream.StartParams{
		ConversationID:  conv.ID,
		ContextID:       activeCtx.ID,
		ParentMessageID: &userMsgRow.ID,
		ProviderID:      providerID,
		ModelID:         modelID,
		Purpose:         stream.PurposeAssistantResponse,
		Source:          srcCh,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("start stream: %w", err))
	}

	// Persist cache observability onto the freshly-created stream_run row so
	// subsequent turns can compare against it. Same non-fatal posture as the
	// observation step itself.
	if cacheErr == nil {
		if err := recordPrefixObservation(ctx, s.queries, runID, cacheObs); err != nil {
			s.logger.Warn("record prefix observation failed", "err", err, "run_id", runID)
		}
	}

	runRow, err := s.supervisor.Get(ctx, runID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	userProto := messageToProto(userMsgRow)
	applyDisplay(userProto, pipeline)
	return connect.NewResponse(&clarkv1.SendMessageResponse{
		UserMessage: userProto,
		StreamRun:   streamRunToProto(runRow),
	}), nil
}

// resolveProviderModel walks the per-turn → conversation → profile chain to
// determine which provider/model to use. Both ids must be set together.
func (s *Service) resolveProviderModel(ctx context.Context, conv store.Conversation, msg *clarkv1.SendMessageRequest) (uuid.UUID, string, error) {
	// Per-turn override.
	if msg.ProviderId != nil || msg.ModelId != nil {
		if msg.ProviderId == nil || msg.ModelId == nil {
			return uuid.Nil, "", connect.NewError(connect.CodeInvalidArgument, errors.New("provider_id and model_id must be set together"))
		}
		pid, err := uuid.Parse(*msg.ProviderId)
		if err != nil {
			return uuid.Nil, "", connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid provider_id: %w", err))
		}
		return pid, *msg.ModelId, nil
	}

	// Conversation settings.
	if conv.Settings != nil {
		var settings clarkv1.ConversationSettings
		if err := json.Unmarshal(conv.Settings, &settings); err == nil {
			if settings.DefaultProviderId != nil && settings.DefaultModelId != nil {
				pid, err := uuid.Parse(*settings.DefaultProviderId)
				if err == nil {
					return pid, *settings.DefaultModelId, nil
				}
			}
		}
	}

	// Profile defaults (resolved through inheritance).
	profile, err := s.queries.GetProfileByID(ctx, conv.ProfileID)
	if err != nil {
		return uuid.Nil, "", connect.NewError(connect.CodeInternal, fmt.Errorf("load profile: %w", err))
	}
	resolved, err := profiles.Resolve(ctx, s.queries, profile)
	if err != nil {
		return uuid.Nil, "", connect.NewError(connect.CodeInternal, fmt.Errorf("resolve profile: %w", err))
	}
	if resolved.DefaultSettings != nil {
		var defaults clarkv1.ProfileDefaults
		if err := json.Unmarshal(resolved.DefaultSettings, &defaults); err == nil {
			if defaults.DefaultProviderId != nil && defaults.DefaultModelId != nil {
				pid, err := uuid.Parse(*defaults.DefaultProviderId)
				if err == nil {
					return pid, *defaults.DefaultModelId, nil
				}
			}
		}
	}

	return uuid.Nil, "", connect.NewError(connect.CodeInvalidArgument,
		errors.New("no provider/model resolved (set per-turn, conversation default, or profile default)"))
}

// resolveIncludeThinking walks conversation settings → profile defaults, default false.
func (s *Service) resolveIncludeThinking(ctx context.Context, conv store.Conversation) bool {
	if conv.Settings != nil {
		var settings clarkv1.ConversationSettings
		if err := json.Unmarshal(conv.Settings, &settings); err == nil && settings.IncludeThinkingInHistory != nil {
			return *settings.IncludeThinkingInHistory
		}
	}
	profile, err := s.queries.GetProfileByID(ctx, conv.ProfileID)
	if err != nil {
		return false
	}
	resolved, err := profiles.Resolve(ctx, s.queries, profile)
	if err != nil {
		return false
	}
	if resolved.DefaultSettings != nil {
		var defaults clarkv1.ProfileDefaults
		if err := json.Unmarshal(resolved.DefaultSettings, &defaults); err == nil && defaults.IncludeThinkingInHistory != nil {
			return *defaults.IncludeThinkingInHistory
		}
	}
	return false
}

// resolveParent picks the parent message id for a new user message. Resolution
// chain:
//
//  1. caller-specified parent_message_id (validated to live in this context).
//  2. activeCtx.CurrentLeafMessageID — the server-tracked cursor.
//  3. latest message in this context by created_at — fallback for fresh
//     contexts (and for cursors cleared by ON DELETE SET NULL).
//
// Returns nil when the context has no messages at all (the user message
// will be a root).
//
// q is passed explicitly so callers can run resolveParent inside a
// transaction (SendMessage uses the TX-bound queries to read the locked
// contexts row + the most-recent committed messages).
func (s *Service) resolveParent(ctx context.Context, q *store.Queries, activeCtx store.Context, requested *string) (*uuid.UUID, error) {
	if requested != nil {
		pid, err := uuid.Parse(*requested)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid parent_message_id: %w", err))
		}
		msg, err := q.GetMessageByID(ctx, pid)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, connect.NewError(connect.CodeNotFound, errors.New("parent_message_id not found"))
			}
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if msg.ContextID != activeCtx.ID {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("parent_message_id is in a different context"))
		}
		return &pid, nil
	}
	if activeCtx.CurrentLeafMessageID != nil {
		pid := *activeCtx.CurrentLeafMessageID
		return &pid, nil
	}
	// Fallback: pick the latest message in the active context as the chronological tip.
	all, err := q.ListMessagesByContext(ctx, activeCtx.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if len(all) == 0 {
		return nil, nil
	}
	// ListMessagesByContext is ordered by created_at ASC; take the last.
	tip := all[len(all)-1]
	return &tip.ID, nil
}

// ---------------------------------------------------------------------------
// settings translation
// ---------------------------------------------------------------------------

// providerCallSettingsJSON mirrors providers.CallSettings JSON shape used by
// modelproviders.encodeCallSettings, so we can decode user_models.default_settings.
type providerCallSettingsJSON struct {
	Temperature          *float64        `json:"temperature,omitempty"`
	MaxOutputTokens      *int            `json:"max_output_tokens,omitempty"`
	ThinkingEnabled      *bool           `json:"thinking_enabled,omitempty"`
	ThinkingBudgetTokens *int32          `json:"thinking_budget_tokens,omitempty"`
	Extras               json.RawMessage `json:"extras,omitempty"`
}

func decodeCallSettingsBytes(b []byte) providers.CallSettings {
	if len(b) == 0 {
		return providers.CallSettings{}
	}
	var raw providerCallSettingsJSON
	if err := json.Unmarshal(b, &raw); err != nil {
		return providers.CallSettings{}
	}
	out := providers.CallSettings{
		Temperature:     raw.Temperature,
		MaxOutputTokens: raw.MaxOutputTokens,
		ThinkingEnabled: raw.ThinkingEnabled,
		Extras:          raw.Extras,
	}
	if raw.ThinkingBudgetTokens != nil {
		v := int(*raw.ThinkingBudgetTokens)
		out.ThinkingBudgetTokens = &v
	}
	return out
}

func protoCallSettingsToProvider(s *clarkv1.CallSettings) providers.CallSettings {
	if s == nil {
		return providers.CallSettings{}
	}
	out := providers.CallSettings{
		Temperature:     s.Temperature,
		ThinkingEnabled: s.ThinkingEnabled,
		Extras:          s.Extras,
	}
	if s.MaxOutputTokens != nil {
		v := int(*s.MaxOutputTokens)
		out.MaxOutputTokens = &v
	}
	if s.ThinkingBudgetTokens != nil {
		v := int(*s.ThinkingBudgetTokens)
		out.ThinkingBudgetTokens = &v
	}
	return out
}

// mergeCallSettings overlays per-turn settings on top of model defaults.
// Per-turn fields win where set; unset per-turn fields fall through to defaults.
func mergeCallSettings(defaults, override providers.CallSettings) providers.CallSettings {
	out := defaults
	if override.Temperature != nil {
		out.Temperature = override.Temperature
	}
	if override.MaxOutputTokens != nil {
		out.MaxOutputTokens = override.MaxOutputTokens
	}
	if override.ThinkingEnabled != nil {
		out.ThinkingEnabled = override.ThinkingEnabled
	}
	if override.ThinkingBudgetTokens != nil {
		out.ThinkingBudgetTokens = override.ThinkingBudgetTokens
	}
	if len(override.Extras) > 0 {
		out.Extras = override.Extras
	}
	return out
}

// streamRunToProto converts a store.StreamRun to its proto shape.
func streamRunToProto(r store.StreamRun) *clarkv1.StreamRun {
	out := &clarkv1.StreamRun{
		Id:                r.ID.String(),
		ConversationId:    r.ConversationID.String(),
		ContextId:         r.ContextID.String(),
		ProviderId:        r.ProviderID.String(),
		ModelId:           r.ModelID,
		Status:            statusToProto(r.Status),
		Purpose:           purposeToProto(r.Purpose),
		StartedAt:    timestamppb.New(r.StartedAt),
		ErrorPayload: r.ErrorPayload,
	}
	if r.ParentMessageID != nil {
		s := r.ParentMessageID.String()
		out.ParentMessageId = &s
	}
	if r.EndedAt != nil {
		out.EndedAt = timestamppb.New(*r.EndedAt)
	}
	_ = out.StartedAt // ensure timestamppb import is used in all branches
	if r.ResultMessageID != nil {
		s := r.ResultMessageID.String()
		out.ResultMessageId = &s
	}
	if r.ResultContextID != nil {
		s := r.ResultContextID.String()
		out.ResultContextId = &s
	}
	out.PrefixLength = r.PrefixLength
	out.CacheStablePrefixLength = r.CacheStablePrefixLength
	out.CacheTrailingDepth = r.CacheTrailingDepth
	return out
}

func statusToProto(s string) clarkv1.StreamRunStatus {
	switch s {
	case "running":
		return clarkv1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING
	case "completed":
		return clarkv1.StreamRunStatus_STREAM_RUN_STATUS_COMPLETED
	case "errored":
		return clarkv1.StreamRunStatus_STREAM_RUN_STATUS_ERRORED
	case "cancelled":
		return clarkv1.StreamRunStatus_STREAM_RUN_STATUS_CANCELLED
	case "interrupted":
		return clarkv1.StreamRunStatus_STREAM_RUN_STATUS_INTERRUPTED
	}
	return clarkv1.StreamRunStatus_STREAM_RUN_STATUS_UNSPECIFIED
}

func purposeToProto(p string) clarkv1.StreamRunPurpose {
	switch p {
	case "assistant_response":
		return clarkv1.StreamRunPurpose_STREAM_RUN_PURPOSE_ASSISTANT_RESPONSE
	case "compression":
		return clarkv1.StreamRunPurpose_STREAM_RUN_PURPOSE_COMPRESSION
	}
	return clarkv1.StreamRunPurpose_STREAM_RUN_PURPOSE_UNSPECIFIED
}

// silence "imported and not used" for the time package if helpers above don't reference it directly.
var _ = time.Now

// ---------------------------------------------------------------------------
// Plugin pipeline resolution
// ---------------------------------------------------------------------------

// resolvePluginPipeline walks the profile parent chain looking for the first
// profile with non-empty profile_plugins rows; returns that profile's
// pipeline. If no profile in the chain has any plugins, returns nil. The
// architecture's "all-or-nothing" inheritance: a child with any plugin rows
// overrides its parent's pipeline entirely.
//
// Cycle-protected: a malformed parent_profile_id loop would otherwise hang;
// detected cycles return an error rather than infinite-looping.
func (s *Service) resolvePluginPipeline(ctx context.Context, profileID uuid.UUID) (plugins.Pipeline, error) {
	cur := profileID
	seen := make(map[uuid.UUID]bool)
	for {
		if seen[cur] {
			return nil, fmt.Errorf("plugin resolve: parent-profile cycle at %s", cur)
		}
		seen[cur] = true

		rows, err := s.queries.ListProfilePlugins(ctx, cur)
		if err != nil {
			return nil, fmt.Errorf("list profile plugins: %w", err)
		}
		if len(rows) > 0 {
			specs := make([]plugins.Spec, 0, len(rows))
			for _, r := range rows {
				specs = append(specs, plugins.Spec{Name: r.PluginName, Config: r.Config})
			}
			return plugins.Resolve(specs)
		}

		prof, err := s.queries.GetProfileByID(ctx, cur)
		if err != nil {
			return nil, fmt.Errorf("get profile %s: %w", cur, err)
		}
		if prof.ParentProfileID == nil {
			return nil, nil
		}
		cur = *prof.ParentProfileID
	}
}

// resolvePipelineForConversation is a convenience wrapper that fetches the
// conversation's profile_id and delegates to resolvePluginPipeline.
func (s *Service) resolvePipelineForConversation(ctx context.Context, conv store.Conversation) (plugins.Pipeline, error) {
	return s.resolvePluginPipeline(ctx, conv.ProfileID)
}

// ---------------------------------------------------------------------------
// Compact (user-triggered compression)
// ---------------------------------------------------------------------------

// Compact runs compression on the active context. The flow:
//
//  1. Resolve compression model + guide + mode from the profile inheritance chain.
//     The compression_provider_id, compression_model_id, and compression_guide
//     must all be set on the resolved profile; otherwise FailedPrecondition.
//  2. Render the active context's messages as a transcript and build the
//     compression prompt.
//  3. Hand to the driver and the supervisor with Purpose=Compression.
//  4. Return the stream_run_id immediately. The supervisor's terminal handler
//     dual-writes the compression_summary message in the OLD context (with
//     usage/cost) plus a new Context with the role=context message containing
//     the calculated REPLACE/APPEND content.
func (s *Service) Compact(ctx context.Context, req *connect.Request[clarkv1.CompactRequest]) (*connect.Response[clarkv1.CompactResponse], error) {
	if s.supervisor == nil || s.catalog == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("Compact requires supervisor + catalog dependencies"))
	}
	user := auth.MustFromContext(ctx)

	convID, err := uuid.Parse(req.Msg.ConversationId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid conversation_id: %w", err))
	}
	conv, err := s.fetchOwnedConversation(ctx, convID, user.ID)
	if err != nil {
		return nil, err
	}
	if err := s.requireNoActiveStream(ctx, conv.ID); err != nil {
		return nil, err
	}

	activeCtx, err := s.queries.GetActiveContextByConversation(ctx, conv.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("conversation has no active context"))
	}
	if err := s.requireNoPendingCompactionSummary(ctx, activeCtx.ID); err != nil {
		return nil, err
	}

	// Resolve compression settings from the profile inheritance chain.
	profile, err := s.queries.GetProfileByID(ctx, conv.ProfileID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load profile: %w", err))
	}
	resolved, err := profiles.Resolve(ctx, s.queries, profile)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("resolve profile: %w", err))
	}

	// Apply per-call overrides over the resolved profile values BEFORE the
	// existence checks. Each request field, when set, takes precedence over
	// the inheritance chain. The Compact page in the client uses these to
	// drive a per-invocation prompt + model picker without persisting to the
	// profile (and as a workaround when the profile resolves to a model the
	// user no longer has enabled).
	guide := resolved.CompressionGuide
	if req.Msg.CompressionGuide != nil {
		v := *req.Msg.CompressionGuide
		guide = &v
	}
	var providerID *uuid.UUID
	if resolved.CompressionProviderID != nil {
		providerID = resolved.CompressionProviderID
	}
	if req.Msg.CompressionProviderId != nil {
		pid, err := uuid.Parse(*req.Msg.CompressionProviderId)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid compression_provider_id: %w", err))
		}
		providerID = &pid
	}
	modelID := resolved.CompressionModelID
	if req.Msg.CompressionModelId != nil {
		v := *req.Msg.CompressionModelId
		modelID = &v
	}

	if guide == nil || *guide == "" {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("compression_guide is required (set on profile or request)"))
	}
	if providerID == nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("compression_provider_id is required (set on profile or request)"))
	}
	if modelID == nil || *modelID == "" {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("compression_model_id is required (set on profile or request)"))
	}

	// Validate provider/model ownership + enablement.
	provRow, err := s.queries.GetUserModelProvider(ctx, *providerID)
	if err != nil || provRow.UserID != user.ID {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("compression provider not found"))
	}
	if _, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: provRow.ID,
		ModelID:             *modelID,
	}); err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("compression model %q is not enabled", *modelID))
	}

	// Resolve compression mode (default REPLACE).
	mode := stream.CompressionModeReplace
	if resolved.CompressionMode != nil && *resolved.CompressionMode == "APPEND" {
		mode = stream.CompressionModeAppend
	}

	// Pick the parent for the compression_summary message: cursor or latest message.
	parentID, err := s.resolveParent(ctx, s.queries, activeCtx, nil)
	if err != nil {
		return nil, err
	}

	// Render the active context's messages as a transcript for the compression prompt.
	transcript, err := s.renderTranscript(ctx, activeCtx.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if transcript == "" {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("nothing to compact (active context has no real turns)"))
	}

	// Build the driver and call Send.
	driver, err := providers.Build(provRow.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, provRow.Config)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build compression driver: %w", err))
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("driver %q is not a stateless provider; stateful compression not yet wired", provRow.Type))
	}

	driverCtx := context.WithoutCancel(ctx)
	srcCh, err := stateless.Send(driverCtx, providers.SendRequest{
		ModelID: *modelID,
		Messages: []providers.WireMessage{
			{Role: "system", Content: *guide},
			{Role: "user", Content: "Here is the conversation to compress.\n\n" + transcript + "\n\nProduce the summary."},
		},
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("driver send: %w", err))
	}

	runID, err := s.supervisor.Start(ctx, stream.StartParams{
		ConversationID:  conv.ID,
		ContextID:       activeCtx.ID,
		ParentMessageID: parentID,
		ProviderID:      provRow.ID,
		ModelID:         *modelID,
		Purpose:         stream.PurposeCompression,
		CompressionMode: mode,
		Source:          srcCh,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("start compression stream: %w", err))
	}
	runRow, err := s.supervisor.Get(ctx, runID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&clarkv1.CompactResponse{StreamRun: streamRunToProto(runRow)}), nil
}

// renderTranscript turns the active context's messages into a plain-text
// transcript "[role]: content" suitable for embedding in a compression prompt.
// Skips role=compression_summary rows (they're audit records, not real turns).
func (s *Service) renderTranscript(ctx context.Context, contextID uuid.UUID) (string, error) {
	msgs, err := s.queries.ListMessagesByContext(ctx, contextID)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	for _, m := range msgs {
		if m.Role == roleCompressionSummary {
			continue
		}
		// system/context are framing; include them so the compressor sees the full picture.
		// user/assistant are the conversation proper.
		fmt.Fprintf(&b, "[%s]: %s\n\n", m.Role, m.Content)
	}
	return strings.TrimRight(b.String(), "\n"), nil
}

// ---------------------------------------------------------------------------
// CountContextTokens
// ---------------------------------------------------------------------------

// CountContextTokens builds the wire prefix for the active context and asks
// the destination driver how many tokens it occupies. The UI uses this
// alongside the model's context_window to advise the user when to compact.
//
// Returns Unimplemented if the destination driver doesn't satisfy
// providers.TokenCounter (OpenAI-compat doesn't, currently).
func (s *Service) CountContextTokens(ctx context.Context, req *connect.Request[clarkv1.CountContextTokensRequest]) (*connect.Response[clarkv1.CountContextTokensResponse], error) {
	if s.catalog == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("CountContextTokens requires catalog dependency"))
	}
	user := auth.MustFromContext(ctx)

	cxID, err := uuid.Parse(req.Msg.ContextId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid context_id: %w", err))
	}
	provID, err := uuid.Parse(req.Msg.ProviderId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid provider_id: %w", err))
	}
	if req.Msg.ModelId == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("model_id is required"))
	}

	// Validate ownership through the context → conversation chain.
	cxRow, conv, err := s.fetchOwnedContext(ctx, cxID, user.ID)
	if err != nil {
		return nil, err
	}
	provRow, err := s.queries.GetUserModelProvider(ctx, provID)
	if err != nil || provRow.UserID != user.ID {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("provider not found"))
	}
	enabled, err := s.queries.GetUserModel(ctx, store.GetUserModelParams{
		UserModelProviderID: provRow.ID,
		ModelID:             req.Msg.ModelId,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("model %q is not enabled on this provider", req.Msg.ModelId))
	}

	// Build the wire prefix as if this context were about to be sent to the destination.
	// Use the cursor (or fallback latest) as the leaf so the full prefix is included.
	leafID, err := s.resolveParent(ctx, s.queries, cxRow, nil)
	if err != nil {
		return nil, err
	}
	includeThinking := s.resolveIncludeThinking(ctx, conv)
	wireMessages, err := history.Build(ctx, s.queries, history.Params{
		Conversation:     conv,
		LeafMessageID:    leafID,
		DestProviderType: provRow.Type,
		IncludeThinking:  includeThinking,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("build history: %w", err))
	}

	// Build driver, type-assert to TokenCounter.
	driver, err := providers.Build(provRow.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, provRow.Config)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build driver: %w", err))
	}
	counter, ok := driver.(providers.TokenCounter)
	if !ok {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("driver %q does not implement TokenCounter", provRow.Type))
	}
	count, err := counter.CountTokens(ctx, req.Msg.ModelId, wireMessages)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("count tokens: %w", err))
	}

	// Pull context_window from the user_model snapshot for convenience.
	var ctxWindow int32
	if enabled.ContextWindow != nil {
		ctxWindow = *enabled.ContextWindow
	}
	return connect.NewResponse(&clarkv1.CountContextTokensResponse{
		TokenCount:    int32(count),
		ContextWindow: ctxWindow,
	}), nil
}
