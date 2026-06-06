-- name: GetUserEmbedderConfig :one
-- Returns the user's embedder config row, if any. pgx ErrNoRows on
-- missing — callers fall back to the daemon's REEVE_EMBEDDER env var
-- (server-default mode).
SELECT * FROM user_embedder_config
WHERE user_id = $1;

-- name: UpsertUserEmbedderConfig :one
-- Single-row upsert keyed by user_id. Conflict resolves by replacing
-- every field (no merge semantics) — the UI sends the whole row each
-- time and "clear my api_key" must work via an empty bytea.
INSERT INTO user_embedder_config (
    user_id, type, config, api_key_encrypted, enabled, updated_at
) VALUES (
    $1, $2, $3, $4, $5, NOW()
)
ON CONFLICT (user_id) DO UPDATE
SET type              = EXCLUDED.type,
    config            = EXCLUDED.config,
    api_key_encrypted = EXCLUDED.api_key_encrypted,
    enabled           = EXCLUDED.enabled,
    updated_at        = NOW()
RETURNING *;

-- name: DeleteUserEmbedderConfig :exec
DELETE FROM user_embedder_config WHERE user_id = $1;

-- name: ListUserEmbedderConfigs :many
-- The worker enumerates this to know which users have configured
-- embedders. Returning all rows in one shot is fine — we'd never
-- have more than a handful per Reeve instance.
SELECT * FROM user_embedder_config WHERE enabled = TRUE ORDER BY user_id;
