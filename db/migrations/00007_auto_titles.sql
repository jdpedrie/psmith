-- +goose Up

-- Profile-level configuration for the auto-title generation feature.
-- All three are nullable + inheritable through the parent-profile chain
-- (mirrors the compression_* fields). When any are unset (after parent
-- resolution), title generation is skipped silently.
ALTER TABLE profiles
    ADD COLUMN title_provider_id UUID REFERENCES user_model_providers(id),
    ADD COLUMN title_model_id    TEXT,
    ADD COLUMN title_guide       TEXT;

-- Context-level human-friendly title. Populated by the title-generation
-- background goroutine after the FIRST assistant turn lands in this
-- context (covers both the initial context and post-compaction contexts).
-- Editable by the user via UpdateContextTitle.
ALTER TABLE contexts
    ADD COLUMN title TEXT;

-- +goose Down

ALTER TABLE contexts
    DROP COLUMN title;

ALTER TABLE profiles
    DROP COLUMN title_guide,
    DROP COLUMN title_model_id,
    DROP COLUMN title_provider_id;
