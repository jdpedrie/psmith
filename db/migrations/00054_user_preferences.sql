-- +goose Up
-- Per-user client preferences that follow the user across devices.
-- A row exists once the user changes a setting; until then the
-- service returns defaults, so absence is a valid state.
--
-- context_warning_tokens: conversation context size past which the
-- clients warn. 0 = no warning (the default).
CREATE TABLE user_preferences (
    user_id                UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    context_warning_tokens INTEGER NOT NULL DEFAULT 0 CHECK (context_warning_tokens >= 0),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- +goose Down
DROP TABLE user_preferences;
