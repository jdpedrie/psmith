-- +goose Up
--
-- Per-user embedder choice. Mirrors `user_langfuse_config`:
-- singleton row keyed by user_id, type + config blob, with the
-- secret-bearing fields (today: api_key) decrypted at read time
-- via the same crypto.Cipher the rest of Reeve uses.
--
-- Why per-user instead of server-global: vectors only ever
-- compare meaningfully within the same model, so two users sharing
-- a Reeve instance need their own (chosen embedder, embedded rows,
-- search) triple. The `messages.embedding_model` column already
-- supports this — each row carries the producing model — so all
-- that's missing is "where does each user record their choice."
--
-- Lazy: the row is created on first GetEmbedderConfig write. Users
-- with no row fall back to the daemon's REEVE_EMBEDDER env var
-- (server-default mode). When the row exists it wins.

CREATE TABLE user_embedder_config (
    user_id           UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    -- Registered embedder type (e.g. "openai"). Empty means
    -- "disabled" — the daemon won't embed or search for this user
    -- even if other users on the same instance are configured.
    type              TEXT NOT NULL,
    -- JSON config blob. Non-secret fields (base_url, model,
    -- dimensions, timeout) live here in plaintext so the Get RPC
    -- can echo them back to the UI without a decrypt round-trip.
    config            JSONB NOT NULL DEFAULT '{}',
    -- Encrypted api_key (and any future secret fields). Stored
    -- separately from `config` so a key rotation only touches this
    -- column and Get can return the non-secret bits without ever
    -- needing the cipher. Empty = no key (Ollama-style local
    -- endpoint).
    api_key_encrypted BYTEA,
    enabled           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- +goose Down
DROP TABLE IF EXISTS user_embedder_config;
