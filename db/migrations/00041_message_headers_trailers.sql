-- +goose Up
-- Plugin-contributed envelope blocks, persisted BESIDE the user's
-- content instead of baked into it. `content` stays exactly what the
-- user typed; the wire prefix composes headers + content + trailers.
-- Frozen at write time (same cache-stability contract the old
-- content-rewrite approach had), untouched by edits, invisible to
-- display/TTS/embeddings, which all read `content`.
ALTER TABLE messages ADD COLUMN message_headers  TEXT;
ALTER TABLE messages ADD COLUMN message_trailers TEXT;

-- +goose Down
ALTER TABLE messages DROP COLUMN message_trailers;
ALTER TABLE messages DROP COLUMN message_headers;
