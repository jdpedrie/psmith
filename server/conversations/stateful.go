package conversations

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/server/providers"
)

// The stateful send path.
//
// A harness (Claude Code, Codex) owns the transcript. Psmith sends only the
// latest message and holds an opaque handle per turn, so almost everything the
// stateless path does is wrong here:
//
//   - No prefix. history.Build is not called at all; the harness already has
//     the conversation and re-sending it would duplicate every turn.
//   - No HistoryTransformer. There is no history on the wire to transform.
//   - System prompt fixed at conversation start, not assembled per turn. The
//     harness pins it when the session opens, so a later profile edit cannot
//     reach a conversation already under way.
//   - MessageEnvelope still applies: it decorates the outgoing message, which
//     is the one thing that does travel.
//
// Which plugin capabilities work and which silently do not is a real cost of
// this model, and it is documented in docs/design/providers.md rather than
// left for someone to discover.

// resolveHarnessHandle finds the handle this turn should extend from.
//
// Walks up the branch to the nearest ancestor that carries one. Empty means
// the branch has never spoken to a harness, which is the signal to open a
// session rather than an error.
//
// Walking rather than reading the conversation is what makes forking work: two
// branches off one parent each find their own handle, so editing an old
// message extends the harness state as it stood at that message rather than as
// it stands now.
func (s *Service) resolveHarnessHandle(ctx context.Context, fromMessageID uuid.UUID) (string, error) {
	if fromMessageID == uuid.Nil {
		return "", nil
	}
	h, err := s.queries.NearestHarnessHandle(ctx, fromMessageID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", nil
		}
		return "", err
	}
	if h == nil {
		return "", nil
	}
	return *h, nil
}

// resolveHarnessSystemPrompt assembles the system prompt a harness session
// opens with: the context's system message plus every SystemPrompter's
// contribution.
//
// Computed once, when the session is opened, and never again. That is the
// harness's constraint rather than a choice: Claude Code fixes it for the
// session's life, and pinning it for Codex too keeps the two behaving the
// same. A user editing their profile mid-conversation sees no change until
// they start a new one, which the UI has to make clear.
func (s *Service) resolveHarnessSystemPrompt(
	ctx context.Context,
	contextID uuid.UUID,
	pipeline pluginapi.Pipeline,
) string {
	var parts []string

	if rows, err := s.queryFullTree(ctx, contextID); err == nil {
		for _, m := range rows {
			if m.Role == "system" && strings.TrimSpace(m.Content) != "" {
				parts = append(parts, m.Content)
				break
			}
		}
	}

	if !pipeline.Empty() {
		prepend, appendStr := pipeline.SystemPrompts()
		if prepend != "" {
			parts = append([]string{prepend}, parts...)
		}
		if appendStr != "" {
			parts = append(parts, appendStr)
		}
	}
	return strings.Join(parts, "\n\n")
}

// statefulSendFunc builds the SendFunc for a harness turn.
//
// Opens a session when the branch has no handle, then sends the one message.
// The handle for the turn comes back as a ChunkSessionHandle, which the
// supervisor stamps onto the assistant row; nothing is written here, because
// at this point the assistant row does not exist yet.
func (s *Service) statefulSendFunc(
	stateful providers.StatefulProvider,
	handle string,
	modelID string,
	systemPrompt string,
	settings providers.CallSettings,
	userMsg providers.WireMessage,
) func(context.Context) (<-chan providers.Chunk, error) {
	return func(driverCtx context.Context) (<-chan providers.Chunk, error) {
		h := handle
		if h == "" {
			opened, err := stateful.StartSession(driverCtx, modelID, providers.SessionConfig{
				SystemPrompt: systemPrompt,
				Settings:     settings,
			})
			if err != nil {
				return nil, fmt.Errorf("start harness session: %w", err)
			}
			h = opened
		}
		return stateful.SendInSession(driverCtx, h, userMsg, settings)
	}
}
