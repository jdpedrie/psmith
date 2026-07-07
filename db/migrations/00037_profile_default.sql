-- +goose Up
-- One profile per user may be the default: tapping "new conversation"
-- creates directly with it instead of showing the profile chooser. The
-- partial unique index makes "at most one default per user" a database
-- invariant rather than an application promise.
ALTER TABLE profiles ADD COLUMN is_default BOOLEAN NOT NULL DEFAULT FALSE;
CREATE UNIQUE INDEX profiles_one_default_per_user ON profiles (user_id) WHERE is_default;

-- +goose Down
DROP INDEX profiles_one_default_per_user;
ALTER TABLE profiles DROP COLUMN is_default;
