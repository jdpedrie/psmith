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
	"sync"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/timestamppb"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/gen/reeve/v1/reevev1connect"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/crypto"
	"github.com/jdpedrie/reeve/internal/history"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/protoconv"
	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/storage"
	"github.com/jdpedrie/reeve/internal/store"
	"github.com/jdpedrie/reeve/internal/stream"
	"github.com/jdpedrie/reeve/plugins"
)

// MaxListPageSize caps page_size in ListConversations regardless of what the
// client requests.
const MaxListPageSize = 100

// Service implements reevev1connect.ConversationsServiceHandler.
//
// catalog, supervisor, logger may be nil when only CRUD is exercised
// (e.g., older tests). SendMessage / Compact require all three plus pool
// (for the per-context-row lock that serializes concurrent sends).
type Service struct {
	reevev1connect.UnimplementedConversationsServiceHandler
	queries    *store.Queries
	pool       *pgxpool.Pool
	catalog    modelmeta.Catalog
	supervisor *stream.Supervisor
	cipher     crypto.Cipher
	storage    storage.Storage
	logger     *slog.Logger
}

// NewService builds a Service. catalog/supervisor/logger/pool may be nil for
// tests that only exercise CRUD; SendMessage and Compact require all four.
// pool is used to begin transactions for the SendMessage critical section
// (resolve-parent → insert-user-message → advance-cursor) so concurrent
// sends on the same context serialize correctly via SELECT FOR UPDATE on
// the contexts row.
//
// cipher decrypts provider config blobs (api_key, base_url, etc.) and
// per-profile / per-user plugin config blobs at the moments those
// bytes are handed to driver / plugin constructors. Pass crypto.Nop{}
// to opt out of encryption.
func NewService(queries *store.Queries, pool *pgxpool.Pool, catalog modelmeta.Catalog, supervisor *stream.Supervisor, cipher crypto.Cipher, st storage.Storage, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	if cipher == nil {
		cipher = crypto.Nop{}
	}
	return &Service{
		queries:    queries,
		pool:       pool,
		catalog:    catalog,
		supervisor: supervisor,
		cipher:     cipher,
		storage:    st,
		logger:     logger,
	}
}

// resolveProviderConfig decrypts provRow.ConfigEncrypted (or falls back
// to plaintext provRow.Config for legacy rows). Mirrors the helper in
// internal/modelproviders so the conversation send path does the same
// thing the model-providers admin path does.
func (s *Service) resolveProviderConfig(row store.UserModelProvider) ([]byte, error) {
	b, err := crypto.ResolveSecret(s.cipher, row.ConfigEncrypted, row.Config)
	if err != nil {
		return nil, fmt.Errorf("decrypt provider config: %w", err)
	}
	if len(b) == 0 {
		return []byte("{}"), nil
	}
	return b, nil
}

// --- CreateConversation ---

func (s *Service) CreateConversation(ctx context.Context, req *connect.Request[reevev1.CreateConversationRequest]) (*connect.Response[reevev1.CreateConversationResponse], error) {
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
	seeds := make([]*reevev1.Message, 0, 2)
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
	return connect.NewResponse(&reevev1.CreateConversationResponse{
		Conversation:   convoProto,
		InitialContext: contextToProto(contextRow),
		SeedMessages:   seeds,
	}), nil
}

// --- ListConversations ---

