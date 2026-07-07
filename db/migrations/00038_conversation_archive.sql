-- +goose Up
-- Archived conversations leave the main list and become read-only: every
-- mutating RPC refuses them until unarchived. A timestamp rather than a
-- boolean records when it happened and gives the archive list a sort key.
ALTER TABLE conversations ADD COLUMN archived_at TIMESTAMPTZ;

-- +goose Down
ALTER TABLE conversations DROP COLUMN archived_at;
