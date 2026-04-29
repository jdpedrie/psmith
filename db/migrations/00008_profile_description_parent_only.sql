-- +goose Up

-- description: free-form per-profile text shown in the picker / detail
-- viewer. Stored as NOT NULL with empty-string default so it never has to
-- be merged from a parent (it's identity metadata, like `name`).
--
-- parent_only: when true, the profile is hidden from the new-conversation
-- picker and only usable as a parent for inheritance. Defaults to false so
-- existing rows remain chat-capable.
ALTER TABLE profiles
    ADD COLUMN description  TEXT    NOT NULL DEFAULT '',
    ADD COLUMN parent_only  BOOLEAN NOT NULL DEFAULT FALSE;

-- +goose Down

ALTER TABLE profiles
    DROP COLUMN parent_only,
    DROP COLUMN description;
