-- name: CreateUserModelProvider :one
INSERT INTO user_model_providers (id, user_id, type, label, config)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetUserModelProvider :one
SELECT * FROM user_model_providers WHERE id = $1;

-- name: ListUserModelProvidersByUser :many
SELECT * FROM user_model_providers
WHERE user_id = $1
ORDER BY created_at;

-- name: UpdateUserModelProviderLabel :exec
UPDATE user_model_providers
SET label = $2, updated_at = NOW()
WHERE id = $1;

-- name: UpdateUserModelProviderConfig :exec
-- Shallow-merges the incoming JSONB patch into the existing config. Keys
-- present in the patch override existing values; absent keys are preserved.
-- To clear a key, send it explicitly with an empty value.
UPDATE user_model_providers
SET config = config || $2, updated_at = NOW()
WHERE id = $1;

-- name: DeleteUserModelProvider :exec
DELETE FROM user_model_providers WHERE id = $1;
