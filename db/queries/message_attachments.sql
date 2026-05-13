-- name: AttachFileToMessage :one
INSERT INTO message_attachments (
    message_id, ordinal, file_id, kind, role_hint
) VALUES (
    $1, $2, $3, $4, $5
)
RETURNING *;

-- name: ListAttachmentsForMessage :many
SELECT
    a.message_id, a.ordinal, a.file_id, a.kind, a.role_hint,
    f.sha256, f.mime_type, f.size_bytes, f.original_filename
FROM message_attachments a
JOIN files f ON f.id = a.file_id
WHERE a.message_id = $1
ORDER BY a.ordinal ASC;

-- name: ListAttachmentsForMessages :many
-- Bulk variant for history builder: one query per chain instead of N.
SELECT
    a.message_id, a.ordinal, a.file_id, a.kind, a.role_hint,
    f.sha256, f.mime_type, f.size_bytes, f.original_filename
FROM message_attachments a
JOIN files f ON f.id = a.file_id
WHERE a.message_id = ANY($1::uuid[])
ORDER BY a.message_id, a.ordinal ASC;
