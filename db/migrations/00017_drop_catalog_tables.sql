-- +goose Up
-- Drop the models.dev catalog cache tables. The runtime now uses
-- LiveCatalog (in-memory, lazy fetch) — no DB cache needed. See
-- internal/modelmeta/live.go.
--
-- catalog_models references catalog_model_providers via FK, so order
-- matters even with CASCADE — drop the dependent first.

DROP TABLE IF EXISTS catalog_models;
DROP TABLE IF EXISTS catalog_model_providers;

-- +goose Down
-- Recreate the original 00001_initial.sql shape so a downgrade restores
-- a valid (empty) catalog. The DBCatalog code that populated these is
-- gone, so a downgraded reeved would still need to rehydrate from
-- models.dev — there's no path back to the prior cached state.

CREATE TABLE catalog_model_providers (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    api_base   TEXT,
    env_key    TEXT,
    doc_url    TEXT,
    npm        TEXT,
    raw        JSONB NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE catalog_models (
    provider_id              TEXT NOT NULL REFERENCES catalog_model_providers(id) ON DELETE CASCADE,
    model_id                 TEXT NOT NULL,
    display_name             TEXT NOT NULL,
    context_window           INTEGER,
    max_output_tokens        INTEGER,
    input_price_per_million  DOUBLE PRECISION,
    output_price_per_million DOUBLE PRECISION,
    cache_read_per_million   DOUBLE PRECISION,
    cache_write_per_million  DOUBLE PRECISION,
    knowledge_cutoff         DATE,
    modalities               TEXT[],
    capabilities             JSONB,
    raw                      JSONB NOT NULL,
    fetched_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider_id, model_id)
);

CREATE INDEX catalog_models_id ON catalog_models (model_id);
