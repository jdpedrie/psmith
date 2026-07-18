-- name: CreateMessage :one
INSERT INTO messages (
    id, context_id, parent_id, role, content,
    raw_content, thinking, thinking_provider_type, thinking_rendered_text,
    provider_id, model_id, message_headers, message_trailers
) VALUES (
    $1, $2, $3, $4, $5,
    $6, $7, $8, $9,
    $10, $11, $12, $13
)
RETURNING *;

-- name: CreateWelcomeMessage :one
-- Insert the profile's snapshot welcome message at conversation-create
-- time. Role is hard-coded to 'assistant' (the welcome is a greeting,
-- not a system instruction) and is_welcome is set so clients can
-- gate a fake-stream reveal animation on first open.
INSERT INTO messages (
    id, context_id, parent_id, role, content, is_welcome
) VALUES (
    $1, $2, $3, 'assistant', $4, TRUE
)
RETURNING *;

-- name: CreateAssistantMessageWithUsage :one
-- Used by the stream supervisor at materialization. Allows the assistant turn
-- (or the compression_summary record) to be inserted with usage + cost
-- columns populated atomically. error_payload is set when the stream
-- terminated in an errored/cancelled state — captures the failure inline so
-- the UI can render the message as a first-class errored history entry.
-- thinking_duration_ms records the elapsed time (ms) between the first and
-- last thinking_delta chunk seen on the run; NULL when the assistant didn't
-- reason at all.
INSERT INTO messages (
    id, context_id, parent_id, role, content,
    raw_content, thinking, thinking_provider_type, thinking_rendered_text,
    thinking_duration_ms,
    provider_id, model_id,
    input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
    reasoning_tokens, provider_usage_raw,
    input_cost_usd, output_cost_usd, cache_read_cost_usd, cache_write_cost_usd,
    tool_cost_usd, total_cost_usd,
    error_payload,
    explicit_cache_attached,
    tool_calls,
    finish_reason
) VALUES (
    $1, $2, $3, $4, $5,
    $6, $7, $8, $9,
    $10,
    $11, $12,
    $13, $14, $15, $16,
    $17, $18,
    $19, $20, $21, $22,
    $23, $24,
    $25,
    $26,
    $27,
    $28
)
RETURNING *;

-- name: GetMessageByID :one
SELECT * FROM messages WHERE id = $1;

-- name: ListMessagesByContext :many
SELECT * FROM messages
WHERE context_id = $1
ORDER BY created_at, id;

-- name: GetContextRoleMessageInContext :one
-- Returns the (single) role=context message in a Context. Each Context has at
-- most one such message; APPEND-mode compression reads it to chain forward.
SELECT * FROM messages
WHERE context_id = $1 AND role = 'context'
ORDER BY created_at
LIMIT 1;

-- name: UpdateMessageContentRole :one
-- In-place edit. content is always set; role is COALESCE'd so the caller can
-- pass NULL to leave it unchanged. edited_at = NOW() unconditionally.
-- sqlc.narg lets the role param be nullable (sqlc otherwise infers
-- non-nullable from the column type).
UPDATE messages
SET content   = $2,
    role      = COALESCE(sqlc.narg('role'), role),
    edited_at = NOW()
WHERE id = $1
RETURNING *;

-- name: ReparentChildren :exec
-- Promotes every direct child of $1 to point at $2 (which may be NULL — that
-- makes them roots in the context). Used by DeleteMessage(cascade=false) just
-- before the DELETE, so the FK's ON DELETE CASCADE has nothing to find.
UPDATE messages
SET parent_id = $2
WHERE parent_id = $1;

-- name: DeleteMessageByID :exec
-- The cascade=true path. With ON DELETE CASCADE on parent_id (migration 00006),
-- this single DELETE removes the descendant subtree too.
DELETE FROM messages WHERE id = $1;

