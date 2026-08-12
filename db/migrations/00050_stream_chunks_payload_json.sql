-- +goose Up
-- stream_chunks.payload is written on the hottest path in the system and never
-- read structurally: no query in db/queries uses ->, ->> or @>. The column is
-- fetched whole and handed to a client verbatim.
--
-- JSONB pays parse-and-normalize on every insert to buy operators and indexing
-- nobody uses here. JSON stores the text as given, which is what a write-heavy
-- opaque payload wants. The validation both types perform is the part worth
-- keeping, so this is not TEXT.
--
-- Safe to rewrite: the cleanup goroutine keeps this table to roughly an hour of
-- chunks, so it is small in practice regardless of how long the server has run.
ALTER TABLE stream_chunks
    ALTER COLUMN payload TYPE JSON USING payload::TEXT::JSON;

-- +goose Down
ALTER TABLE stream_chunks
    ALTER COLUMN payload TYPE JSONB USING payload::TEXT::JSONB;
