-- +goose Up

-- Cache observability for the chat-plugin pipeline. See "Chat plugins → Cache
-- observability" in docs/architecture.md.
--
-- prefix_hashes records the SHA-256 of each rendered wire-message in send
-- order at SendMessage time (post-plugin). The next SendMessage on the same
-- context compares positionally against this list to compute:
--   - cache_stable_prefix_length: count of leading positions whose hash
--     matches the previous turn's. That's the cache hit zone.
--   - cache_trailing_depth: previous_turn_prefix_length - stable. The
--     trailing positions whose bytes changed between turns and therefore
--     fell out of cache.
--
-- Stable/trailing are NULL on the first turn for a context (no previous to
-- compare against). The hash array is stored as a JSONB array of hex strings.
ALTER TABLE stream_runs
    ADD COLUMN prefix_hashes              JSONB,
    ADD COLUMN prefix_length              INTEGER,
    ADD COLUMN cache_stable_prefix_length INTEGER,
    ADD COLUMN cache_trailing_depth       INTEGER;

-- Lookup by context for "fetch the previous turn's hashes." Filter to rows
-- that actually recorded hashes so we skip turns that errored before the
-- prefix was ever built.
CREATE INDEX stream_runs_context_with_prefix
    ON stream_runs (context_id, started_at DESC)
    WHERE prefix_hashes IS NOT NULL;

-- +goose Down

DROP INDEX IF EXISTS stream_runs_context_with_prefix;
ALTER TABLE stream_runs
    DROP COLUMN cache_trailing_depth,
    DROP COLUMN cache_stable_prefix_length,
    DROP COLUMN prefix_length,
    DROP COLUMN prefix_hashes;
