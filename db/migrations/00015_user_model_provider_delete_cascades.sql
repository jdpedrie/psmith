-- +goose Up

-- Provider deletion was failing with an FK constraint violation any time a
-- historical message, stream_run, harness_session, or profile still
-- referenced the provider. The original schema declared these FKs with no
-- ON DELETE clause (= NO ACTION), so the server's DeleteUserModelProvider
-- request returned Internal and the UI dropped it silently — looking like
-- "delete doesn't work."
--
-- Fix: switch every FK that points at user_model_providers(id) to ON DELETE
-- SET NULL. The semantics line up with how the rest of the schema handles
-- this kind of relationship:
--
--   * messages.provider_id (assistant turns): the produced-by link is
--     audit/display only. Losing the link when a provider is deleted is
--     fine — the conversation history stays intact, just shows "(deleted
--     provider)" or similar.
--
--   * stream_runs.provider_id: same — historical run rows survive their
--     provider going away. Mirrors how stream_runs.parent_message_id /
--     result_message_id already use ON DELETE SET NULL for messages.
--
--   * harness_sessions.provider_id: a deleted provider invalidates the
--     session anyway; the row becomes a tombstone rather than blocking the
--     user from removing the provider.
--
--   * profiles.compression_provider_id / profiles.title_provider_id: with
--     the column NULL, the profile silently falls back to its profile-chain
--     parent, then to "feature disabled" — exactly what users expect when
--     they remove the underlying provider.
--
-- One column flips from NOT NULL to NULLABLE: stream_runs.provider_id was
-- declared NOT NULL but ON DELETE SET NULL needs the column nullable. Live
-- run rows still get a non-null value at insert; only post-deletion stale
-- rows can carry NULL.

-- profiles
ALTER TABLE profiles
    DROP CONSTRAINT profiles_compression_provider_id_fkey,
    ADD CONSTRAINT profiles_compression_provider_id_fkey
        FOREIGN KEY (compression_provider_id)
        REFERENCES user_model_providers(id)
        ON DELETE SET NULL;

ALTER TABLE profiles
    DROP CONSTRAINT profiles_title_provider_id_fkey,
    ADD CONSTRAINT profiles_title_provider_id_fkey
        FOREIGN KEY (title_provider_id)
        REFERENCES user_model_providers(id)
        ON DELETE SET NULL;

-- messages
ALTER TABLE messages
    DROP CONSTRAINT messages_provider_id_fkey,
    ADD CONSTRAINT messages_provider_id_fkey
        FOREIGN KEY (provider_id)
        REFERENCES user_model_providers(id)
        ON DELETE SET NULL;

-- stream_runs (also relax NOT NULL on provider_id)
ALTER TABLE stream_runs
    ALTER COLUMN provider_id DROP NOT NULL;
ALTER TABLE stream_runs
    DROP CONSTRAINT stream_runs_provider_id_fkey,
    ADD CONSTRAINT stream_runs_provider_id_fkey
        FOREIGN KEY (provider_id)
        REFERENCES user_model_providers(id)
        ON DELETE SET NULL;

-- harness_sessions (also relax NOT NULL on provider_id)
ALTER TABLE harness_sessions
    ALTER COLUMN provider_id DROP NOT NULL;
ALTER TABLE harness_sessions
    DROP CONSTRAINT harness_sessions_provider_id_fkey,
    ADD CONSTRAINT harness_sessions_provider_id_fkey
        FOREIGN KEY (provider_id)
        REFERENCES user_model_providers(id)
        ON DELETE SET NULL;

-- +goose Down

ALTER TABLE harness_sessions
    DROP CONSTRAINT harness_sessions_provider_id_fkey,
    ADD CONSTRAINT harness_sessions_provider_id_fkey
        FOREIGN KEY (provider_id)
        REFERENCES user_model_providers(id);
ALTER TABLE harness_sessions
    ALTER COLUMN provider_id SET NOT NULL;

ALTER TABLE stream_runs
    DROP CONSTRAINT stream_runs_provider_id_fkey,
    ADD CONSTRAINT stream_runs_provider_id_fkey
        FOREIGN KEY (provider_id)
        REFERENCES user_model_providers(id);
ALTER TABLE stream_runs
    ALTER COLUMN provider_id SET NOT NULL;

ALTER TABLE messages
    DROP CONSTRAINT messages_provider_id_fkey,
    ADD CONSTRAINT messages_provider_id_fkey
        FOREIGN KEY (provider_id)
        REFERENCES user_model_providers(id);

ALTER TABLE profiles
    DROP CONSTRAINT profiles_title_provider_id_fkey,
    ADD CONSTRAINT profiles_title_provider_id_fkey
        FOREIGN KEY (title_provider_id)
        REFERENCES user_model_providers(id);

ALTER TABLE profiles
    DROP CONSTRAINT profiles_compression_provider_id_fkey,
    ADD CONSTRAINT profiles_compression_provider_id_fkey
        FOREIGN KEY (compression_provider_id)
        REFERENCES user_model_providers(id);
