-- +goose Up
-- ListContextsByConversation's per-context "latest assistant message
-- with usage" subquery orders by (created_at, id) within a context;
-- the only prior index was (context_id, parent_id), so every context
-- row paid a sort over its full message set. Also serves the
-- structure-only tree listing, which orders the same way.
CREATE INDEX messages_context_created ON messages (context_id, created_at DESC, id DESC);

-- +goose Down
DROP INDEX messages_context_created;
