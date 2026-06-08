-- name: InsertDeviceToolCall :one
-- Persist one completed device-tool call. Written by the
-- conversations service from the broker's completion hook,
-- right after the matching POST /respond returns.
INSERT INTO device_tool_calls (
    id, user_id, conversation_id, message_id,
    tool_name, input_json, output_json,
    status, error_message,
    invoked_at, completed_at
) VALUES (
    $1, $2, $3, $4,
    $5, $6, $7,
    $8, $9,
    $10, $11
)
RETURNING *;

-- name: ListDeviceToolCallsByUser :many
-- Recent-first paginated list for the Settings → Device tool
-- activity page. `cursor` is the invoked_at of the last row from
-- the previous page; pass NULL for the first page.
SELECT *
FROM device_tool_calls
WHERE user_id = $1
  AND ($2::TIMESTAMPTZ IS NULL OR invoked_at < $2)
ORDER BY invoked_at DESC
LIMIT $3;

-- name: ListDeviceToolCallsByConversation :many
-- Same shape as ListDeviceToolCallsByUser but conversation-scoped
-- — used by future per-conversation activity affordances. Caller
-- must have already verified ownership via the conversation row.
SELECT *
FROM device_tool_calls
WHERE conversation_id = $1
  AND ($2::TIMESTAMPTZ IS NULL OR invoked_at < $2)
ORDER BY invoked_at DESC
LIMIT $3;

-- name: CountDeviceToolCallsByUser :one
-- For the "X calls in the last 7 days" chip on settings.
SELECT COUNT(*)::INT
FROM device_tool_calls
WHERE user_id = $1
  AND invoked_at >= NOW() - ($2::INTERVAL);
