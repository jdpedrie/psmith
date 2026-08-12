-- +goose Up
-- Provider-side uploads of attachment blobs.
--
-- History assembly inlines every attachment in a conversation on every send,
-- so the same image is base64'd and pushed upstream once per turn for the life
-- of the chat. Providers that expose a Files API let the bytes cross once and
-- be referenced by id thereafter.
--
-- Keyed by (provider, sha256) rather than by message or conversation: blobs are
-- content-addressed, so one upload serves every message that references the
-- same bytes, across conversations. The provider row rather than the provider
-- TYPE because the upload lives behind one account's credentials and is not
-- visible to another.
--
-- user_id is denormalized from the provider so expiry sweeps and per-user
-- deletion do not need a join, and so a stray row can never be handed to the
-- wrong account.
CREATE TABLE provider_files (
    user_model_provider_id UUID NOT NULL REFERENCES user_model_providers(id) ON DELETE CASCADE,
    sha256                 TEXT NOT NULL,
    user_id                UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider_file_id       TEXT NOT NULL,
    mime_type              TEXT NOT NULL,
    size_bytes             BIGINT NOT NULL,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- NULL means the provider did not state an expiry. Those are treated as
    -- durable; a reference that turns out to be dead is handled at send time
    -- by falling back to inline bytes, not by guessing a lifetime here.
    expires_at             TIMESTAMPTZ,
    PRIMARY KEY (user_model_provider_id, sha256)
);

CREATE INDEX provider_files_expires ON provider_files (expires_at)
    WHERE expires_at IS NOT NULL;

-- +goose Down
DROP TABLE provider_files;
