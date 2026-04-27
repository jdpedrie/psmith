-- +goose Up

-- profile_plugins holds the ordered chat-plugin pipeline attached to a profile.
-- Inheritance is all-or-nothing through the profile parent chain: if a profile
-- has any rows here, that's its full pipeline; otherwise the resolver walks
-- to the parent.
--
-- See "Chat plugins → Configuration and scope" in docs/architecture.md.
CREATE TABLE profile_plugins (
    profile_id  UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    ordinal     INTEGER NOT NULL,
    plugin_name TEXT NOT NULL,
    config      JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (profile_id, ordinal)
);
CREATE INDEX profile_plugins_name ON profile_plugins (plugin_name);

-- +goose Down

DROP TABLE IF EXISTS profile_plugins;
