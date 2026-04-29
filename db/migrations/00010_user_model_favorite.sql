-- +goose Up

-- favorite: surfaces frequently-used user models at the top of the model
-- picker. Identity-style metadata, like profiles.favorite — not part of the
-- snapshotted catalog metadata.
ALTER TABLE user_models
    ADD COLUMN favorite BOOLEAN NOT NULL DEFAULT FALSE;

-- +goose Down

ALTER TABLE user_models
    DROP COLUMN favorite;
