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
-- Per-context message_count is aggregated in a single query so the client
-- can render the context list without N+1 round trips.
SELECT
    c.*,
    COUNT(m.id)::BIGINT AS message_count
FROM contexts c
LEFT JOIN messages m ON m.context_id = c.id
WHERE c.conversation_id = $1
GROUP BY c.id
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
