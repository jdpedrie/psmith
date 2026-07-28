-- name: UpsertPluginState :one
-- Write the snapshot a completed turn produced. Upsert rather than insert
-- because the assistant message is materialized before the binding hook
-- runs, and a retried bind must be idempotent rather than a duplicate-key
-- failure.
INSERT INTO plugin_state (
    plugin_name, message_id, conversation_id, context_id,
    state_version, schema_version, state_json
) VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (plugin_name, message_id) DO UPDATE
SET state_version  = EXCLUDED.state_version,
    schema_version = EXCLUDED.schema_version,
    state_json     = EXCLUDED.state_json
RETURNING *;

-- name: GetPluginState :one
-- Exact lookup for one message's snapshot.
SELECT * FROM plugin_state
WHERE plugin_name = $1 AND message_id = $2;

-- name: GetNearestPluginState :one
-- THE read path. Walks the message parent chain upward from $2 and returns
-- the first ancestor (inclusive of $2 itself) carrying a snapshot for this
-- plugin.
--
-- A plain "parent's row" lookup is not good enough: stitch deletes reparent
-- children onto a grandparent, non-game messages can be interleaved, and a
-- turn that failed to bind leaves a gap. Walking until a row is found
-- absorbs all three.
--
-- The walk deliberately does NOT cross a context boundary, because the
-- parent chain does not either — compaction seeds the new context with a
-- fresh root. Carrying a campaign through compaction is an explicit copy.
WITH RECURSIVE chain AS (
    SELECT messages.id, messages.parent_id, 0 AS depth
    FROM messages
    WHERE messages.id = $2
    UNION ALL
    SELECT m.id, m.parent_id, c.depth + 1
    FROM messages m
    INNER JOIN chain c ON m.id = c.parent_id
)
SELECT ps.*
FROM chain
INNER JOIN plugin_state ps
    ON ps.message_id = chain.id AND ps.plugin_name = $1
ORDER BY chain.depth ASC
LIMIT 1;

-- name: ListPluginStateInContext :many
-- Context sweep, used by the compaction copy and by cleanup. Newest first.
SELECT * FROM plugin_state
WHERE plugin_name = $1 AND context_id = $2
ORDER BY state_version DESC;

-- name: DeletePluginStateForConversation :exec
-- Explicit teardown. Conversation deletion already cascades; this exists
-- for a plugin that wants to abandon a campaign without deleting the chat.
DELETE FROM plugin_state
WHERE plugin_name = $1 AND conversation_id = $2;

-- name: ListPluginNamesInContext :many
-- Which plugins hold state in this context. Used by the compaction copy,
-- which must carry every stateful plugin forward without knowing in
-- advance which ones are attached.
SELECT DISTINCT plugin_name FROM plugin_state
WHERE context_id = $1
ORDER BY plugin_name;
