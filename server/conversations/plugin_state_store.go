package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/pluginapi/host"
	"github.com/jdpedrie/psmith/server/store"
)

// userScopedStateStore is the concrete host.PluginStateStore handed to the
// tool dispatch context. Same shape as userScopedResolver: built per
// send with the owner and conversation baked in, so a plugin cannot
// widen its own scope no matter what ids it passes.
//
// Ownership is enforced on every call rather than trusted from the
// caller, and a row belonging to someone else reads as absent — the
// plugin can't tell the difference and we'd rather not leak existence.
type userScopedStateStore struct {
	svc            *Service
	pluginName     string
	userID         uuid.UUID
	conversationID uuid.UUID
	// leafID is the message this turn's state lookup walks up from —
	// the user message that triggered the send. Baked in rather than
	// accepted per call so a plugin cannot walk a chain it wasn't given.
	// On regenerate this is the pre-existing user message, so the new
	// branch inherits the same parent state.
	leafID uuid.UUID
}

var _ host.PluginStateStore = (*userScopedStateStore)(nil)

// newPluginStateStore builds a per-send store bound to one plugin, one owner,
// and one conversation. Constructed inline in SendMessage — never
// stashed on Service, which would let a later send inherit an earlier
// send's scope.
func (s *Service) newPluginStateStore(pluginName string, userID, conversationID, leafID uuid.UUID) host.PluginStateStore {
	return &userScopedStateStore{
		svc:            s,
		pluginName:     pluginName,
		userID:         userID,
		conversationID: conversationID,
		leafID:         leafID,
	}
}

func (g *userScopedStateStore) LoadNearest(ctx context.Context) (json.RawMessage, int64, uuid.UUID, error) {
	if g.leafID == uuid.Nil {
		return nil, 0, uuid.Nil, host.ErrNoPluginState
	}
	row, err := g.svc.queries.GetNearestPluginState(ctx, store.GetNearestPluginStateParams{
		PluginName: g.pluginName,
		ID:         g.leafID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, 0, uuid.Nil, host.ErrNoPluginState
		}
		return nil, 0, uuid.Nil, fmt.Errorf("game_store: load nearest: %w", err)
	}
	// The chain walk is not itself scoped, so verify the row we landed
	// on belongs to this conversation before handing it back. A
	// mismatch means the leaf id came from somewhere it shouldn't have.
	if row.ConversationID != g.conversationID {
		return nil, 0, uuid.Nil, host.ErrNoPluginState
	}
	return json.RawMessage(row.StateJson), row.StateVersion, row.MessageID, nil
}

func (g *userScopedStateStore) Save(ctx context.Context, messageID uuid.UUID, state json.RawMessage, version int64) error {
	if messageID == uuid.Nil {
		return errors.New("game_store: save requires a message id")
	}
	if len(state) == 0 {
		return errors.New("game_store: refusing to save empty state")
	}
	// Confirm the target message is in this conversation before writing.
	// Without it a bad id would bind campaign state onto a stranger's
	// message, and the FK alone would happily allow it.
	msg, err := g.svc.queries.GetMessageByID(ctx, messageID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("game_store: message %s not found", messageID)
		}
		return fmt.Errorf("game_store: load message: %w", err)
	}
	ctxRow, err := g.svc.queries.GetContextByID(ctx, msg.ContextID)
	if err != nil {
		return fmt.Errorf("game_store: load context: %w", err)
	}
	if ctxRow.ConversationID != g.conversationID {
		return fmt.Errorf("game_store: message %s not found", messageID)
	}

	if _, err := g.svc.queries.UpsertPluginState(ctx, store.UpsertPluginStateParams{
		PluginName:     g.pluginName,
		MessageID:      messageID,
		ConversationID: g.conversationID,
		ContextID:      msg.ContextID,
		StateVersion:   version,
		SchemaVersion:  1,
		StateJson:      state,
	}); err != nil {
		return fmt.Errorf("game_store: save: %w", err)
	}
	return nil
}

// copyStateParams describes one context-boundary crossing.
type copyStateParams struct {
	conversationID uuid.UUID
	// sourceLeafID is the message whose lineage the new context
	// continues. For compaction that is the summary's parent — the tip
	// of the chain the summary was written from.
	sourceLeafID  *uuid.UUID
	sourceCtxID   uuid.UUID
	newCtxID      uuid.UUID
	seedMessageID uuid.UUID
}

// copyPluginStateAcrossContexts carries every stateful plugin's state
// into a newly seeded context.
//
// Which snapshot gets copied matters more than it looks. A context can
// hold several leaves, and the copy has to take the one belonging to the
// SAME chain the summary was written from — not simply the newest row in
// the context. Taking the newest would hand the player mechanical state
// from a branch they abandoned while the narrative summary describes the
// branch they actually played, and the mismatch would be silent.
//
// Runs inside the caller's transaction so the new context cannot exist
// without its state.
func copyPluginStateAcrossContexts(ctx context.Context, q *store.Queries, p copyStateParams) error {
	if p.sourceLeafID == nil {
		// An empty source context has no lineage to carry.
		return nil
	}
	names, err := q.ListPluginNamesInContext(ctx, p.sourceCtxID)
	if err != nil {
		return fmt.Errorf("copy plugin state: list plugins: %w", err)
	}
	for _, name := range names {
		row, err := q.GetNearestPluginState(ctx, store.GetNearestPluginStateParams{
			PluginName: name,
			ID:         *p.sourceLeafID,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				// The plugin has state somewhere in this context but not
				// on the branch being compacted. Nothing to carry.
				continue
			}
			return fmt.Errorf("copy plugin state: load %s: %w", name, err)
		}
		if _, err := q.UpsertPluginState(ctx, store.UpsertPluginStateParams{
			PluginName:     name,
			MessageID:      p.seedMessageID,
			ConversationID: p.conversationID,
			ContextID:      p.newCtxID,
			StateVersion:   row.StateVersion,
			SchemaVersion:  row.SchemaVersion,
			StateJson:      row.StateJson,
		}); err != nil {
			return fmt.Errorf("copy plugin state: write %s: %w", name, err)
		}
	}
	return nil
}

// Leaf exposes the branch head this store was constructed against, so callers
// working outside a send (panel actions) have somewhere to bind a write.
func (s *userScopedStateStore) Leaf() uuid.UUID { return s.leafID }

// LoadConversation reads the conversation-scoped row.
func (s *userScopedStateStore) LoadConversation(ctx context.Context) (json.RawMessage, int64, error) {
	row, err := s.svc.queries.GetPluginConversationState(ctx, store.GetPluginConversationStateParams{
		PluginName:     s.pluginName,
		ConversationID: s.conversationID,
	})
	if err != nil {
		// Absent is the normal first-use condition, not a failure.
		return nil, 0, host.ErrNoPluginState
	}
	return row.StateJson, row.StateVersion, nil
}

// SaveConversation overwrites the conversation-scoped row.
func (s *userScopedStateStore) SaveConversation(ctx context.Context, state json.RawMessage, version int64) error {
	_, err := s.svc.queries.UpsertPluginConversationState(ctx, store.UpsertPluginConversationStateParams{
		PluginName:     s.pluginName,
		ConversationID: s.conversationID,
		StateVersion:   version,
		SchemaVersion:  1,
		StateJson:      state,
	})
	return err
}
