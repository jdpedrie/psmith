-- +goose Up

-- Captures the failure metadata for a stream run that errored or was cancelled
-- mid-flight, so the materialized message row carries the error inline (in
-- addition to the canonical copy on `stream_runs.error_payload`). Lets the UI
-- render failed assistant turns and failed compactions as first-class history
-- entries — partial content + error text + provider/model identification —
-- instead of throwing them away with a transient banner. NULL on successful
-- runs.
ALTER TABLE messages
    ADD COLUMN error_payload JSONB;

-- +goose Down

ALTER TABLE messages
    DROP COLUMN error_payload;
