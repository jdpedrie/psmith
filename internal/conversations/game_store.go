package conversations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
)

// userScopedGameStore is the concrete plugins.GameStore handed to the
// tool dispatch context. Same shape as userScopedResolver: built per
// send with the owner and conversation baked in, so a plugin cannot
// widen its own scope no matter what ids it passes.
//
// Ownership is enforced on every call rather than trusted from the
// caller, and a row belonging to someone else reads as absent — the
// plugin can't tell the difference and we'd rather not leak existence.
type userScopedGameStore struct {
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

var _ plugins.GameStore = (*userScopedGameStore)(nil)

// newGameStore builds a per-send store bound to one plugin, one owner,
// and one conversation. Constructed inline in SendMessage — never
// stashed on Service, which would let a later send inherit an earlier
// send's scope.
func (s *Service) newGameStore(pluginName string, userID, conversationID, leafID uuid.UUID) plugins.GameStore {
	return &userScopedGameStore{
		svc:            s,
		pluginName:     pluginName,
		userID:         userID,
		conversationID: conversationID,
		leafID:         leafID,
	}
}

func (g *userScopedGameStore) LoadNearest(ctx context.Context) (json.RawMessage, int64, uuid.UUID, error) {
	if g.leafID == uuid.Nil {
		return nil, 0, uuid.Nil, plugins.ErrNoGameState
	}
	row, err := g.svc.queries.GetNearestPluginState(ctx, store.GetNearestPluginStateParams{
		PluginName: g.pluginName,
		ID:         g.leafID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, 0, uuid.Nil, plugins.ErrNoGameState
		}
		return nil, 0, uuid.Nil, fmt.Errorf("game_store: load nearest: %w", err)
	}
	// The chain walk is not itself scoped, so verify the row we landed
	// on belongs to this conversation before handing it back. A
	// mismatch means the leaf id came from somewhere it shouldn't have.
	if row.ConversationID != g.conversationID {
		return nil, 0, uuid.Nil, plugins.ErrNoGameState
	}
	return json.RawMessage(row.StateJson), row.StateVersion, row.MessageID, nil
}

func (g *userScopedGameStore) Save(ctx context.Context, messageID uuid.UUID, state json.RawMessage, version int64) error {
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
