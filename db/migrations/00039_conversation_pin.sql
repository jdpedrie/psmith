-- +goose Up
-- Pinned conversations render above the paged list, newest pin first.
-- Pin and archive are mutually exclusive: archiving clears the pin, and
-- pinning an archived conversation is refused (it's a mutation).
ALTER TABLE conversations ADD COLUMN pinned_at TIMESTAMPTZ;

-- +goose Down
ALTER TABLE conversations DROP COLUMN pinned_at;
