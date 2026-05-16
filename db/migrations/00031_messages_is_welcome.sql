-- +goose Up
-- Marks an assistant message as the profile's welcome greeting,
-- inserted at conversation-create time. Clients gate a fake-stream
-- reveal animation on this flag (first open in an app session).
-- The row otherwise behaves like a normal assistant turn — included
-- in wire history, branchable, editable, etc.
ALTER TABLE messages ADD COLUMN is_welcome BOOLEAN NOT NULL DEFAULT FALSE;

-- +goose Down
ALTER TABLE messages DROP COLUMN is_welcome;
