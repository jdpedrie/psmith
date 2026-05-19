-- Plugin pipeline overrides scoped to one conversation. Merged on
-- top of the profile-chain plugins at resolve time — see
-- internal/conversations/service.resolvePluginPipeline.

-- name: ListConversationPlugins :many
SELECT * FROM conversation_plugins
WHERE conversation_id = $1
ORDER BY ordinal;

-- name: ReplaceConversationPlugins :exec
-- Atomic-swap pattern matching profile_plugins. Caller wraps this in
-- a transaction together with per-row InsertConversationPlugin calls.
DELETE FROM conversation_plugins WHERE conversation_id = $1;

-- name: InsertConversationPlugin :one
-- $4 = config_encrypted, $5 = disabled. Legacy plaintext `config`
-- column stays NULL on every new row; read path decrypts $4 and
-- falls back to the plaintext column only for the encryption-rollover
-- legacy case (which doesn't apply to a brand-new table but keeps
-- the read shape identical to profile_plugins).
INSERT INTO conversation_plugins (conversation_id, ordinal, plugin_name, config_encrypted, disabled)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;
