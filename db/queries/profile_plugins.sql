-- name: ListProfilePlugins :many
-- Returns the ordered plugin pipeline for one profile (no inheritance walk;
-- callers do the walk in code so they can short-circuit on a profile that
-- defines its own pipeline).
SELECT * FROM profile_plugins
WHERE profile_id = $1
ORDER BY ordinal;

-- name: ReplaceProfilePlugins :exec
-- Atomically swap the pipeline. Caller wraps this in a transaction along with
-- the per-row inserts via InsertProfilePlugin (an in-tx loop) — there's no
-- batch-insert sqlc emit for an arbitrary slice.
DELETE FROM profile_plugins WHERE profile_id = $1;

-- name: InsertProfilePlugin :one
-- $4 is config_encrypted (nullable BYTEA); the legacy plaintext
-- config column is left NULL on every new row. The service layer's
-- read path decrypts config_encrypted and falls back to the plaintext
-- column for legacy rows still carrying their pre-rollover JSONB.
-- $5 is `disabled` — when TRUE the resolver drops any same-named
-- plugin inherited from this profile's parent chain (the explicit-
-- subtract escape hatch for the merge resolver).
INSERT INTO profile_plugins (profile_id, ordinal, plugin_name, config_encrypted, disabled)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: UpdateProfilePluginConfig :exec
-- Overwrite the encrypted config for one plugin entry in a profile's
-- pipeline. Also clears the legacy plaintext column so a read can't
-- accidentally fall back to it after an upgrade. Used by the system-
-- profile backfill to repair stale configs left over from older seed
-- versions; ordinary plugin edits go through ReplaceProfilePlugins +
-- InsertProfilePlugin (atomic whole-pipeline swap).
UPDATE profile_plugins
SET config_encrypted = $3, config = NULL
WHERE profile_id = $1 AND plugin_name = $2;