-- name: HasCompressionSummaryInContext :one
-- True iff the context contains at least one role=compression_summary row that
-- did NOT fail (error_payload IS NULL). SendMessage / Compact use this as a
-- precondition: a clean pending summary must be promoted
-- (PromoteCompactionToNewContext) or deleted (DeleteMessage) before more turns
-- can land. Errored compression_summary rows are first-class history entries
-- the user can review; they do not gate the conversation — the user retries
-- by either deleting the failed summary or kicking off a fresh compaction.
SELECT EXISTS(
    SELECT 1 FROM messages
    WHERE context_id = $1
      AND role = 'compression_summary'
      AND error_payload IS NULL
)::BOOLEAN AS has_summary;

-- name: GetCompressionSummaryInContext :one
-- Returns the (single) compression_summary message in a context, if any. Used
-- by PromoteCompactionToNewContext to read the (possibly user-edited) content
-- and seed the new context's role=context message.
SELECT * FROM messages
WHERE context_id = $1 AND role = 'compression_summary'
ORDER BY created_at DESC
LIMIT 1;

-- name: GetContextLeafMessage :one
-- Returns the leaf of a context's message tree: the message that no other
-- message in the same context references as a parent. When the context has
-- multiple dangling branches (shouldn't happen in normal use), returns the
-- one with the greatest id (most recently created per UUIDv7 monotonicity).
-- Returns no rows when the context is truly empty.
SELECT * FROM messages m
WHERE m.context_id = $1
  AND m.id NOT IN (
    SELECT DISTINCT c.parent_id FROM messages c
    WHERE c.context_id = $1 AND c.parent_id IS NOT NULL
  )
ORDER BY m.id DESC
LIMIT 1;

-- name: ListMessageAncestorChain :many
-- Walks parent_id from the leaf back to the root, returning rows root-first.
-- sibling_count: number of OTHER messages sharing this row's parent — i.e.
-- branches forking off the same parent. The UI uses it to render fork
-- indicators alongside the linear chain.
WITH RECURSIVE chain AS (
    SELECT messages.*, 0 AS depth
    FROM messages
    WHERE messages.id = $1
    UNION ALL
    SELECT m.*, c.depth + 1
    FROM messages m
    INNER JOIN chain c ON m.id = c.parent_id
)
SELECT chain.id, chain.context_id, chain.parent_id, chain.role, chain.content,
       chain.raw_content, chain.thinking, chain.thinking_provider_type, chain.thinking_rendered_text,
       chain.thinking_duration_ms,
       chain.provider_id, chain.model_id,
       chain.input_tokens, chain.output_tokens, chain.cache_read_tokens, chain.cache_write_tokens,
       chain.reasoning_tokens, chain.provider_usage_raw,
       chain.input_cost_usd, chain.output_cost_usd, chain.cache_read_cost_usd, chain.cache_write_cost_usd,
       chain.tool_cost_usd,
       chain.total_cost_usd,
       chain.error_payload,
       chain.tool_calls,
       chain.finish_reason,
       chain.created_at,
       chain.edited_at,
       (
           SELECT COUNT(*)::INT FROM messages m
           WHERE m.id <> chain.id
             AND (
                 (chain.parent_id IS NOT NULL AND m.parent_id = chain.parent_id)
                 OR (chain.parent_id IS NULL AND m.context_id = chain.context_id AND m.parent_id IS NULL)
             )
       )::INT AS sibling_count
FROM chain
ORDER BY depth DESC;

-- name: SetMessageEmbedding :exec
-- Worker writes the embedding triple. Idempotent: the CHECK constraint
-- enforces all-three-or-none on every row already, so calling with the
-- same triple over and over is fine.
UPDATE messages
SET embedding       = $2,
    embedding_model = $3,
    embedding_at    = $4
WHERE id = $1;

-- name: ClearMessageEmbedding :exec
-- Reset the triple when a model swap orphans the existing vector.
-- Backfill picks the row up via ListUnembeddedMessages on the next
-- pass. CHECK invariant still holds (all three back to NULL).
UPDATE messages
SET embedding       = NULL,
    embedding_model = NULL,
    embedding_at    = NULL
WHERE id = $1;

-- name: ListUnembeddedMessages :many
-- Backfill worker's hot path. Skips system messages (framing, not
-- searchable content) and zero-length rows (nothing to embed). Ordered
-- by user_id (so the worker can group within a batch and dispatch one
-- embedder call per user) then oldest-first within the user — partial
-- backfill makes monotonic progress against `created_at` and the
-- "embedded up to YYYY-MM-DD" chip stays accurate.
SELECT m.id, m.content, c.user_id
FROM messages m
JOIN contexts ctx ON ctx.id = m.context_id
JOIN conversations c ON c.id = ctx.conversation_id
WHERE m.embedding IS NULL
  AND m.role IN ('user', 'assistant', 'context')
  AND m.content <> ''
