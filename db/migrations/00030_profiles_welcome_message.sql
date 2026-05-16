-- +goose Up
-- Optional opening assistant message persisted at conversation-create
-- time and included in wire history sent to the LLM on every turn.
-- Snapshotted (not live-linked) — later edits to this field don't
-- mutate the welcome message in existing conversations. Inherits
-- through the parent chain like the other text fields (NULL = inherit).
--
-- See migration 00031 for the companion `messages.is_welcome` flag
-- that marks the inserted row.
ALTER TABLE profiles ADD COLUMN welcome_message TEXT;

-- +goose Down
ALTER TABLE profiles DROP COLUMN welcome_message;
