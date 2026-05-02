-- +goose Up
-- Per-user, per-plugin global config blob. Used for fields the plugin's
-- ConfigField descriptor marks as Global=true (e.g. brave_search.api_key)
-- — values the user only wants to enter once across every profile that
-- uses the plugin. At pipeline-build time the server merges the user's
-- stored global blob into the per-profile config blob handed to the
-- plugin constructor; profile-scoped config can still override on a
-- per-key basis.
--
-- (user_id, plugin_name) is unique — there's exactly one global config
-- per (user, plugin). When the plugin isn't yet configured globally,
-- the row simply doesn't exist; the merge code treats absence as an
-- empty object.
CREATE TABLE IF NOT EXISTS user_plugin_settings (
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plugin_name TEXT        NOT NULL,
    config      JSONB       NOT NULL DEFAULT '{}'::JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, plugin_name)
);

CREATE INDEX IF NOT EXISTS user_plugin_settings_user
    ON user_plugin_settings (user_id);

-- +goose Down
DROP TABLE IF EXISTS user_plugin_settings;
