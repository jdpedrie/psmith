-- name: ListUserMCPServers :many
SELECT * FROM user_mcp_servers
WHERE user_id = $1
ORDER BY name, id;

-- name: GetUserMCPServer :one
SELECT * FROM user_mcp_servers
WHERE id = $1;

-- name: InsertUserMCPServer :one
INSERT INTO user_mcp_servers (id, user_id, name, config_encrypted)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: UpdateUserMCPServer :one
UPDATE user_mcp_servers
SET name = $3,
    config = NULL,
    config_encrypted = $4,
    updated_at = NOW()
WHERE id = $1 AND user_id = $2
RETURNING *;

-- name: DeleteUserMCPServer :execrows
DELETE FROM user_mcp_servers
WHERE id = $1 AND user_id = $2;
