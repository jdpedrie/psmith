-- name: CreateUserModelProvider :one
-- config_encrypted is the AES-256-GCM-sealed JSONB blob; the legacy
-- `config` column is left NULL. The service layer's Get/List path
-- decrypts config_encrypted when present and falls back to plaintext
-- config for any row that hasn't been touched since the encryption
-- rollout.
INSERT INTO user_model_providers (id, user_id, type, label, config_encrypted, default_settings)
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

-- name: UpdateUserModelProviderEncryptedConfig :exec
-- Full-replacement update on the encrypted column. The service layer
-- handles partial-merge semantics in Go (decrypt → JSON merge →
-- re-encrypt) before calling this — the SQL side stays straightforward
-- replacement so the encrypted bytes remain a single sealed unit.
-- Clears any plaintext config that may still be present, finalising
-- the row's transition to encrypted-only storage.
UPDATE user_model_providers
SET config_encrypted = $2, config = NULL, updated_at = NOW()
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
