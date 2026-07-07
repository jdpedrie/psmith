-- name: CreateConversation :one
INSERT INTO conversations (
    id, user_id, profile_id, title, settings
) VALUES (
    $1, $2, $3, $4, $5
)
RETURNING *;

-- name: GetConversationByID :one
SELECT * FROM conversations WHERE id = $1;

-- name: ListConversationsByUser :many
SELECT * FROM conversations
WHERE user_id = $1
ORDER BY created_at DESC;

-- name: ListConversationsByUserRecentlyUsed :many
-- Returns conversations sorted by the most recent message activity, with
-- created_at as the fallback for conversations that haven't received a
-- message yet. Optional filters: case-insensitive title substring (NULL
-- skips the filter; conversations with no title are excluded when set);
-- profile_id (NULL skips the filter).
--
-- Keyset paging: cursor_key/cursor_id (NULL = first page) resume after
-- the row with that (last_activity_at, id) tuple; id breaks timestamp
-- ties so a page boundary through same-instant rows can't skip or
-- duplicate. page_limit callers pass limit+1 to detect a next page.
WITH convs AS (
    SELECT
        c.*,
        COALESCE(
            (SELECT MAX(m.created_at) FROM messages m
             JOIN contexts ctx ON ctx.id = m.context_id
             WHERE ctx.conversation_id = c.id),
            c.created_at
        ) AS last_activity_at
    FROM conversations c
    WHERE c.user_id = $1
      AND (sqlc.narg('title_query')::text IS NULL
           OR (c.title IS NOT NULL
               AND c.title ILIKE '%' || sqlc.narg('title_query')::text || '%'))
      AND (sqlc.narg('profile_id')::uuid IS NULL
           OR c.profile_id = sqlc.narg('profile_id')::uuid)
)
SELECT * FROM convs
WHERE (sqlc.narg('cursor_key')::timestamptz IS NULL
       OR (last_activity_at, id) < (sqlc.narg('cursor_key')::timestamptz, sqlc.narg('cursor_id')::uuid))
ORDER BY last_activity_at DESC, id DESC
LIMIT sqlc.arg('page_limit');

-- name: ListConversationsByUserRecentlyCreated :many
-- Same filters as ListConversationsByUserRecentlyUsed but ordered by the
-- conversation's own created_at — the freshest creation always wins
-- regardless of subsequent message traffic. Still computes
-- last_activity_at for clients that want to display "last used" alongside
-- the row even when sorting by creation. Same keyset scheme, keyed on
-- created_at.
SELECT
    c.*,
    COALESCE(
        (SELECT MAX(m.created_at) FROM messages m
         JOIN contexts ctx ON ctx.id = m.context_id
         WHERE ctx.conversation_id = c.id),
        c.created_at
    ) AS last_activity_at
FROM conversations c
WHERE c.user_id = $1
  AND (sqlc.narg('title_query')::text IS NULL
       OR (c.title IS NOT NULL
           AND c.title ILIKE '%' || sqlc.narg('title_query')::text || '%'))
  AND (sqlc.narg('profile_id')::uuid IS NULL
       OR c.profile_id = sqlc.narg('profile_id')::uuid)
  AND (sqlc.narg('cursor_key')::timestamptz IS NULL
       OR (c.created_at, c.id) < (sqlc.narg('cursor_key')::timestamptz, sqlc.narg('cursor_id')::uuid))
ORDER BY c.created_at DESC, c.id DESC
LIMIT sqlc.arg('page_limit');

-- name: UpdateConversationTitle :exec
UPDATE conversations SET title = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateConversationSettings :exec
UPDATE conversations SET settings = $2, updated_at = NOW() WHERE id = $1;

-- name: DeleteConversation :exec
DELETE FROM conversations WHERE id = $1;
