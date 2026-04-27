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

-- name: UpdateConversationTitle :exec
UPDATE conversations SET title = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateConversationSettings :exec
UPDATE conversations SET settings = $2, updated_at = NOW() WHERE id = $1;

-- name: DeleteConversation :exec
DELETE FROM conversations WHERE id = $1;
