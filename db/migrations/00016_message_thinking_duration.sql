-- +goose Up

-- Adds thinking_duration_ms so the UI can render "Thought for X.Ys" on
-- historical messages. The supervisor records it at materialization from
-- the elapsed time between the first and last `thinking_delta` chunk it
-- saw on the run; rows materialised before this migration carry NULL and
-- the UI falls back to a duration-less "Thought" badge.
--
-- INTEGER (ms) is plenty: we'll never see a thinking burst longer than
-- ~24 days (INT max), and the UI only needs ~0.1s precision anyway.

ALTER TABLE messages
    ADD COLUMN thinking_duration_ms INTEGER;

-- +goose Down

ALTER TABLE messages
    DROP COLUMN thinking_duration_ms;
