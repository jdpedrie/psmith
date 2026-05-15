-- +goose Up
-- Per-user Langfuse observability config. Optional: a row only exists
-- once the user has touched the Langfuse settings page. Credentials
-- are stored encrypted via the same AES-GCM cipher as
-- user_model_providers.config (see internal/crypto). The plaintext
-- secret_key column carries legacy / pre-encryption rows during the
-- rollover window — same dual-column pattern documented on
-- user_model_providers.
--
-- enabled is the master toggle: when false, the supervisor hook
-- short-circuits and no events leave the box even if credentials are
-- set. UI lets users keep credentials configured + tracing paused.
--
-- host defaults to Langfuse Cloud's US region; users on EU cloud or
-- self-hosted instances overwrite. The trailing slash is stripped at
-- write time (the client appends `/api/public/ingestion`).
CREATE TABLE user_langfuse_config (
    user_id              UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    host                 TEXT NOT NULL DEFAULT 'https://us.cloud.langfuse.com',
    public_key           TEXT NOT NULL DEFAULT '',
    secret_key_encrypted BYTEA,
    secret_key           TEXT,
    enabled              BOOLEAN NOT NULL DEFAULT FALSE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- +goose Down
DROP TABLE user_langfuse_config;
