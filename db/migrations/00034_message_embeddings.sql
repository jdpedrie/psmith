-- +goose Up
--
-- Per-message vector embeddings for semantic search. Three new columns
-- on `messages`:
--
--   embedding       — the vector itself (768-dim — matches
--                     nomic-embed-text-v1.5, the default Ollama model).
--   embedding_model — the wire-stable identifier of the producer
--                     (e.g. "nomic-embed-text"). Lets Search scope to
--                     "rows produced by the active embedder" and the
--                     backfill worker find legacy rows.
--   embedding_at    — when the row was embedded. Cheap observability
--                     for the backfill UI and a tie-breaker if we
--                     ever want recency-aware results.
--
-- A different-dim model swap (e.g. moving to mxbai-embed-large at
-- 1024) will be a follow-up migration that adds a typed column
-- alongside this one and migrates rows over; pgvector requires a
-- fixed dim per column, so there's no clean way to make this
-- polymorphic in v1.
--
-- The `vector` extension must already be installed in the target
-- database. The install command (`reeve install`) runs the
-- ensure-vector preflight before goose.Up so a fresh deploy still
-- works one-shot, but the CREATE EXTENSION lives outside the
-- migration because it needs CREATE-on-database privilege the
-- migration runner often doesn't have (the pgtestdb test user
-- being the prototypical case).

ALTER TABLE messages
    ADD COLUMN embedding       vector(768),
    ADD COLUMN embedding_model TEXT,
    ADD COLUMN embedding_at    TIMESTAMPTZ;

-- All three move together. A row either has the full triple set or
-- has none of them — anything else is a write-path bug worth catching
-- loudly at insert time.
ALTER TABLE messages
    ADD CONSTRAINT messages_embedding_triple_invariant
    CHECK (
        (embedding IS NULL AND embedding_model IS NULL AND embedding_at IS NULL)
        OR
        (embedding IS NOT NULL AND embedding_model IS NOT NULL AND embedding_at IS NOT NULL)
    );

-- HNSW with cosine: best general-purpose semantic-search index for
-- single-digit-million-row catalogues. Partial WHERE keeps both build
-- and ongoing write cost zero until a row is actually embedded.
-- m=16, ef_construction=64 are pgvector's documented sane defaults
-- for "I haven't tuned anything yet" — fine for first-user scale.
CREATE INDEX messages_embedding_hnsw
    ON messages USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL;

-- Backfill worker's hot path: "give me messages still needing
-- embedding, oldest first." Partial index keeps it tiny — once
-- backfill catches up, this index has zero rows.
CREATE INDEX messages_unembedded_created_at
    ON messages (created_at)
    WHERE embedding IS NULL;

-- +goose Down
DROP INDEX IF EXISTS messages_unembedded_created_at;
DROP INDEX IF EXISTS messages_embedding_hnsw;
ALTER TABLE messages
    DROP CONSTRAINT IF EXISTS messages_embedding_triple_invariant,
    DROP COLUMN IF EXISTS embedding_at,
    DROP COLUMN IF EXISTS embedding_model,
    DROP COLUMN IF EXISTS embedding;
-- Don't DROP EXTENSION vector — other future tables may depend on it
-- and the extension itself is cheap to keep around.