ORDER BY c.user_id, m.created_at ASC
LIMIT $1;

-- name: CountUnembeddedMessages :one
-- Drives the "X / Y embedded" progress chip in the settings UI.
-- Cheap even on millions of rows because the partial
-- messages_unembedded_created_at index is exactly this predicate.
-- Scoped to a user so the chip means "MY unembedded messages."
SELECT COUNT(*)::INT FROM messages m
JOIN contexts ctx ON ctx.id = m.context_id
JOIN conversations c ON c.id = ctx.conversation_id
WHERE m.embedding IS NULL
  AND m.role IN ('user', 'assistant', 'context')
  AND m.content <> ''
  AND c.user_id = $1;

-- name: ListMessagesEmbeddedUnderDifferentModel :many
-- When the user swaps embedders (different Model() than what's on
-- existing rows), backfill re-embeds. Returns the rows that need
-- re-embedding under the new model. Like ListUnembeddedMessages but
-- the predicate is "wrong model" rather than "no embedding."
SELECT id, content
FROM messages
WHERE embedding IS NOT NULL
  AND embedding_model <> $1
  AND role IN ('user', 'assistant', 'context')
  AND content <> ''
ORDER BY created_at ASC
LIMIT $2;

-- name: SearchMessagesByEmbedding :many
-- Cosine-distance ranked search. Restricts to messages owned by the
-- caller (via the context→conversation→user chain) and to rows
-- embedded under the same model as the query vector — mixing models
-- would compare vectors from different spaces and yield garbage.
--
-- Returns m.context_id alongside m.id so the memory plugin can drop
-- hits that are still in the wire prefix. A conversation is a
-- SEQUENCE of contexts: when compression fires, the old context is
-- retired and a new one becomes active. The wire prefix is only ever
-- built from the active context, so messages from old contexts —
-- even in the SAME conversation as the caller — are exactly the
-- "no longer in scope" content the memory plugin should surface.
--
-- `<=>` is pgvector's cosine-distance operator: 0 = identical
-- direction, 2 = opposite. Smaller is better. We surface the raw
-- distance so callers can threshold ("only return matches under 0.4").
--
-- pgvector's HNSW index handles ORDER BY ... LIMIT efficiently even
-- with the WHERE filter, provided the filter is selective enough to
-- not prune away most candidates. For a single user that's free; if
-- we ever scale to many users per Psmith instance the index would
-- need partitioning, but that's a future-us problem.
SELECT m.id,
       m.context_id,
       m.parent_id,
       m.role,
       m.content,
       m.created_at,
       ctx.conversation_id,
       c.title AS conversation_title,
       (m.embedding <=> $1)::FLOAT8 AS distance
FROM messages m
JOIN contexts ctx ON ctx.id = m.context_id
JOIN conversations c ON c.id = ctx.conversation_id
WHERE c.user_id = $2
  AND m.embedding_model = $3
  AND m.embedding IS NOT NULL
ORDER BY m.embedding <=> $1
LIMIT $4;

-- name: ListMessageTreeStructure :many
-- Skeleton rows for the branch switcher: the tree SHAPE without
-- content. Selecting only these columns keeps TOASTed message bodies
-- entirely unread.
SELECT id, context_id, parent_id, role, created_at
FROM messages
WHERE context_id = $1
ORDER BY created_at ASC, id ASC;