func (s *Service) ListConversations(ctx context.Context, req *connect.Request[reevev1.ListConversationsRequest]) (*connect.Response[reevev1.ListConversationsResponse], error) {
	caller := auth.MustFromContext(ctx)

	var titleQuery *string
	if q := strings.TrimSpace(req.Msg.GetTitleQuery()); q != "" {
		titleQuery = &q
	}
	var profileFilter *uuid.UUID
	if pid := req.Msg.GetProfileId(); pid != "" {
		parsed, err := uuid.Parse(pid)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid profile_id: %w", err))
		}
		profileFilter = &parsed
	}

	// Two SQL queries (one ordered by created_at, one by computed
	// last_activity_at) — sqlc doesn't support dynamic ORDER BY. Both share
	// the same filter shape, so we just pick which to call.
	type row struct {
		Conversation   store.Conversation
		LastActivityAt time.Time
	}
	var rows []row
	switch req.Msg.GetOrder() {
	case reevev1.ConversationOrder_CONVERSATION_ORDER_RECENTLY_CREATED:
		raw, err := s.queries.ListConversationsByUserRecentlyCreated(ctx, store.ListConversationsByUserRecentlyCreatedParams{
			UserID:     caller.ID,
			TitleQuery: titleQuery,
			ProfileID:  profileFilter,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		rows = make([]row, len(raw))
		for i, r := range raw {
			rows[i] = row{
				Conversation: store.Conversation{
					ID: r.ID, UserID: r.UserID, ProfileID: r.ProfileID,
					Title: r.Title, Settings: r.Settings,
					CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
				},
				LastActivityAt: r.LastActivityAt,
			}
		}
	default: // UNSPECIFIED or RECENTLY_USED
		raw, err := s.queries.ListConversationsByUserRecentlyUsed(ctx, store.ListConversationsByUserRecentlyUsedParams{
			UserID:     caller.ID,
			TitleQuery: titleQuery,
			ProfileID:  profileFilter,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		rows = make([]row, len(raw))
		for i, r := range raw {
			rows[i] = row{
				Conversation: store.Conversation{
					ID: r.ID, UserID: r.UserID, ProfileID: r.ProfileID,
					Title: r.Title, Settings: r.Settings,
					CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
				},
				LastActivityAt: r.LastActivityAt,
			}
		}
	}

	limit := int(req.Msg.PageSize)
	if limit <= 0 || limit > MaxListPageSize {
		limit = MaxListPageSize
	}
	if len(rows) > limit {
		rows = rows[:limit]
	}

	out := make([]*reevev1.Conversation, 0, len(rows))
	for _, r := range rows {
		// active_context_id is left empty in list responses — clients can
		// fetch the full conversation via GetConversation when they need it.
		// Avoids N+1 round trips on the list path.
		p, err := conversationToProtoWithActivity(r.Conversation, "", r.LastActivityAt)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		out = append(out, p)
	}
	return connect.NewResponse(&reevev1.ListConversationsResponse{Conversations: out}), nil
}

// --- GetConversation ---

func (s *Service) GetConversation(ctx context.Context, req *connect.Request[reevev1.GetConversationRequest]) (*connect.Response[reevev1.GetConversationResponse], error) {
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
	return connect.NewResponse(&reevev1.GetConversationResponse{
		Conversation:  convoProto,
		ActiveContext: contextToProto(active),
	}), nil
}

// --- UpdateConversation ---

func (s *Service) UpdateConversation(ctx context.Context, req *connect.Request[reevev1.UpdateConversationRequest]) (*connect.Response[reevev1.UpdateConversationResponse], error) {
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
	return connect.NewResponse(&reevev1.UpdateConversationResponse{Conversation: proto}), nil
}

// --- DeleteConversation ---

func (s *Service) DeleteConversation(ctx context.Context, req *connect.Request[reevev1.DeleteConversationRequest]) (*connect.Response[reevev1.DeleteConversationResponse], error) {
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
	return connect.NewResponse(&reevev1.DeleteConversationResponse{}), nil
}

// --- ListContexts ---

func (s *Service) ListContexts(ctx context.Context, req *connect.Request[reevev1.ListContextsRequest]) (*connect.Response[reevev1.ListContextsResponse], error) {
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
	out := make([]*reevev1.Context, 0, len(rows))
	for _, r := range rows {
		out = append(out, listContextRowToProto(r))
	}
	return connect.NewResponse(&reevev1.ListContextsResponse{Contexts: out}), nil
}

// --- ActivateContext ---

func (s *Service) ActivateContext(ctx context.Context, req *connect.Request[reevev1.ActivateContextRequest]) (*connect.Response[reevev1.ActivateContextResponse], error) {
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
	return connect.NewResponse(&reevev1.ActivateContextResponse{Context: contextToProto(updated)}), nil
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
func (s *Service) SetCurrentLeaf(ctx context.Context, req *connect.Request[reevev1.SetCurrentLeafRequest]) (*connect.Response[reevev1.SetCurrentLeafResponse], error) {
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
	return connect.NewResponse(&reevev1.SetCurrentLeafResponse{Context: contextToProto(updated)}), nil
}

// --- UpdateContext ---

// UpdateContext edits a context's mutable metadata. Currently just `title`.
// Replace semantics: nil leaves alone, non-nil sets (empty string clears).
// Conversation-lock applies (no in-flight stream).
func (s *Service) UpdateContext(ctx context.Context, req *connect.Request[reevev1.UpdateContextRequest]) (*connect.Response[reevev1.UpdateContextResponse], error) {
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

	return connect.NewResponse(&reevev1.UpdateContextResponse{Context: contextToProto(cxRow)}), nil
}

// --- ListMessages ---

func (s *Service) ListMessages(ctx context.Context, req *connect.Request[reevev1.ListMessagesRequest]) (*connect.Response[reevev1.ListMessagesResponse], error) {
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

	// Full-tree mode short-circuits the leaf-resolution path entirely:
	// caller wants every message in the context (every branch), not the
	// linear ancestor chain. Used by the client's branch switcher to
	// discover sibling IDs and walk down to the deepest descendant of a
	// chosen fork. The recursive CTE used in chain mode doesn't apply
	// here — we just dump all rows for the context.
	if req.Msg.FullTree {
		all, err := s.queries.ListMessagesByContext(ctx, contextID)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		ids := make([]uuid.UUID, 0, len(all))
		for _, m := range all {
			ids = append(ids, m.ID)
		}
		attBy, err := loadAttachmentsByMessage(ctx, s.queries, ids)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		out := make([]*reevev1.Message, 0, len(all))
		for _, m := range all {
			proto := messageToProto(m)
			proto.Attachments = attBy[proto.Id]
			applyDisplay(proto, pipeline)
			out = append(out, proto)
		}
		return connect.NewResponse(&reevev1.ListMessagesResponse{Messages: out}), nil
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
				return connect.NewResponse(&reevev1.ListMessagesResponse{}), nil
			}
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		leafID = leaf.ID
	}

	rows, err := s.queries.ListMessageAncestorChain(ctx, leafID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	ids := make([]uuid.UUID, 0, len(rows))
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	attBy, err := loadAttachmentsByMessage(ctx, s.queries, ids)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*reevev1.Message, 0, len(rows))
	for _, r := range rows {
		proto := chainRowToProto(r)
		proto.Attachments = attBy[proto.Id]
		applyDisplay(proto, pipeline)
		out = append(out, proto)
	}
	return connect.NewResponse(&reevev1.ListMessagesResponse{Messages: out}), nil
}

// --- GetMessage ---

func (s *Service) GetMessage(ctx context.Context, req *connect.Request[reevev1.GetMessageRequest]) (*connect.Response[reevev1.GetMessageResponse], error) {
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
	return connect.NewResponse(&reevev1.GetMessageResponse{Message: proto}), nil
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
func (s *Service) SendMessage(ctx context.Context, req *connect.Request[reevev1.SendMessageRequest]) (*connect.Response[reevev1.SendMessageResponse], error) {
	if s.supervisor == nil || s.catalog == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("SendMessage requires supervisor + catalog dependencies"))
	}
	// Regenerate-mode skips the user-message-create step entirely; the
	// stream parents off an existing user row. Content is meaningless in
	// that mode (the user row already carries it). Non-regen requires
	// EITHER non-empty content OR ≥1 attachment — an "image-only" turn
	// ("look at this") is a valid first message.
	if !req.Msg.Regenerate && req.Msg.Content == "" && len(req.Msg.AttachmentFileIds) == 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("content or attachment is required"))
	}
	if req.Msg.Regenerate && (req.Msg.ParentMessageId == nil || *req.Msg.ParentMessageId == "") {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("regenerate requires parent_message_id"))
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

	// Resolve the chat-plugin pipeline up front. Needed before the user-row
	// INSERT so OutgoingUserTransformer plugins (e.g. basic_grounding's
	// `<grounding>` block) can rewrite the content that gets persisted —
	// per the plugin contract, the rewritten text is what lands on the row,
	// is what history.Build re-emits on every subsequent turn, and is what
	// keeps the prefix-cache stable. Reused later for history.Build
	// (SystemPrompter + HistoryTransformer) and for the SendMessage
	// response's display transform.
	pipeline, err := s.resolvePipelineForConversation(ctx, conv)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("resolve plugin pipeline: %w", err))
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
	if req.Msg.Regenerate {
		// Regenerate: parent_message_id references an existing row in the
		// active context. Don't insert a new user row; just load the
		// parent and let the rest of the handler use it as the stream's
		// parent. Two valid shapes:
		//
		//   - parent.role == "user": new assistant becomes a sibling of
		//     any previous assistant under this user message. Standard
		//     "Reload" affordance on an assistant turn.
		//   - parent.role == "assistant": new assistant chains AFTER the
		//     parent assistant — produces two assistants in a row. Powers
		//     "Save and Resend" on an edited assistant: the edit stays
		//     in place and the model continues from there. The wire
		//     prefix sent to the LLM ends with the parent assistant; not
		//     all providers support that gracefully (Anthropic does via
		//     prefill, OpenAI Chat may error). We surface upstream
		//     errors verbatim rather than refusing the request.
		//
		// Other roles (system, summary, context) remain rejected — they
		// have no defined "regenerate from here" semantics.
		pid, perr := uuid.Parse(*req.Msg.ParentMessageId)
		if perr != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid parent_message_id: %w", perr))
		}
		row, gerr := s.queries.GetMessageByID(ctx, pid)
		if gerr != nil {
			if errors.Is(gerr, pgx.ErrNoRows) {
				return nil, connect.NewError(connect.CodeNotFound, errors.New("parent_message_id not found"))
			}
			return nil, connect.NewError(connect.CodeInternal, gerr)
		}
		if row.ContextID != activeCtx.ID {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("parent_message_id does not belong to active context"))
		}
		if row.Role != "user" && row.Role != "assistant" {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("regenerate requires parent_message_id to reference a user or assistant message"))
		}
		userMsgRow = row
		// Repoint the context's current leaf to this user. Without it,
		// subsequent non-explicit-parent sends would parent off whatever
		// leaf the cursor still pointed at, not this regenerated branch.
		if _, err := s.queries.UpdateContextCurrentLeaf(ctx, store.UpdateContextCurrentLeafParams{
			ID:                   activeCtx.ID,
			CurrentLeafMessageID: &row.ID,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("advance cursor: %w", err))
		}
	} else {
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

		// Apply OutgoingUserTransformer plugins (basic_grounding,
		// future siblings) to the raw user content so the rewritten
		// text is what we persist. Empty pipeline → identity transform.
		// Device-fact envelope from the request is translated from the
		// proto enum to the plugin-side string keys; plugins ignore
		// keys they don't recognize.
		persistedContent := pipeline.TransformOutgoingUser(
			req.Msg.Content,
			deviceFactsFromProto(req.Msg.DeviceFacts),
		)

		row, err := qtx.CreateMessage(ctx, store.CreateMessageParams{
			ID:        userMsgID,
			ContextID: lockedCtx.ID,
			ParentID:  parentMessageID,
			Role:      "user",
			Content:   persistedContent,
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

		// Bind attachments before commit. Each attachment_file_id must
		// reference a files row owned by the same user — anything else
		// is a permissions violation we surface as InvalidArgument so a
		// misbehaving client gets a clean error rather than a silently-
		// dropped attachment.
		for i, idStr := range req.Msg.AttachmentFileIds {
			fileID, perr := uuid.Parse(idStr)
			if perr != nil {
				return nil, connect.NewError(connect.CodeInvalidArgument,
					fmt.Errorf("invalid attachment_file_id[%d]: %w", i, perr))
			}
			fileRow, ferr := qtx.GetFile(ctx, fileID)
			if ferr != nil {
				return nil, connect.NewError(connect.CodeInvalidArgument,
					fmt.Errorf("attachment_file_id[%d] not found", i))
			}
			if fileRow.UserID != user.ID {
				return nil, connect.NewError(connect.CodeInvalidArgument,
					fmt.Errorf("attachment_file_id[%d] not owned by caller", i))
			}
			if _, aerr := qtx.AttachFileToMessage(ctx, store.AttachFileToMessageParams{
				MessageID: userMsgRow.ID,
				Ordinal:   int32(i),
				FileID:    fileID,
				Kind:      attachmentKindFromMime(fileRow.MimeType),
				RoleHint:  "user_supplied",
			}); aerr != nil {
				return nil, connect.NewError(connect.CodeInternal,
					fmt.Errorf("bind attachment: %w", aerr))
			}
		}

		if err := tx.Commit(ctx); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
		}
	}

	// Build the driver instance for this provider.
	provCfg, err := s.resolveProviderConfig(provRow)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	driver, err := providers.Build(provRow.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, provCfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build driver: %w", err))
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("driver %q is not a stateless provider; stateful harness sends are not yet wired", provRow.Type))
	}

	// `pipeline` is already resolved above (before the user-row INSERT
	// so OutgoingUserTransformer plugins could rewrite the persisted
	// content). Reused here for FireMessagePersisted, history.Build,
	// and the response's display transform.

	// Fire MessageLifecycleHook plugins on the just-committed user
	// message (skipped on Regenerate where userMsgRow is the existing
	// parent assistant turn, not a freshly-persisted user message).
	// Detached goroutines, no back-pressure on this RPC.
	if !pipeline.Empty() && !req.Msg.Regenerate {
		pipeline.FireMessagePersisted(context.Background(), plugins.PersistedMessage{
			ID:        userMsgRow.ID.String(),
			ContextID: userMsgRow.ContextID.String(),
			Role:      userMsgRow.Role,
			Content:   userMsgRow.Content,
		}, s.logger)
	}

	// Build the wire prefix from history, ending at the just-inserted user message.
	includeThinking := s.resolveIncludeThinking(ctx, conv)
	wireMessages, err := history.Build(ctx, s.queries, history.Params{
		Conversation:     conv,
		LeafMessageID:    &userMsgRow.ID,
		DestProviderType: provRow.Type,
		IncludeThinking:  includeThinking,
		Plugins:          pipeline,
		UserID:           user.ID,
		Attachments:      s.storage,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("build history: %w", err))
	}

	// When regenerating with an assistant parent, the wire prefix
	// naturally ends in "assistant" (no new user row was inserted). Most
	// providers — OpenAI Chat, Google Gemini — reject a contents array
	// that doesn't end with a user turn (Gemini returns 400, OpenAI
	// errors with "messages with role 'assistant' must be followed by a
	// user message"). Inject a synthetic single-space user message for
	// the wire ONLY; nothing is persisted to the messages table. The
	// new assistant's parent_id remains the parent assistant, so the
	// stored chain still reads user → assistant → assistant. The space
	// is a minimal-content nudge — using " " over "Continue." avoids
	// putting words in the user's mouth that they didn't type.
	if req.Msg.Regenerate && userMsgRow.Role == "assistant" {
		wireMessages = append(wireMessages, providers.WireMessage{
			Role:    "user",
			Content: " ",
		})
	}

	// Resolve effective call settings via the 4-layer chain (high precedence
	// → low): conversation > resolved profile > model > provider. The
	// per-turn `req.Msg.CallSettings` proto field exists for forward-compat
	// but is intentionally NOT merged in v1 — conversation-level granularity
	// is enough; per-message overrides clutter the composer for marginal
	// benefit. See the plan's "Resolution chain" section.
	callSettings, err := s.assembleCallSettings(ctx, conv, providerID, modelID, enabledModel.DefaultSettings)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("assemble call settings: %w", err))
	}

	// Gemini explicit cache hook. When call_settings.google.explicit_cache
	// is true and we're sending to a google driver, look up (or create)
	// a cachedContents resource for this (context, model). On hit:
	// trim the wire prefix to the new tail and stash the cache name on
	// settings.Google.CachedContent for the driver to attach. On miss
	// or error: send normally; failures are non-fatal.
	// Build the SendRequest before the cache hook so the hook can
	// mutate Messages + Settings in place via the driver's
	// ApplyExplicitCacheRef.
	sendReq := providers.SendRequest{
		ModelID:        modelID,
		Messages:       wireMessages,
		Settings:       callSettings,
		ConversationID: conv.ID.String(),
		Tools:          collectPipelineTools(pipeline),
	}

	// Provider-agnostic explicit-cache hook. The driver opts in by
	// implementing providers.ExplicitCacheProvider; the conversations
	// service owns the lifecycle (lookup → check expiry → check
	// prefix-hash match → attach OR create-and-store). Today only the
	// Google driver implements the interface; Anthropic could grow
	// one in the future without changing this code path.
	//
	// explicitCacheAttached records the outcome for forensic stamping
	// onto the assistant message. nil → not applicable (toggle off or
	// driver doesn't implement caching); &true → cache attached;
	// &false → toggle was on but no cache attached this turn.
	var explicitCacheAttached *bool
	if callSettings.ExplicitCache != nil && *callSettings.ExplicitCache {
		if cp, ok := driver.(providers.ExplicitCacheProvider); ok {
			attached := s.maybeAttachExplicitCache(ctx, cp, provRow.Type, activeCtx.ID, modelID, &sendReq)
			explicitCacheAttached = &attached
		}
	}
	// Build a SendFunc closure for the supervisor. The supervisor calls
	// it inside its run goroutine with retry + per-attempt 60s timeout
	// (see `internal/stream/send_retry.go`); on exhaustion the supervisor
	// materialises an errored assistant message inline. SendMessage
	// itself returns immediately — the user's typed message is durable
	// the moment the user-row INSERT commits, regardless of upstream
	// health.
	// Per-run collector for tool-result attachments. The
	// tool_loop's appender writes here as each plugin returns
	// attachments; the post-materialize hook below drains the
	// slice and persists each as a `files` row + a
	// message_attachments row bound to the just-inserted
	// assistant message id (role_hint=tool_result).
	var (
		toolAttachMu      sync.Mutex
		toolAttachPending []plugins.ToolAttachment
	)
	appendToolAttachment := func(a plugins.ToolAttachment) {
		toolAttachMu.Lock()
		defer toolAttachMu.Unlock()
		toolAttachPending = append(toolAttachPending, a)
	}
	// Per-run accumulator for tool-side spend. The tool_loop calls
	// this for every ToolResult.CostUSD it sees; the supervisor
	// reads the total at materialize time via the
	// ToolCostProvider closure (see StartParams below). Mutex-
	// guarded because tool dispatch could fan out across
	// goroutines in the future, even though today it's serial per
	// round.
	var (
		toolCostMu    sync.Mutex
		toolCostTotal float64
		toolCostAny   bool
	)
	appendToolCost := func(c float64) {
		if c <= 0 {
			return
		}
		toolCostMu.Lock()
		defer toolCostMu.Unlock()
		toolCostTotal += c
		toolCostAny = true
	}
	readToolCost := func() *float64 {
		toolCostMu.Lock()
		defer toolCostMu.Unlock()
		if !toolCostAny {
			return nil
		}
		v := toolCostTotal
		return &v
	}
	var sendFunc func(driverCtx context.Context) (<-chan providers.Chunk, error)
	if len(sendReq.Tools) > 0 {
		// Tools present → wrap the driver's Send in a per-round tool loop
		// that drains tool_use, dispatches to the owning plugin, and
		// re-issues the request with tool_results. The supervisor sees a
		// single linear chunk stream.
		sendFunc = makeToolLoopSendFunc(stateless, sendReq, pipeline, s.logger, appendToolAttachment, appendToolCost, s.newProviderResolver(conv.UserID))
	} else {
		sendFunc = func(driverCtx context.Context) (<-chan providers.Chunk, error) {
			return stateless.Send(driverCtx, sendReq)
		}
	}
	ownerUserID := conv.UserID
	persistAttachments := func(persistCtx context.Context, assistantMsgID uuid.UUID) {
		toolAttachMu.Lock()
		atts := append([]plugins.ToolAttachment(nil), toolAttachPending...)
		toolAttachPending = nil
		toolAttachMu.Unlock()
		if len(atts) == 0 {
			return
		}
		if err := s.persistToolResultAttachments(persistCtx, ownerUserID, assistantMsgID, atts); err != nil {
			s.logger.Warn("persist tool-result attachments failed",
				"err", err,
				"assistant_msg_id", assistantMsgID,
				"count", len(atts))
		}
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
		SendFunc:        sendFunc,
		// Hand the constructed driver to the supervisor so it can populate
		// thinking_provider_type + thinking_rendered_text on the assistant
		// row. `stateless` already implements providers.Provider via the
		// embedded interface chain.
		Provider:                stateless,
		ExplicitCacheAttached:   explicitCacheAttached,
		Pipeline:                pipeline,
		OnAssistantMaterialized: persistAttachments,
		ToolCostProvider:        readToolCost,
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
	// Bind attachments to the response so the client's optimistic
	// update sees the just-attached chips on the new user row.
	// `loadAttachmentsByMessage` returns nil for empty input, which
	// is fine for the regenerate path (existing parent row).
	if attBy, aerr := loadAttachmentsByMessage(ctx, s.queries, []uuid.UUID{userMsgRow.ID}); aerr == nil {
		userProto.Attachments = attBy[userProto.Id]
	}
	applyDisplay(userProto, pipeline)
	return connect.NewResponse(&reevev1.SendMessageResponse{
		UserMessage: userProto,
		StreamRun:   streamRunToProto(runRow),
	}), nil
}

