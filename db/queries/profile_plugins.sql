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
INSERT INTO profile_plugins (profile_id, ordinal, plugin_name, config)
VALUES ($1, $2, $3, $4)
RETURNING *;
