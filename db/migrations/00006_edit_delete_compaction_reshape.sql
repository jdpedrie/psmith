-- +goose Up

-- Add ON DELETE CASCADE to messages.parent_id so DeleteMessage(cascade=true)
-- is a single DELETE that takes the descendant subtree with it. The
-- DeleteMessage(cascade=false) path REPARENTs children before deleting (so
-- the cascade has nothing to find).
ALTER TABLE messages
    DROP CONSTRAINT messages_parent_id_fkey;
ALTER TABLE messages
    ADD CONSTRAINT messages_parent_id_fkey
    FOREIGN KEY (parent_id) REFERENCES messages(id) ON DELETE CASCADE;

-- stream_runs reference messages via parent_message_id and result_message_id.
-- Switch both to ON DELETE SET NULL so deleting a message preserves the
-- historical run row (with its usage/cost/cache observability) but loses the
-- dangling link.
ALTER TABLE stream_runs
    DROP CONSTRAINT stream_runs_parent_message_id_fkey;
ALTER TABLE stream_runs
    ADD CONSTRAINT stream_runs_parent_message_id_fkey
    FOREIGN KEY (parent_message_id) REFERENCES messages(id) ON DELETE SET NULL;

ALTER TABLE stream_runs
    DROP CONSTRAINT stream_runs_result_message_id_fkey;
ALTER TABLE stream_runs
    ADD CONSTRAINT stream_runs_result_message_id_fkey
    FOREIGN KEY (result_message_id) REFERENCES messages(id) ON DELETE SET NULL;

-- edited_at is set by EditMessage (in-place mutation of content / role).
-- Null means the message has never been edited; UI shows "edited <relative time>"
-- only when this is non-null.
ALTER TABLE messages
    ADD COLUMN edited_at TIMESTAMPTZ;

-- +goose Down

ALTER TABLE messages
    DROP COLUMN edited_at;

ALTER TABLE stream_runs
    DROP CONSTRAINT stream_runs_result_message_id_fkey;
ALTER TABLE stream_runs
    ADD CONSTRAINT stream_runs_result_message_id_fkey
    FOREIGN KEY (result_message_id) REFERENCES messages(id);

ALTER TABLE stream_runs
    DROP CONSTRAINT stream_runs_parent_message_id_fkey;
ALTER TABLE stream_runs
    ADD CONSTRAINT stream_runs_parent_message_id_fkey
    FOREIGN KEY (parent_message_id) REFERENCES messages(id);

ALTER TABLE messages
    DROP CONSTRAINT messages_parent_id_fkey;
ALTER TABLE messages
    ADD CONSTRAINT messages_parent_id_fkey
    FOREIGN KEY (parent_id) REFERENCES messages(id);
