-- name: UpsertUserModel :one
INSERT INTO user_models (
    user_model_provider_id, model_id, display_name,
    context_window, max_output_tokens,
    input_price_per_million, output_price_per_million,
    cache_read_per_million, cache_write_per_million,
    knowledge_cutoff, modalities, capabilities, default_settings,
    metadata_source, metadata_snapshot_at
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
ON CONFLICT (user_model_provider_id, model_id) DO UPDATE SET
    display_name              = EXCLUDED.display_name,
    context_window            = EXCLUDED.context_window,
    max_output_tokens         = EXCLUDED.max_output_tokens,
    input_price_per_million   = EXCLUDED.input_price_per_million,
    output_price_per_million  = EXCLUDED.output_price_per_million,
    cache_read_per_million    = EXCLUDED.cache_read_per_million,
    cache_write_per_million   = EXCLUDED.cache_write_per_million,
    knowledge_cutoff          = EXCLUDED.knowledge_cutoff,
    modalities                = EXCLUDED.modalities,
    capabilities              = EXCLUDED.capabilities,
    default_settings          = EXCLUDED.default_settings,
    metadata_source           = EXCLUDED.metadata_source,
    metadata_snapshot_at      = EXCLUDED.metadata_snapshot_at
RETURNING *;

-- name: GetUserModel :one
SELECT * FROM user_models
WHERE user_model_provider_id = $1 AND model_id = $2;

-- name: ListUserModelsByProvider :many
SELECT * FROM user_models
WHERE user_model_provider_id = $1
ORDER BY model_id;

-- name: ListUserModelsByUser :many
SELECT um.*
FROM user_models um
JOIN user_model_providers ump ON ump.id = um.user_model_provider_id
WHERE ump.user_id = $1
ORDER BY ump.created_at, um.model_id;

-- name: DeleteUserModel :exec
DELETE FROM user_models
WHERE user_model_provider_id = $1 AND model_id = $2;

-- name: SetUserModelFavorite :exec
UPDATE user_models
SET favorite = $3
WHERE user_model_provider_id = $1 AND model_id = $2;

-- name: UpdateUserModelDefaultSettings :exec
-- Replaces (not merges) the per-model default_settings JSONB blob. NULL
-- clears it. metadata_snapshot_at is bumped so consumers polling for row
-- changes notice the update — the row's metadata identity hasn't changed,
-- but its effective behavior has.
UPDATE user_models
SET default_settings = $3, metadata_snapshot_at = NOW()
WHERE user_model_provider_id = $1 AND model_id = $2;
