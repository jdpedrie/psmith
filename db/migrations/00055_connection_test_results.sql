-- +goose Up
-- The last connection test of a provider or MCP server, and the model ids a
-- provider's last discovery found. Settings shows them as a status dot, a
-- "3 new" badge and a failing-server count; kept in process memory they reset
-- on every restart.
ALTER TABLE user_model_providers
    ADD COLUMN last_test_at timestamptz,
    ADD COLUMN last_test_ok boolean NOT NULL DEFAULT false,
    ADD COLUMN last_test_latency_ms bigint NOT NULL DEFAULT 0,
    ADD COLUMN last_test_message text NOT NULL DEFAULT '',
    ADD COLUMN last_discovered_model_ids text[];

ALTER TABLE user_mcp_servers
    ADD COLUMN last_test_at timestamptz,
    ADD COLUMN last_test_ok boolean NOT NULL DEFAULT false,
    ADD COLUMN last_test_message text NOT NULL DEFAULT '',
    ADD COLUMN last_test_tool_count integer NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE user_mcp_servers
    DROP COLUMN last_test_at,
    DROP COLUMN last_test_ok,
    DROP COLUMN last_test_message,
    DROP COLUMN last_test_tool_count;

ALTER TABLE user_model_providers
    DROP COLUMN last_test_at,
    DROP COLUMN last_test_ok,
    DROP COLUMN last_test_latency_ms,
    DROP COLUMN last_test_message,
    DROP COLUMN last_discovered_model_ids;
