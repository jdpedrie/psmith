-- +goose Up
-- Per-context Gemini cachedContents tracking.
--
-- When a profile/conversation enables `google.explicit_cache`, the
-- conversations service auto-creates a Gemini cache when the prefix
-- exceeds the model's minimum (1024 tokens on Flash, 4096 on Pro),
-- references it on subsequent turns, and refreshes on TTL expiry.
--
-- Stored per (context_id, model_id) since:
--   - A new context (post-Compact) has a different prefix → new cache.
--   - Switching models mid-conversation needs a model-specific cache
--     (cachedContents are model-scoped — a cache for Pro can't be used
--     by Flash and vice versa).
--
-- prefix_message_count records HOW MUCH of the wire prefix the cache
-- contains, so subsequent SendMessage calls can trim the contents
-- array to just the new turns. cache_name is the full Gemini resource
-- name ("cachedContents/abc123"). expires_at mirrors what Gemini
-- returns; we proactively recreate when within ~1 minute of expiry to
-- avoid mid-flight TTL races.

CREATE TABLE gemini_caches (
    context_id              UUID NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    model_id                TEXT NOT NULL,
    cache_name              TEXT NOT NULL,        -- "cachedContents/<id>"
    prefix_message_count    INTEGER NOT NULL,     -- N where wireMessages[:N] is in the cache
    prefix_hash             TEXT NOT NULL,        -- sha256 of the cached prefix bytes; sanity check
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (context_id, model_id)
);

CREATE INDEX gemini_caches_expires ON gemini_caches (expires_at);

-- +goose Down
DROP TABLE IF EXISTS gemini_caches;
