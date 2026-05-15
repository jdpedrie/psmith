-- name: GetUserLangfuseConfig :one
-- Returns the user's Langfuse config row, if any. pgx ErrNoRows on
-- absent — service layer maps that to "tracing disabled" rather than
-- a hard error so the GET RPC can return the default-disabled shape.
SELECT * FROM user_langfuse_config
WHERE user_id = $1;

-- name: UpsertUserLangfuseConfig :one
-- Single-call full replace. The service layer reads the existing row
-- (if any), merges request fields onto it, then calls this — same
-- pattern as UpdateUserModel. secret_key (plaintext column) is
-- always cleared by this query; we never write to it from the
-- service path. The legacy column exists only for the rollover
-- window described on the table comment.
INSERT INTO user_langfuse_config (
    user_id, host, public_key, secret_key_encrypted, enabled, updated_at
) VALUES ($1, $2, $3, $4, $5, NOW())
ON CONFLICT (user_id) DO UPDATE SET
    host                 = EXCLUDED.host,
    public_key           = EXCLUDED.public_key,
    secret_key_encrypted = EXCLUDED.secret_key_encrypted,
    enabled              = EXCLUDED.enabled,
    secret_key           = NULL,
    updated_at           = NOW()
RETURNING *;

-- name: DeleteUserLangfuseConfig :exec
-- Removes the entire row. Drops both credentials and the enabled
-- toggle in one shot — for users who want to fully sever the
-- integration rather than just disable it.
DELETE FROM user_langfuse_config WHERE user_id = $1;
