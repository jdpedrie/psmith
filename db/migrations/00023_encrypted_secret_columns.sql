-- +goose Up
--
-- API keys and other credentials live in three JSONB config blobs:
--   user_model_providers.config    — provider api_key + base_url, etc.
--   user_plugin_settings.config    — per-user plugin globals (brave_search api_key)
--   profile_plugins.config         — per-profile plugin overrides
--
-- This migration adds an opaque BYTEA twin column to each. The
-- application's read path checks the encrypted column first; if NULL,
-- it falls back to the existing plaintext JSONB so unmigrated rows
-- keep working through the rollover. The write path only ever writes
-- the encrypted column and clears the plaintext one — so any row
-- touched after the rollout becomes encrypted automatically.
--
-- A future migration drops the old `config` column once all rows have
-- been touched (or after a one-shot `reeve encrypt-secrets` rewrites
-- everything in place). Splitting into two migrations means there's
-- no point at which a running server is reading from a column that
-- doesn't exist.
--
-- Existing `config NOT NULL` constraints are relaxed to NULL so the
-- write path can null out the plaintext column without violating the
-- schema. The application enforces "exactly one of config /
-- config_encrypted is non-null" in its read path.

ALTER TABLE user_model_providers
    ALTER COLUMN config DROP NOT NULL,
    ADD COLUMN config_encrypted BYTEA;

ALTER TABLE user_plugin_settings
    ALTER COLUMN config DROP NOT NULL,
    ADD COLUMN config_encrypted BYTEA;

-- profile_plugins.config was already nullable (per 00004); only the
-- encrypted twin needs adding.
ALTER TABLE profile_plugins
    ADD COLUMN config_encrypted BYTEA;

-- +goose Down

ALTER TABLE profile_plugins
    DROP COLUMN config_encrypted;

ALTER TABLE user_plugin_settings
    DROP COLUMN config_encrypted,
    ALTER COLUMN config SET NOT NULL;

ALTER TABLE user_model_providers
    DROP COLUMN config_encrypted,
    ALTER COLUMN config SET NOT NULL;
