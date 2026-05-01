-- +goose Up

-- Adds the bottom layer of the 4-tier CallSettings resolution chain
-- (conversation > profile > model > provider). Provider-level defaults give
-- users a place to set "every conversation against this provider should pin
-- temperature=0.2 by default" — falling through to per-model and per-profile
-- overrides when those are set.
--
-- Storage shape mirrors the upper layers (`profiles.default_settings`,
-- `user_models.default_settings`): a JSONB blob carrying a `call_settings`
-- key whose contents marshal to `reeve.v1.CallSettings`. Additive — existing
-- rows carry NULL and resolve identically to "all unset, inherit nothing."
ALTER TABLE user_model_providers
    ADD COLUMN default_settings JSONB;

-- +goose Down

ALTER TABLE user_model_providers
    DROP COLUMN default_settings;
