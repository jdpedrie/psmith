-- +goose Up

-- favorite: surfaces frequently-used profiles at the top of pickers.
-- Identity-style metadata, like name/description/parent_only — not merged
-- through the parent chain.
ALTER TABLE profiles
    ADD COLUMN favorite BOOLEAN NOT NULL DEFAULT FALSE;

-- +goose Down

ALTER TABLE profiles
    DROP COLUMN favorite;