// resolveProviderModel walks the per-turn → conversation → profile chain to
// determine which provider/model to use. Both ids must be set together.
func (s *Service) resolveProviderModel(ctx context.Context, conv store.Conversation, msg *reevev1.SendMessageRequest) (uuid.UUID, string, error) {
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
		var settings reevev1.ConversationSettings
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
		defaults, err := profiles.DefaultsFromJSON(resolved.DefaultSettings)
		if err == nil && defaults != nil &&
			defaults.DefaultProviderId != nil && defaults.DefaultModelId != nil {
			pid, perr := uuid.Parse(*defaults.DefaultProviderId)
			if perr == nil {
				return pid, *defaults.DefaultModelId, nil
			}
		}
	}

	return uuid.Nil, "", connect.NewError(connect.CodeInvalidArgument,
		errors.New("no provider/model resolved (set per-turn, conversation default, or profile default)"))
}

// resolveIncludeThinking walks conversation settings → profile defaults, default false.
func (s *Service) resolveIncludeThinking(ctx context.Context, conv store.Conversation) bool {
	if conv.Settings != nil {
		var settings reevev1.ConversationSettings
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
		defaults, err := profiles.DefaultsFromJSON(resolved.DefaultSettings)
		if err == nil && defaults != nil && defaults.IncludeThinkingInHistory != nil {
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

// decodeCallSettingsBytes decodes the JSONB blob persisted in
// `user_models.default_settings` (the model layer of the resolution chain)
// into a proto CallSettings. Returns nil for an empty/invalid blob — the
// model layer contributes nothing in that case.
func decodeCallSettingsBytes(b []byte) *reevev1.CallSettings {
	if len(b) == 0 {
		return nil
	}
	cs, err := profiles.UnmarshalCallSettings(b)
	if err != nil {
		return nil
	}
	return cs
}

// loadProviderDefaultSettings loads the bottom-of-chain provider-level
// CallSettings from `user_model_providers.default_settings`. Returns
// (nil, nil) when the column is NULL — that layer contributes nothing.
func (s *Service) loadProviderDefaultSettings(ctx context.Context, providerID uuid.UUID) (*reevev1.CallSettings, error) {
	prov, err := s.queries.GetUserModelProvider(ctx, providerID)
	if err != nil {
		return nil, fmt.Errorf("load provider %s: %w", providerID, err)
	}
	return decodeCallSettingsBytes(prov.DefaultSettings), nil
}

// assembleCallSettings sparse-merges the four layers of the resolution chain
// in highest-precedence-first order:
//
//	conversation.settings.call_settings
//	  > resolved_profile.default_settings.call_settings
//	    > user_model.default_settings
//	      > user_model_provider.default_settings
//
// Each layer's set fields override the layers below; unset fields fall
// through. Returns the driver-side struct ready to ship via SendRequest.
//
// Implementation: load every layer's proto, then nest MergeCallSettings calls
// from the bottom up so the precedence reads top-down at the call site.
func (s *Service) assembleCallSettings(
	ctx context.Context,
	conv store.Conversation,
	providerID uuid.UUID,
	modelID string,
	modelDefaultSettingsBytes []byte,
) (providers.CallSettings, error) {
	// Layer 4 (lowest precedence): provider.
	providerCS, err := s.loadProviderDefaultSettings(ctx, providerID)
	if err != nil {
		return providers.CallSettings{}, err
	}

	// Layer 3: model. Already loaded by the caller; decode its blob.
	modelCS := decodeCallSettingsBytes(modelDefaultSettingsBytes)

	// Layer 2: resolved profile (with parent-chain inheritance baked into
	// resolved.DefaultSettings.call_settings by profiles.Resolve).
	profile, err := s.queries.GetProfileByID(ctx, conv.ProfileID)
	if err != nil {
		return providers.CallSettings{}, fmt.Errorf("load profile: %w", err)
	}
	resolved, err := profiles.Resolve(ctx, s.queries, profile)
	if err != nil {
		return providers.CallSettings{}, fmt.Errorf("resolve profile: %w", err)
	}
	profileCS := extractProfileCallSettings(resolved.DefaultSettings)

	// Layer 1 (highest precedence): conversation.
	convCS := extractConversationCallSettings(conv.Settings)

	// Merge bottom-up.
	merged := profiles.MergeCallSettings(
		convCS,
		profiles.MergeCallSettings(
			profileCS,
			profiles.MergeCallSettings(modelCS, providerCS),
		),
	)
	return protoCallSettingsToProvider(merged), nil
}

// extractProfileCallSettings pulls the call_settings sub-object out of a
// profile's default_settings JSONB blob. Returns nil for an empty blob or
// missing field — that layer contributes nothing to the merge.
func extractProfileCallSettings(blob []byte) *reevev1.CallSettings {
	if len(blob) == 0 {
		return nil
	}
	var s struct {
		CallSettings json.RawMessage `json:"call_settings,omitempty"`
	}
	if err := json.Unmarshal(blob, &s); err != nil {
		return nil
	}
	if len(s.CallSettings) == 0 {
		return nil
	}
	cs, err := profiles.UnmarshalCallSettings(s.CallSettings)
	if err != nil {
		return nil
	}
	return cs
}

// extractConversationCallSettings pulls the call_settings sub-object out of a
// conversation's settings JSONB blob. The blob is protojson-encoded
// (see convert.go::settingsToJSON); we use the same decoder to honour
// proto's optional-field presence rules.
var conversationSettingsExtractUnmarshaller = protojson.UnmarshalOptions{DiscardUnknown: true}

func extractConversationCallSettings(blob []byte) *reevev1.CallSettings {
	if len(blob) == 0 {
		return nil
	}
	var settings reevev1.ConversationSettings
	if err := conversationSettingsExtractUnmarshaller.Unmarshal(blob, &settings); err != nil {
		return nil
	}
	return settings.CallSettings
}

// protoCallSettingsToProvider converts a proto CallSettings (the wire/storage
// shape) into the driver-side struct (what providers.SendRequest carries).
// Drivers pluck whatever subset they support; the rest is silently dropped.
// protoCallSettingsToProvider is a thin alias for the shared converter
// in internal/protoconv. Kept so the call sites in this file stay
// terse; remove if the package gets refactored to use the converter
// directly everywhere.
func protoCallSettingsToProvider(s *reevev1.CallSettings) providers.CallSettings {
	return protoconv.CallSettings(s)
}

// streamRunToProto converts a store.StreamRun to its proto shape.
func streamRunToProto(r store.StreamRun) *reevev1.StreamRun {
	out := &reevev1.StreamRun{
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

func statusToProto(s string) reevev1.StreamRunStatus {
	switch s {
	case "running":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_RUNNING
	case "completed":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_COMPLETED
	case "errored":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_ERRORED
	case "cancelled":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_CANCELLED
	case "interrupted":
		return reevev1.StreamRunStatus_STREAM_RUN_STATUS_INTERRUPTED
	}
	return reevev1.StreamRunStatus_STREAM_RUN_STATUS_UNSPECIFIED
}

func purposeToProto(p string) reevev1.StreamRunPurpose {
	switch p {
	case "assistant_response":
		return reevev1.StreamRunPurpose_STREAM_RUN_PURPOSE_ASSISTANT_RESPONSE
	case "compression":
		return reevev1.StreamRunPurpose_STREAM_RUN_PURPOSE_COMPRESSION
	}
	return reevev1.StreamRunPurpose_STREAM_RUN_PURPOSE_UNSPECIFIED
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
// Per-plugin user-scoped global settings (`Global=true` ConfigField rows
// stored in user_plugin_settings) are merged INTO the profile-level
// config blob before the constructor runs. Profile-level config wins on
// per-key collisions; absence of a global row is treated as an empty
// object.
//
// Cycle-protected: a malformed parent_profile_id loop would otherwise hang;
// detected cycles return an error rather than infinite-looping.
func (s *Service) resolvePluginPipeline(ctx context.Context, profileID uuid.UUID) (plugins.Pipeline, error) {
	cur := profileID
	seen := make(map[uuid.UUID]bool)
	var owner uuid.UUID
	for {
		if seen[cur] {
			return nil, fmt.Errorf("plugin resolve: parent-profile cycle at %s", cur)
		}
		seen[cur] = true

		// Cache the profile lookup so we can both check parent_profile_id
		// (loop continuation) and fish out user_id (global-merge keying).
		prof, err := s.queries.GetProfileByID(ctx, cur)
		if err != nil {
			return nil, fmt.Errorf("get profile %s: %w", cur, err)
		}
		owner = prof.UserID

		rows, err := s.queries.ListProfilePlugins(ctx, cur)
		if err != nil {
			return nil, fmt.Errorf("list profile plugins: %w", err)
		}
		if len(rows) > 0 {
			specs := make([]plugins.Spec, 0, len(rows))
			for _, r := range rows {
				profileCfg, dErr := crypto.ResolveSecret(s.cipher, r.ConfigEncrypted, r.Config)
				if dErr != nil {
					return nil, fmt.Errorf("decrypt profile_plugins.%s: %w", r.PluginName, dErr)
				}
				merged, mErr := s.mergeGlobalIntoProfileConfig(ctx, owner, r.PluginName, profileCfg)
				if mErr != nil {
					return nil, fmt.Errorf("merge globals for %q: %w", r.PluginName, mErr)
				}
				specs = append(specs, plugins.Spec{Name: r.PluginName, Config: merged})
			}
			return plugins.Resolve(specs)
		}

		if prof.ParentProfileID == nil {
			return nil, nil
		}
		cur = *prof.ParentProfileID
	}
}

// mergeGlobalIntoProfileConfig fetches the calling user's global config
// for one plugin and overlays the profile-level config on top (profile
// wins on per-key collisions). Empty results everywhere → returns the
// profile config unchanged. Plugins with no Global=true fields and no
// stored row simply get their original config back.
func (s *Service) mergeGlobalIntoProfileConfig(ctx context.Context, userID uuid.UUID, pluginName string, profileConfig []byte) ([]byte, error) {
	row, err := s.queries.GetUserPluginSettings(ctx, store.GetUserPluginSettingsParams{
		UserID:     userID,
		PluginName: pluginName,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return profileConfig, nil
	}
	if err != nil {
		return nil, err
	}
	globalBytes, err := crypto.ResolveSecret(s.cipher, row.ConfigEncrypted, row.Config)
	if err != nil {
		return nil, fmt.Errorf("decrypt user_plugin_settings.%s: %w", pluginName, err)
	}
	if len(globalBytes) == 0 || string(globalBytes) == "{}" {
		return profileConfig, nil
	}

	// Decode both blobs, shallow-merge, re-encode. Both halves are flat
	// JSON objects (the ConfigField shape is flat — no nesting); the
	// merge is just key-by-key.
	var globalMap, profileMap map[string]any
	if err := json.Unmarshal(globalBytes, &globalMap); err != nil {
		// Malformed global blob → treat as empty rather than failing the
		// whole pipeline build. The user's profile sends should not be
		// gated by a stale-shape global row.
		return profileConfig, nil
	}
	if globalMap == nil {
		globalMap = map[string]any{}
	}
	if len(profileConfig) > 0 {
		if err := json.Unmarshal(profileConfig, &profileMap); err != nil {
			return nil, fmt.Errorf("decode profile config: %w", err)
		}
	}
	if profileMap == nil {
		profileMap = map[string]any{}
	}
	merged := make(map[string]any, len(globalMap)+len(profileMap))
	for k, v := range globalMap {
		merged[k] = v
	}
	for k, v := range profileMap {
		merged[k] = v
	}
	out, err := json.Marshal(merged)
	if err != nil {
		return nil, fmt.Errorf("encode merged config: %w", err)
	}
	return out, nil
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
func (s *Service) Compact(ctx context.Context, req *connect.Request[reevev1.CompactRequest]) (*connect.Response[reevev1.CompactResponse], error) {
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

	// Render the active chain — the linear walk from the current
	// leaf back to root — as a transcript for the compression
	// prompt. We use the chain (not every row in the context) so
	// forks/branches don't pollute the summary with sibling
	// turns the user can't see in the active thread.
	//
	// parentID was just resolved above; it points at the chain's
	// tip (cursor or latest). When the context is empty parentID
	// is nil and the transcript comes back empty — which the
	// "nothing to compact" check below catches the same way.
	transcript, err := s.renderTranscript(ctx, parentID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if transcript == "" {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("nothing to compact (active context has no real turns)"))
	}

	// Build the driver and call Send.
	provCfg, err := s.resolveProviderConfig(provRow)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	driver, err := providers.Build(provRow.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, provCfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf("build compression driver: %w", err))
	}
	stateless, ok := driver.(providers.StatelessProvider)
	if !ok {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("driver %q is not a stateless provider; stateful compression not yet wired", provRow.Type))
	}

	// Compression-specific call settings. We deliberately do NOT inherit
	// the conversation's resolved CallSettings — the compressor is a
	// different job than the conversation model and the inherited
	// settings tend to make compression fail:
	//
	//   - max_tokens defaults to 4096 in Anthropic without an explicit
	//     value. A long conversation's summary easily exceeds that and
	//     the model terminates mid-summary (the "compression stops
	//     before finished" bug). Set a generous explicit cap.
	//   - thinking, if enabled on the conversation's profile, would
	//     eat from the same output-token budget on Anthropic and crowd
	//     out the actual summary. Compression produces a structural
	//     document, not a reasoned answer — force-disable thinking.
	//   - temperature stays unset (driver default) — compression's
	//     determinism doesn't need explicit lowering and forcing 0
	//     can degrade output quality on some models.
	const compressionMaxOutputTokens = 8192
	maxOut := compressionMaxOutputTokens
	thinkingDisabled := false
	compressionSettings := providers.CallSettings{
		MaxOutputTokens: &maxOut,
		Thinking: &providers.ThinkingSettings{
			Enabled: &thinkingDisabled,
		},
	}
	compactSendReq := providers.SendRequest{
		ModelID: *modelID,
		Messages: []providers.WireMessage{
			{Role: "system", Content: *guide},
			{Role: "user", Content: "Here is the conversation to compress.\n\n" + transcript + "\n\nProduce the summary."},
		},
		Settings: compressionSettings,
	}
	compactSendFunc := func(driverCtx context.Context) (<-chan providers.Chunk, error) {
		return stateless.Send(driverCtx, compactSendReq)
	}

	// Pipeline is threaded through to the supervisor so MessageLifecycleHook
	// plugins fire when the compression_summary row is materialised. The
	// compress prompt itself doesn't run plugin transforms (that's by
	// design — see materializeCompression in internal/stream/consume.go),
	// but the post-write hook DOES fan out, so embedding / audit-style
	// plugins observe summaries the same way they observe assistant turns.
	compactPipeline, _ := s.resolvePipelineForConversation(ctx, conv)

	runID, err := s.supervisor.Start(ctx, stream.StartParams{
		ConversationID:  conv.ID,
		ContextID:       activeCtx.ID,
		ParentMessageID: parentID,
		ProviderID:      provRow.ID,
		ModelID:         *modelID,
		Purpose:         stream.PurposeCompression,
		CompressionMode: mode,
		SendFunc:        compactSendFunc,
		Provider:        stateless,
		Pipeline:        compactPipeline,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("start compression stream: %w", err))
	}
	runRow, err := s.supervisor.Get(ctx, runID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&reevev1.CompactResponse{StreamRun: streamRunToProto(runRow)}), nil
}

// renderTranscript turns the active chain — the linear walk from
// `leafID` back to root — into a plain-text transcript "[role]: content"
// suitable for embedding in a compression prompt. Skips
// role=compression_summary rows (they're audit records, not real turns).
//
// Walking the ancestor chain (rather than ListMessagesByContext) is
// load-bearing: contexts can hold multiple branches once the user
// forks via Reload, and the user only sees one branch at a time.
// Including sibling branches would feed the compressor turns the
// user-facing conversation never had — produces summaries that
// reference assistant replies the user wouldn't recognise.
//
// leafID nil = empty context: returns empty transcript.
func (s *Service) renderTranscript(ctx context.Context, leafID *uuid.UUID) (string, error) {
	if leafID == nil {
		return "", nil
	}
	rows, err := s.queries.ListMessageAncestorChain(ctx, *leafID)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	for _, m := range rows {
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
func (s *Service) CountContextTokens(ctx context.Context, req *connect.Request[reevev1.CountContextTokensRequest]) (*connect.Response[reevev1.CountContextTokensResponse], error) {
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
		UserID:           user.ID,
		Attachments:      s.storage,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("build history: %w", err))
	}

	// Build driver, type-assert to TokenCounter.
	provCfg, err := s.resolveProviderConfig(provRow)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	driver, err := providers.Build(provRow.Type, providers.Deps{Catalog: s.catalog, Logger: s.logger}, provCfg)
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
	return connect.NewResponse(&reevev1.CountContextTokensResponse{
		TokenCount:    int32(count),
		ContextWindow: ctxWindow,
	}), nil
}
