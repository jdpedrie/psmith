-- +goose Up
-- Context-size-tiered pricing (grok-4.5-style: different rates when the
-- prompt exceeds a context threshold). JSONB array of tier objects:
--   [{"threshold_tokens": 128000, "input_per_million": 6.0,
--     "output_per_million": 30.0, "cache_read_per_million": 0.6,
--     "cache_write_per_million": null}, ...]
-- Semantics: the flat price columns are the base tier; the tier with the
-- HIGHEST threshold_tokens below the request's prompt-token count wins,
-- and any null subfield in the winning tier falls back to the base
-- column. The whole request prices at the winning tier (provider
-- semantics — not marginal). NULL/empty = no tiers (flat pricing).
ALTER TABLE user_models ADD COLUMN pricing_tiers JSONB;

-- +goose Down
ALTER TABLE user_models DROP COLUMN pricing_tiers;
