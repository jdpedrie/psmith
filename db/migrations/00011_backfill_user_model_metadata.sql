-- +goose Up
-- +goose StatementBegin

-- Step 1: backfill catalog_provider_id for existing OpenRouter providers that
-- were created before the provider-template UI added the field. Match by
-- base_url so we don't depend on label spelling. Other openai-compatible
-- providers (LM Studio, Ollama, etc.) intentionally have no catalog hint —
-- their models aren't in the public catalog and metadata is user-managed.
UPDATE user_model_providers
SET config = jsonb_set(config, '{catalog_provider_id}', '"openrouter"')
WHERE type = 'openai-compatible'
  AND config->>'base_url' LIKE '%openrouter.ai%'
  AND (config->>'catalog_provider_id') IS NULL;

-- Step 2: backfill metadata on user_models rows whose enable-time snapshot
-- missed the catalog (driver path with no catalog hint). For each user_model
-- that has a matching catalog_models row — matched via the provider's
-- driver type ("anthropic") or its config catalog_provider_id — copy the
-- per-model metadata across. Skip rows whose user explicitly entered the
-- metadata themselves (`metadata_source = 'manual'`).
UPDATE user_models um
SET context_window          = cm.context_window,
    max_output_tokens        = cm.max_output_tokens,
    input_price_per_million  = cm.input_price_per_million,
    output_price_per_million = cm.output_price_per_million,
    cache_read_per_million   = cm.cache_read_per_million,
    cache_write_per_million  = cm.cache_write_per_million,
    knowledge_cutoff         = cm.knowledge_cutoff,
    modalities               = cm.modalities,
    capabilities             = cm.capabilities,
    metadata_source          = 'catalog',
    metadata_snapshot_at     = cm.fetched_at
FROM catalog_models cm, user_model_providers ump
WHERE ump.id = um.user_model_provider_id
  AND cm.model_id = um.model_id
  AND um.metadata_source <> 'manual'
  AND (
        (ump.type = 'anthropic'         AND cm.provider_id = 'anthropic')
     OR (ump.config->>'catalog_provider_id' IS NOT NULL
         AND cm.provider_id = ump.config->>'catalog_provider_id')
  );

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- This migration is a one-way backfill — there's no meaningful reversal that
-- recovers prior empty/driver state, and rolling back would only erase
-- correct catalog data that subsequent runs would just rewrite. No-op.
SELECT 1;
-- +goose StatementEnd
