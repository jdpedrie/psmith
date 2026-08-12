-- name: CreateSession :exec
INSERT INTO sessions (token_hash, user_id, client_label, expires_at)
VALUES ($1, $2, $3, $4);

-- name: GetSessionWithUser :one
SELECT
    s.token_hash,
    s.user_id,
    s.client_label,
    s.created_at AS session_created_at,
    s.last_used_at,
    s.expires_at,
    u.id              AS user_id_full,
    u.username        AS username,
    u.display_name    AS display_name,
    u.password_hash   AS password_hash,
    u.is_admin        AS is_admin,
    u.created_at      AS user_created_at,
    u.updated_at      AS user_updated_at
FROM sessions s
JOIN users u ON s.user_id = u.id
WHERE s.token_hash = $1 AND s.expires_at > NOW();

-- name: TouchSession :exec
-- Coarse last-seen tracking, deliberately.
--
-- This runs on every authenticated request, so without the interval guard
-- every read becomes a write: the same row is dirtied at request rate,
-- concurrent requests from one session serialize on its lock, and the table
-- accumulates dead tuples for a column nobody reads with precision. The guard
-- makes the common case a no-op UPDATE that touches no rows.
--
-- The cost is that last_used_at can lag by up to the interval. Nothing depends
-- on it being exact; it exists so a human can see whether a session is stale.
UPDATE sessions
SET last_used_at = NOW()
WHERE token_hash = $1
  AND last_used_at < NOW() - INTERVAL '5 minutes';

-- name: DeleteSession :exec
DELETE FROM sessions WHERE token_hash = $1;

-- name: DeleteExpiredSessions :exec
DELETE FROM sessions WHERE expires_at <= NOW();
