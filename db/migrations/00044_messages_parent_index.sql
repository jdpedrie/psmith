-- +goose Up
-- ReparentChildren (the DeleteMessage stitch path) and every other
-- parent-only lookup filter on parent_id alone; the existing composite
-- (context_id, parent_id) index can't serve a bare parent_id predicate,
-- so each stitch delete paid a sequential scan of messages.
CREATE INDEX IF NOT EXISTS messages_parent ON messages (parent_id);

-- +goose Down
DROP INDEX IF EXISTS messages_parent;
