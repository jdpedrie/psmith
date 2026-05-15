-- +goose Up
-- Per-user Langfuse observability config. Optional: a row only exists
-- once the user has touched the Langfuse settings page.
--
-- The secret_key is stored ONLY in encrypted form (AES-GCM via the
-- same internal/crypto cipher that protects
-- user_model_providers.config_encrypted). No plaintext fallback
-- column — this table is brand-new so there's no rollover history
-- to defend against, and the absent column keeps anyone reading the
-- DB by hand from accidentally seeing a secret.
--
-- enabled is the master toggle: when false, the supervisor hook
-- short-circuits and no events leave the box even if credentials are
-- set. The settings page lets users keep credentials saved while
-- pausing emit.
--
-- host defaults to Langfuse Cloud's US region; users on EU cloud or
-- self-hosted instances overwrite. The trailing slash is stripped at
-- write time (the client appends `/api/public/ingestion`).
CREATE TABLE user_langfuse_config (
    user_id              UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    host                 TEXT NOT NULL DEFAULT 'https://us.cloud.langfuse.com',
    public_key           TEXT NOT NULL DEFAULT '',
    secret_key_encrypted BYTEA,
    enabled              BOOLEAN NOT NULL DEFAULT FALSE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- +goose Down
DROP TABLE user_langfuse_config;
