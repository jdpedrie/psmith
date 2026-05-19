-- +goose Up
--
-- Two related changes that together turn the plugin pipeline into a
-- mergeable, conversation-overridable system:
--
--   1. Add `disabled` to profile_plugins so a child profile can
--      explicitly drop a plugin it would otherwise inherit. Without
--      this, switching the resolver from "child overrides wholesale"
--      to "merge across chain" would force every existing child
--      profile to suddenly inherit its parent's plugins with no
--      escape hatch.
--
--   2. Create conversation_plugins — same shape as profile_plugins
--      but FK'd to conversations. The resolver merges in conversation
--      rows last (highest priority) so users can override or disable
--      a plugin for one conversation without forking the profile.
--
-- The encrypted-config split (`config_encrypted` non-null path,
-- `config` legacy plaintext fallback) mirrors profile_plugins so
-- crypto.ResolveSecret works the same way at read time.
--
-- Inheritance behaviour change (no backfill): existing child profiles
-- that have any plugin rows currently HIDE their parent's pipeline
-- entirely. With merge semantics they'll suddenly inherit parent
-- plugins again. Users who want to keep the old override behaviour
-- must add disabled=true rows for each parent plugin they want to
-- drop. Intentional — see commit message + docs/architecture.md.

ALTER TABLE profile_plugins
    ADD COLUMN disabled BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE conversation_plugins (
    conversation_id  UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    ordinal          INTEGER NOT NULL,
    plugin_name      TEXT NOT NULL,
    config           JSONB,
    config_encrypted BYTEA,
    disabled         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (conversation_id, ordinal)
);
CREATE INDEX conversation_plugins_name ON conversation_plugins (plugin_name);

-- +goose Down
DROP TABLE IF EXISTS conversation_plugins;
ALTER TABLE profile_plugins DROP COLUMN IF EXISTS disabled;
