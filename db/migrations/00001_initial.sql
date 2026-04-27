-- +goose Up

-- Users & sessions --------------------------------------------------------

CREATE TABLE users (
    id             UUID PRIMARY KEY,
    username       TEXT NOT NULL UNIQUE,
    display_name   TEXT,
    password_hash  TEXT NOT NULL,
    is_admin       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sessions (
    token_hash    TEXT PRIMARY KEY,
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_label  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at    TIMESTAMPTZ NOT NULL
);

CREATE INDEX sessions_user ON sessions (user_id);
CREATE INDEX sessions_expiry ON sessions (expires_at);

-- Model catalog (refreshed periodically from models.dev) -------------------

CREATE TABLE catalog_model_providers (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    api_base    TEXT,
    env_key     TEXT,
    doc_url     TEXT,
    npm         TEXT,
    raw         JSONB NOT NULL,
    fetched_at  TIMESTAMPTZ NOT NULL
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
    fetched_at               TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (provider_id, model_id)
);

CREATE INDEX catalog_models_id ON catalog_models (model_id);

-- User-configured providers (instances of a driver type) ------------------

CREATE TABLE user_model_providers (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    label       TEXT NOT NULL,
    config      JSONB NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, type, label)
);

CREATE INDEX user_model_providers_user ON user_model_providers (user_id);

-- User-enabled models (snapshotted from catalog or driver discovery) ------

CREATE TABLE user_models (
    user_model_provider_id    UUID NOT NULL REFERENCES user_model_providers(id) ON DELETE CASCADE,
    model_id                  TEXT NOT NULL,

    -- Snapshot at enable time. User-editable afterward.
    display_name              TEXT NOT NULL,
    context_window            INTEGER,
    max_output_tokens         INTEGER,
    input_price_per_million   DOUBLE PRECISION,
    output_price_per_million  DOUBLE PRECISION,
    cache_read_per_million    DOUBLE PRECISION,
    cache_write_per_million   DOUBLE PRECISION,
    knowledge_cutoff          DATE,
    modalities                TEXT[],
    capabilities              JSONB,
    default_settings          JSONB,

    -- Provenance.
    metadata_source           TEXT NOT NULL CHECK (metadata_source IN ('catalog','driver','manual')),
    metadata_snapshot_at      TIMESTAMPTZ NOT NULL,
    enabled_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_model_provider_id, model_id)
);

-- Profiles ----------------------------------------------------------------

CREATE TABLE profiles (
    id                       UUID PRIMARY KEY,
    user_id                  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    parent_profile_id        UUID REFERENCES profiles(id),
    name                     TEXT NOT NULL,
    system_message           TEXT,
    default_user_message     TEXT,
    compression_guide        TEXT,
    compression_mode         TEXT CHECK (compression_mode IN ('REPLACE', 'APPEND')),
    compression_provider_id  UUID REFERENCES user_model_providers(id),
    compression_model_id     TEXT,
    default_settings         JSONB,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX profiles_user ON profiles (user_id);

-- Conversations / Contexts / Messages -------------------------------------

CREATE TABLE conversations (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    profile_id  UUID NOT NULL REFERENCES profiles(id),
    title       TEXT,
    settings    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX conversations_user ON conversations (user_id);

CREATE TABLE contexts (
    id                       UUID PRIMARY KEY,
    conversation_id          UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    parent_context_id        UUID REFERENCES contexts(id),
    context_activation_time  TIMESTAMPTZ NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX contexts_active ON contexts (conversation_id, context_activation_time DESC);

CREATE TABLE messages (
    id                      UUID PRIMARY KEY,
    context_id              UUID NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    parent_id               UUID REFERENCES messages(id),
    role                    TEXT NOT NULL CHECK (role IN ('system', 'context', 'user', 'assistant')),
    content                 TEXT NOT NULL,
    raw_content             TEXT,
    thinking                JSONB,
    thinking_provider_type  TEXT,
    thinking_rendered_text  TEXT,
    provider_id             UUID REFERENCES user_model_providers(id),
    model_id                TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX messages_context_parent ON messages (context_id, parent_id);

-- Streaming ---------------------------------------------------------------

CREATE TABLE stream_runs (
    id                 UUID PRIMARY KEY,
    conversation_id    UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    context_id         UUID NOT NULL REFERENCES contexts(id),
    parent_message_id  UUID REFERENCES messages(id),
    provider_id        UUID NOT NULL REFERENCES user_model_providers(id),
    model_id           TEXT NOT NULL,
    status             TEXT NOT NULL CHECK (status IN ('running','completed','errored','cancelled','interrupted')),
    purpose            TEXT NOT NULL CHECK (purpose IN ('assistant_response','compression')),
    started_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at           TIMESTAMPTZ,
    error_payload      JSONB,
    result_message_id  UUID REFERENCES messages(id),
    result_context_id  UUID REFERENCES contexts(id)
);

CREATE INDEX stream_runs_active ON stream_runs (status) WHERE status = 'running';
CREATE INDEX stream_runs_conversation ON stream_runs (conversation_id);

CREATE TABLE stream_chunks (
    stream_run_id  UUID NOT NULL REFERENCES stream_runs(id) ON DELETE CASCADE,
    sequence       BIGINT NOT NULL,
    chunk_type     TEXT NOT NULL,
    payload        JSONB NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (stream_run_id, sequence)
);

-- Harness sessions (stateful providers) -----------------------------------

CREATE TABLE harness_sessions (
    id                   UUID PRIMARY KEY,
    conversation_id      UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    provider_id          UUID NOT NULL REFERENCES user_model_providers(id),
    external_session_id  TEXT NOT NULL,
    state                JSONB,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at         TIMESTAMPTZ
);

-- +goose Down

DROP TABLE IF EXISTS harness_sessions;
DROP TABLE IF EXISTS stream_chunks;
DROP TABLE IF EXISTS stream_runs;
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS contexts;
DROP TABLE IF EXISTS conversations;
DROP TABLE IF EXISTS profiles;
DROP TABLE IF EXISTS user_models;
DROP TABLE IF EXISTS user_model_providers;
DROP TABLE IF EXISTS catalog_models;
DROP TABLE IF EXISTS catalog_model_providers;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS users;
