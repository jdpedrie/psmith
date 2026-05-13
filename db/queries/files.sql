-- name: CreateFile :one
-- Idempotent on (user_id, sha256) — re-uploading the same content by
-- the same user returns the existing row instead of inserting a
-- duplicate. The DO UPDATE no-op pattern is the standard way to make
-- ON CONFLICT path RETURN the existing row (a plain DO NOTHING would
-- return no rows).
INSERT INTO files (
    id, user_id, sha256, mime_type, size_bytes, original_filename
) VALUES (
    $1, $2, $3, $4, $5, $6
)
ON CONFLICT (user_id, sha256) DO UPDATE
    SET sha256 = EXCLUDED.sha256
RETURNING *;

-- name: GetFile :one
SELECT * FROM files
WHERE id = $1
LIMIT 1;

-- name: GetFileByUserAndSHA :one
SELECT * FROM files
WHERE user_id = $1 AND sha256 = $2
LIMIT 1;

-- name: ListFilesForUser :many
SELECT * FROM files
WHERE user_id = $1
ORDER BY created_at DESC
LIMIT $2;

-- name: DeleteFile :exec
-- Caller's responsibility to ensure no message_attachments still reference
-- the file (or accept the ON DELETE CASCADE on message_attachments).
DELETE FROM files
WHERE id = $1;
