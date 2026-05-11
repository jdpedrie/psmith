-- +goose Up
-- Add finish_reason TEXT to messages so the UI can surface unexpected
-- termination causes (max_tokens, content_filter, length, tool_calls,
-- etc.) on the assistant bubble footer. Per-provider strings are stored
-- verbatim — the UI normalises the "expected" set (stop / end_turn /
-- STOP) and only renders when the value is something else.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS finish_reason TEXT;

-- +goose Down
ALTER TABLE messages DROP COLUMN IF EXISTS finish_reason;
