-- name: GetUserPreferences :one
-- The user's preferences row, if any. pgx ErrNoRows when the user has
-- never changed a setting; the service maps that to the defaults.
SELECT * FROM user_preferences
WHERE user_id = $1;

-- name: UpsertUserPreferences :one
-- Full replace of the row. The service merges the request's set fields
-- onto the current values (or the defaults) before calling this.
INSERT INTO user_preferences (user_id, context_warning_tokens, updated_at)
VALUES ($1, $2, NOW())
ON CONFLICT (user_id) DO UPDATE SET
    context_warning_tokens = EXCLUDED.context_warning_tokens,
    updated_at             = NOW()
RETURNING *;
