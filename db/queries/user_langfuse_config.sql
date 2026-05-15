-- name: GetUserLangfuseConfig :one
-- Returns the user's Langfuse config row, if any. pgx ErrNoRows on
-- absent — service layer maps that to "tracing disabled" rather than
-- a hard error so the GET RPC can return the default-disabled shape.
SELECT * FROM user_langfuse_config
WHERE user_id = $1;

-- name: UpsertUserLangfuseConfig :one
-- Single-call full replace. The service layer reads the existing row
-- (if any), merges request fields onto it, then calls this — same
-- pattern as UpdateUserModel. secret_key_encrypted is the only
-- credential column; the value is AES-GCM encrypted before it
-- reaches this query (see internal/langfusesvc).
INSERT INTO user_langfuse_config (
    user_id, host, public_key, secret_key_encrypted, enabled, updated_at
) VALUES ($1, $2, $3, $4, $5, NOW())
ON CONFLICT (user_id) DO UPDATE SET
    host                 = EXCLUDED.host,
    public_key           = EXCLUDED.public_key,
    secret_key_encrypted = EXCLUDED.secret_key_encrypted,
    enabled              = EXCLUDED.enabled,
    updated_at           = NOW()
RETURNING *;

-- name: DeleteUserLangfuseConfig :exec
-- Removes the entire row. Drops both credentials and the enabled
-- toggle in one shot — for users who want to fully sever the
-- integration rather than just disable it.
DELETE FROM user_langfuse_config WHERE user_id = $1;

-- name: ListUserLangfuseConfigs :many
-- Every existing row across all users. Used at server boot to prime
-- the in-memory emitter cache so tracing works for the very first
-- assistant turn after a restart, not just after the first
-- LangfuseService.Update RPC of the new process.
SELECT * FROM user_langfuse_config ORDER BY user_id;
