-- name: CreateUser :one
INSERT INTO users (id, username, display_name, password_hash, is_admin)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetUserByID :one
SELECT * FROM users WHERE id = $1;

-- name: GetUserByUsername :one
SELECT * FROM users WHERE username = $1;

-- name: ListUsers :many
SELECT * FROM users ORDER BY created_at;

-- name: UpdateUserDisplayName :exec
UPDATE users SET display_name = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateUserIsAdmin :exec
UPDATE users SET is_admin = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateUserPassword :exec
UPDATE users SET password_hash = $2, updated_at = NOW() WHERE id = $1;

-- name: DeleteUser :exec
DELETE FROM users WHERE id = $1;

-- name: CountUsers :one
SELECT COUNT(*) FROM users;
