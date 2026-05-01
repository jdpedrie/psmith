-- +goose Up
-- Generalize the per-context cache tracking from Google-specific
-- (gemini_caches) to provider-agnostic (explicit_caches). The old
-- table only held Gemini cachedContents resource names; the new
-- shape adds provider_type so any driver implementing
-- providers.ExplicitCacheProvider (Google today; Anthropic in the
-- future, if its cache_control auto-placement gains a toggle) can
-- store its opaque cache reference here.
--
-- cache_ref replaces cache_name — for Google it's still
-- "cachedContents/<id>"; for other drivers it's whatever opaque
-- string the driver hands back from CreateExplicitCacheRef.
--
-- Existing rows are preserved (data-preserving migration). Since
-- Gemini was the only writer, we backfill provider_type='google'.

CREATE TABLE explicit_caches (
    context_id              UUID NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    provider_type           TEXT NOT NULL,        -- "google" today; "anthropic", etc. later
    model_id                TEXT NOT NULL,
    cache_ref               TEXT NOT NULL,        -- driver-opaque reference
    prefix_message_count    INTEGER NOT NULL,
    prefix_hash             TEXT NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (context_id, provider_type, model_id)
);

CREATE INDEX explicit_caches_expires ON explicit_caches (expires_at);

-- Backfill any existing rows from gemini_caches.
INSERT INTO explicit_caches
    (context_id, provider_type, model_id, cache_ref, prefix_message_count, prefix_hash, created_at, expires_at)
SELECT
    context_id, 'google', model_id, cache_name, prefix_message_count, prefix_hash, created_at, expires_at
FROM gemini_caches;

DROP TABLE gemini_caches;

-- +goose Down
CREATE TABLE gemini_caches (
    context_id              UUID NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    model_id                TEXT NOT NULL,
    cache_name              TEXT NOT NULL,
    prefix_message_count    INTEGER NOT NULL,
    prefix_hash             TEXT NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (context_id, model_id)
);
CREATE INDEX gemini_caches_expires ON gemini_caches (expires_at);

INSERT INTO gemini_caches
    (context_id, model_id, cache_name, prefix_message_count, prefix_hash, created_at, expires_at)
SELECT
    context_id, model_id, cache_ref, prefix_message_count, prefix_hash, created_at, expires_at
FROM explicit_caches WHERE provider_type='google';

DROP TABLE explicit_caches;
