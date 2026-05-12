-- name: CreateStreamRun :one
INSERT INTO stream_runs (
    id, conversation_id, context_id, parent_message_id,
    provider_id, model_id, status, purpose
) VALUES (
    $1, $2, $3, $4,
    $5, $6, $7, $8
)
RETURNING *;

-- name: GetStreamRunByID :one
SELECT * FROM stream_runs WHERE id = $1;

-- name: ListStreamRunsByConversation :many
SELECT * FROM stream_runs
WHERE conversation_id = $1
ORDER BY started_at DESC;

-- name: ListActiveStreamRunsByUser :many
-- Live runs for every conversation the user owns. Powers the iOS
-- StreamHub's "what's running right now" sweep on app launch /
-- conversations-list refresh: each run gets adopted, so a cold launch
-- into a mid-generation conversation shows live content.
SELECT sr.*
FROM stream_runs sr
JOIN conversations c ON c.id = sr.conversation_id
WHERE c.user_id = $1 AND sr.status = 'running'
ORDER BY sr.started_at DESC;

-- name: ListActiveStreamRunsByConversation :many
-- Live runs for a specific conversation. Used by ConversationViewModel
-- on view entry to detect "there's an in-flight assistant turn the
-- previous view didn't finish receiving" — typically zero rows, at
-- most one or two (a turn + a parallel compaction).
SELECT sr.*
FROM stream_runs sr
JOIN conversations c ON c.id = sr.conversation_id
WHERE c.user_id = $1 AND sr.conversation_id = $2 AND sr.status = 'running'
ORDER BY sr.started_at DESC;

-- name: FinalizeStreamRun :one
-- Sets a terminal status, ended_at, optional result_message_id /
-- result_context_id (compression sets the latter) / error_payload.
UPDATE stream_runs
SET status = $2,
    ended_at = NOW(),
    result_message_id = $3,
    result_context_id = $4,
    error_payload = $5
WHERE id = $1
RETURNING *;

-- name: MarkRunningAsInterrupted :exec
-- Called once on server boot. The upstream sockets died with the process and
-- cannot be resumed; users see a partial assistant message + retry affordance.
UPDATE stream_runs
SET status = 'interrupted',
    ended_at = NOW()
WHERE status = 'running';

-- name: InsertStreamChunk :exec
INSERT INTO stream_chunks (stream_run_id, sequence, chunk_type, payload)
VALUES ($1, $2, $3, $4);

-- name: ListStreamChunks :many
-- Returns persisted chunks for a run, in sequence order, starting at the given
-- sequence cursor. Used to replay missed chunks for late subscribers.
SELECT stream_run_id, sequence, chunk_type, payload, created_at
FROM stream_chunks
WHERE stream_run_id = $1 AND sequence >= $2
ORDER BY sequence;

-- name: MaxStreamChunkSequence :one
-- Returns the highest persisted sequence for a run, or NULL if none persisted.
SELECT COALESCE(MAX(sequence), -1)::BIGINT AS max_sequence
FROM stream_chunks
WHERE stream_run_id = $1;

-- name: GetLatestStreamRunWithPrefixForContext :one
-- Returns the most recent stream_run for a context that recorded prefix
-- hashes (skipping turns that errored before the prefix was assembled).
-- Used by the next SendMessage to compute cache-stable prefix length.
SELECT * FROM stream_runs
WHERE context_id = $1 AND prefix_hashes IS NOT NULL
ORDER BY started_at DESC
LIMIT 1;

-- name: HasRunningStreamForConversation :one
-- True iff the conversation has any stream_run with status='running'. Used by
-- the conversation-lock helper that gates mutating RPCs while a stream is
-- in flight (server-side enforcement of the UI's "disabled while streaming"
-- behavior).
SELECT EXISTS(
    SELECT 1 FROM stream_runs
    WHERE conversation_id = $1 AND status = 'running'
)::BOOLEAN AS has_running;

-- name: SetStreamRunPrefixHashes :exec
-- Records the per-message hashes of the rendered wire-prefix for a run plus
-- the diagnostics computed against the previous turn (NULL on the first
-- turn for a context — no comparison possible).
UPDATE stream_runs
SET prefix_hashes              = $2,
    prefix_length              = $3,
    cache_stable_prefix_length = $4,
    cache_trailing_depth       = $5
WHERE id = $1;

-- name: PruneFinalizedStreamChunks :execrows
-- Deletes stream_chunks belonging to stream_runs that finalized more
-- than $1 ago. Stream chunks are transient — they exist only to feed
-- mid-stream subscribers (and to let late reconnects within the
-- retention window catch up). Once a run is finalized, the assistant
-- message row carries the persisted aggregate; the per-chunk rows
-- become dead weight.
--
-- Uses a CTE rather than a JOIN so the planner picks the indexed
-- (ended_at) scan on stream_runs as the driver. Returns the number of
-- chunk rows pruned so the caller can log a trickle of housekeeping
-- activity (or skip the log entirely on zero-row runs).
WITH eligible AS (
    SELECT id FROM stream_runs
    WHERE ended_at IS NOT NULL
      AND ended_at < NOW() - sqlc.arg(retention)::INTERVAL
)
DELETE FROM stream_chunks
WHERE stream_run_id IN (SELECT id FROM eligible);
