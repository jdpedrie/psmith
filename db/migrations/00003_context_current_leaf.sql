-- +goose Up

-- Per-context current leaf: "the tip the user is currently viewing in this
-- context." Drives SendMessage's parent resolution and lets multi-device
-- clients converge on the same view. Nullable: fresh contexts have no cursor
-- until the first SendMessage advances it.
--
-- ON DELETE SET NULL: deleting the referenced message clears the cursor; the
-- next SendMessage falls through to the latest-by-created_at fallback.
ALTER TABLE contexts
    ADD COLUMN current_leaf_message_id UUID REFERENCES messages(id) ON DELETE SET NULL;

-- +goose Down

ALTER TABLE contexts
    DROP COLUMN current_leaf_message_id;
