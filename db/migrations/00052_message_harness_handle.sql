-- +goose Up
-- The harness session handle that INCLUDES this message.
--
-- Stateful providers (Claude Code, Codex) keep the transcript themselves and
-- hand back an opaque handle per turn. Psmith stores that handle on the
-- assistant message the turn produced, so the handle and the message it
-- represents live or die together.
--
-- On the MESSAGE, not on the conversation. Handles are immutable snapshots:
-- sending to a historical one forks from that point. Keyed to a message, a
-- fork of the message tree is automatically a fork of the harness state,
-- because each branch walks up to its own nearest handle. Keyed to a
-- conversation it would be a single mutable pointer, and editing an old
-- message would silently corrupt every branch.
--
-- This replaces harness_sessions, which was created in 00001 for a design
-- where a conversation had one long-lived session. It never had a single
-- query written against it, and the fork-per-turn model makes its shape
-- (conversation_id -> external_session_id) actively wrong.
ALTER TABLE messages ADD COLUMN harness_handle TEXT;

-- Finding a branch's current handle means walking up from a leaf to the
-- nearest ancestor that has one, the same shape as plugin_state's lookup.
CREATE INDEX messages_harness_handle ON messages (context_id, id)
    WHERE harness_handle IS NOT NULL;

DROP TABLE IF EXISTS harness_sessions;

-- +goose Down
CREATE TABLE harness_sessions (
    id                   UUID PRIMARY KEY,
    conversation_id      UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    provider_id          UUID NOT NULL REFERENCES user_model_providers(id),
    external_session_id  TEXT NOT NULL,
    state                JSONB,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at         TIMESTAMPTZ
);
DROP INDEX IF EXISTS messages_harness_handle;
ALTER TABLE messages DROP COLUMN harness_handle;
