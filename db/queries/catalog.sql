-- Catalog providers --------------------------------------------------------

-- name: UpsertCatalogProvider :exec
INSERT INTO catalog_model_providers (id, name, api_base, env_key, doc_url, npm, raw, fetched_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (id) DO UPDATE SET
    name       = EXCLUDED.name,
    api_base   = EXCLUDED.api_base,
    env_key    = EXCLUDED.env_key,
    doc_url    = EXCLUDED.doc_url,
    npm        = EXCLUDED.npm,
    raw        = EXCLUDED.raw,
    fetched_at = EXCLUDED.fetched_at;

-- name: GetCatalogProvider :one
SELECT * FROM catalog_model_providers WHERE id = $1;

-- name: ListCatalogProviders :many
SELECT * FROM catalog_model_providers ORDER BY id;

-- name: CountCatalogProviders :one
SELECT COUNT(*) FROM catalog_model_providers;

-- Catalog models -----------------------------------------------------------

-- name: UpsertCatalogModel :exec
INSERT INTO catalog_models (
    provider_id, model_id, display_name, context_window, max_output_tokens,
    input_price_per_million, output_price_per_million,
    cache_read_per_million, cache_write_per_million,
    knowledge_cutoff, modalities, capabilities, raw, fetched_at
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
ON CONFLICT (provider_id, model_id) DO UPDATE SET
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
    raw                       = EXCLUDED.raw,
    fetched_at                = EXCLUDED.fetched_at;

-- name: GetCatalogModel :one
SELECT * FROM catalog_models WHERE provider_id = $1 AND model_id = $2;

-- name: ListCatalogModelsByProvider :many
SELECT * FROM catalog_models WHERE provider_id = $1 ORDER BY model_id;

-- name: CountCatalogModels :one
SELECT COUNT(*) FROM catalog_models;

-- name: LatestCatalogFetch :one
SELECT MAX(fetched_at)::TIMESTAMPTZ AS latest FROM catalog_model_providers;
