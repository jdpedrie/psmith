-- name: CreateContext :one
INSERT INTO contexts (
    id, conversation_id, parent_context_id, context_activation_time
) VALUES (
    $1, $2, $3, $4
)
RETURNING *;

-- name: GetContextByID :one
SELECT * FROM contexts WHERE id = $1;

-- name: GetContextByIDForUpdate :one
-- Row-locks the context for the duration of the enclosing transaction.
-- Used by SendMessage to serialize the
--   resolve-parent → insert-user-message → advance-cursor
-- critical section across concurrent sends on the same context, so the
-- second SendMessage observes the first's committed state and produces
-- siblings (not a chain) when neither specifies an explicit parent.
SELECT * FROM contexts WHERE id = $1 FOR UPDATE;

-- name: GetActiveContextByConversation :one
SELECT * FROM contexts
WHERE conversation_id = $1
ORDER BY context_activation_time DESC
LIMIT 1;

-- name: ListContextsByConversation :many
-- Per-context aggregates (message_count, last_message_total_tokens,
-- cumulative_cost_usd) are computed in a single query so the client can
-- render context-list rows without N+1 round trips.
--
--   last_message_total_tokens: input_tokens + output_tokens of the most
--     recent assistant message (by created_at, then id as tiebreaker) that
--     carries usage data. Zero when no such message exists yet. Mirrors the
--     "last turn cost / size" UX surface — input tokens already reflect the
--     full wire prefix at that turn, so input+output captures the work the
--     model did for that turn.
--   cumulative_cost_usd: SUM of messages.total_cost_usd across every row in
--     the context (NULLs treated as zero). Includes compression_summary
--     rows since they carry real cost.
--
-- Lateral aggregation, not LEFT JOIN + GROUP BY: the join materialized
-- every message ROW (all columns, embeddings included) per context just
-- to count and sum two fields, then grouped by every contexts column.
-- The laterals aggregate in place off the messages(context_id, ...)
-- indexes and only two scalars leave each subquery. The client
-- refreshes this list after every terminal and delete, so it runs
-- constantly on hot conversations.
SELECT
    c.*,
    agg.message_count,
    COALESCE(last_turn.total_tokens, 0)::BIGINT AS last_message_total_tokens,
    agg.cumulative_cost_usd
FROM contexts c
LEFT JOIN LATERAL (
    SELECT COUNT(*)::BIGINT AS message_count,
           COALESCE(SUM(m.total_cost_usd), 0)::DOUBLE PRECISION AS cumulative_cost_usd
    FROM messages m
    WHERE m.context_id = c.id
) agg ON TRUE
LEFT JOIN LATERAL (
    SELECT (COALESCE(la.input_tokens, 0) + COALESCE(la.output_tokens, 0))::BIGINT AS total_tokens
    FROM messages la
    WHERE la.context_id = c.id
      AND la.role = 'assistant'
      AND (la.input_tokens IS NOT NULL OR la.output_tokens IS NOT NULL)
    ORDER BY la.created_at DESC, la.id DESC
    LIMIT 1
) last_turn ON TRUE
WHERE c.conversation_id = $1
ORDER BY c.context_activation_time DESC;

-- name: UpdateContextActivationTime :one
UPDATE contexts
SET context_activation_time = $2
WHERE id = $1
RETURNING *;

-- name: UpdateContextTitle :exec
-- Sets the human-friendly title for a Context. Pass NULL to clear.
-- Populated automatically after the first assistant turn lands in the
-- context (when profile title settings are configured); editable by user.
UPDATE contexts SET title = $2 WHERE id = $1;

-- name: UpdateContextCurrentLeaf :one
-- Sets the per-context cursor for "the tip the user is currently viewing."
-- Pass NULL for current_leaf_message_id to clear the cursor.
UPDATE contexts
SET current_leaf_message_id = $2
WHERE id = $1
RETURNING *;

-- name: ReparentChildContexts :exec
-- Points children of a context about to be deleted at their
-- grandparent, keeping compaction lineage connected. NULL parent is
-- valid (the deleted context was a root).
UPDATE contexts SET parent_context_id = $2 WHERE parent_context_id = $1;

-- name: DeleteContext :exec
-- Messages (and their attachments / explicit-cache rows) go via
-- ON DELETE CASCADE. Callers must clear stream_runs references first
-- (their context FKs have no cascade).
DELETE FROM contexts WHERE id = $1;
