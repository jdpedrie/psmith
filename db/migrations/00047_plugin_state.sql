-- +goose Up
-- Branch-scoped state for stateful plugins (first user: the strategy
-- game). The row is keyed to the ASSISTANT MESSAGE that produced it,
-- not to the conversation, and that is the whole point.
--
-- Psmith conversations are trees. Regenerating a turn, editing an
-- earlier message, or choosing a different option from a scrolled-back
-- message all fork a new sibling assistant message. A single mutable
-- row per conversation would let one branch stomp another's state and
-- would make "what if I had chosen differently" incoherent. Keyed per
-- message, each branch owns an independent lineage and no rollback is
-- ever needed: reading state means walking up the parent chain to the
-- nearest ancestor that has a row.
--
-- Consequences worth knowing:
--   - ON DELETE CASCADE, because a snapshot of a deleted message is
--     meaningless. This follows the message_attachments rule (derived
--     per-message data cascades; audit trails use SET NULL instead).
--     Note DeleteMessage(cascade=false) reparents children first, so
--     their snapshots survive with them.
--   - The parent chain does NOT cross a context boundary — compaction
--     seeds the new context with a fresh root — so carrying a campaign
--     through compaction is an explicit copy, not a chain walk. The
--     context_id column exists for that sweep and for cleanup, never
--     for the read path.
--   - state_version is monotonic per lineage and is what optimistic
--     concurrency compares against, so a duplicated or replayed tool
--     call cannot apply the same transition twice.
CREATE TABLE IF NOT EXISTS plugin_state (
    plugin_name     TEXT   NOT NULL,
    message_id      UUID   NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    conversation_id UUID   NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    context_id      UUID   NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    state_version   BIGINT NOT NULL,
    schema_version  INT    NOT NULL DEFAULT 1,
    state_json      JSONB  NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (plugin_name, message_id)
);

-- Context sweep: the compaction copy and any cleanup need "the rows
-- this plugin owns in this context".
CREATE INDEX IF NOT EXISTS plugin_state_plugin_context
    ON plugin_state (plugin_name, context_id);

-- +goose Down
DROP INDEX IF EXISTS plugin_state_plugin_context;
DROP TABLE IF EXISTS plugin_state;
