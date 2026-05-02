-- name: GetUserPluginSettings :one
-- Returns the row for one (user, plugin) — caller decides what "missing"
-- means (sqlc emits ErrNoRows on no match; the service layer treats that
-- as an empty config and returns `{}` to the wire).
SELECT * FROM user_plugin_settings
WHERE user_id = $1 AND plugin_name = $2;

-- name: ListUserPluginSettings :many
-- All globally-configured plugins for a user. Drives the "Plugin
-- settings" page; missing rows mean "not yet configured" and need a
-- defaults-from-descriptor render at the UI layer.
SELECT * FROM user_plugin_settings
WHERE user_id = $1
ORDER BY plugin_name;

-- name: UpsertUserPluginSettings :one
-- Idempotent: insert-or-update. updated_at is bumped to NOW() on every
-- save. Empty config (`{}`) is a valid stored value — it means "the
-- user explicitly cleared every global field" and should beat the
-- absence-is-empty fallback at merge time.
INSERT INTO user_plugin_settings (user_id, plugin_name, config)
VALUES ($1, $2, $3)
ON CONFLICT (user_id, plugin_name) DO UPDATE
    SET config     = EXCLUDED.config,
        updated_at = NOW()
RETURNING *;

-- name: DeleteUserPluginSettings :exec
DELETE FROM user_plugin_settings
WHERE user_id = $1 AND plugin_name = $2;
