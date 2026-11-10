-- +goose Up
-- Turning a model off deletes its row, except for a model added by hand: its
-- metadata (context window, pricing, capabilities) exists nowhere else, and no
-- provider listing offers it to turn back on. Those rows stay with
-- enabled = false. Every reader that feeds a picker or a send skips them.
ALTER TABLE user_models
    ADD COLUMN enabled boolean NOT NULL DEFAULT true;

-- +goose Down
DELETE FROM user_models WHERE NOT enabled;
ALTER TABLE user_models DROP COLUMN enabled;
