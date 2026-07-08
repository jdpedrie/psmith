-- name: GetUserTTSConfig :one
-- pgx ErrNoRows on missing — callers treat absence as the apple_local
-- default (on-device synthesis, nothing to configure).
SELECT * FROM user_tts_config
WHERE user_id = $1;

-- name: UpsertUserTTSConfig :one
-- Single-row upsert keyed by user_id; conflict replaces every field
-- (the service sparse-merges before calling, and "clear my api_key"
-- must work via an empty bytea).
INSERT INTO user_tts_config (
    user_id, kind, config, api_key_encrypted, provider_ref, enabled, updated_at
) VALUES (
    $1, $2, $3, $4, $5, $6, NOW()
)
ON CONFLICT (user_id) DO UPDATE
SET kind              = EXCLUDED.kind,
    config            = EXCLUDED.config,
    api_key_encrypted = EXCLUDED.api_key_encrypted,
    provider_ref      = EXCLUDED.provider_ref,
    enabled           = EXCLUDED.enabled,
    updated_at        = NOW()
RETURNING *;

-- name: DeleteUserTTSConfig :exec
DELETE FROM user_tts_config WHERE user_id = $1;
