-- +goose Up
-- User-level MCP server registry. One row = one named server spec
-- (transport + command/args/env or url/headers + default tool prefix)
-- stored as the same JSON shape the mcp plugin's config blob uses, so
-- pipeline-build resolution hands it to the plugin constructor as-is.
-- Registered servers surface as pseudo-plugins ("mcp:<id>") in
-- ListPluginTypes; profile/conversation pipeline rows store only that
-- reference and never carry the secret-bearing spec themselves.
--
-- The config / config_encrypted split mirrors profile_plugins:
-- crypto.ResolveSecret reads whichever is populated; writes always go
-- to config_encrypted (plaintext bytes under crypto.Nop).
--
-- id is its own PK (not (user_id, name)) because pipeline rows
-- reference the server by id — renames must not orphan attachments,
-- and globally-unique ids leave room for shared/household registry
-- entries later.
CREATE TABLE user_mcp_servers (
    id               UUID PRIMARY KEY,
    user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name             TEXT NOT NULL,
    config           JSONB,
    config_encrypted BYTEA,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, name)
);

CREATE INDEX user_mcp_servers_user ON user_mcp_servers (user_id);

-- +goose Down
DROP TABLE IF EXISTS user_mcp_servers;
