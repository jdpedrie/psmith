-- +goose Up
--
-- Per-user speech (TTS) config. Mirrors user_embedder_config: a
-- singleton row keyed by user_id, kind + non-secret JSON config,
-- secret api_key in its own encrypted column. Absence of a row means
-- the default kind, apple_local — on-device synthesis, no server
-- involvement — so speech works before anything is configured.
--
-- provider_ref is the credential-reuse path: for kinds whose vendor
-- is already a configured chat provider (grok/xAI, OpenAI), the row
-- points at the user_model_providers row and the speech driver pulls
-- the api_key from there at build time — one key, encrypted once,
-- shared by both drivers. ON DELETE SET NULL: deleting the chat
-- provider degrades speech to "no credential" (Test fails loudly)
-- rather than blocking the delete.

CREATE TABLE user_tts_config (
    user_id           UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- Registered speech kind ("apple_local", "grok",
    -- "openai-compatible").
    kind              TEXT NOT NULL,
    -- Non-secret config (voice, model, speed, base_url) in plaintext
    -- so Get echoes it without a decrypt round-trip.
    config            JSONB NOT NULL DEFAULT '{}',
    -- Encrypted standalone api_key. Empty when the key rides in via
    -- provider_ref or the kind needs none.
    api_key_encrypted BYTEA,
    -- Optional reference to a chat provider row whose api_key the
    -- speech driver reuses.
    provider_ref      UUID REFERENCES user_model_providers(id) ON DELETE SET NULL,
    enabled           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- +goose Down
DROP TABLE IF EXISTS user_tts_config;
