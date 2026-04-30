-- name: CreateUserModelProvider :one
INSERT INTO user_model_providers (id, user_id, type, label, config, default_settings)
VALUES ($1, $2, $3, $4, $5, $6)
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

-- name: UpdateUserModelProviderDefaultSettings :exec
-- Replaces (not merges) the provider-level default_settings blob. NULL clears
-- it, returning the row to "no provider-level defaults; resolve from above
-- only." Replace semantics keep the call site simple — the resolver does the
-- merge with the upper layers, so partial writes here would be a footgun.
UPDATE user_model_providers
SET default_settings = $2, updated_at = NOW()
WHERE id = $1;

-- name: DeleteUserModelProvider :exec
DELETE FROM user_model_providers WHERE id = $1;
