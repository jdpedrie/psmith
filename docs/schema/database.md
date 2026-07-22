# Database schema

The full current Postgres schema, the migration history that produced it, and the special features that matter. The source of truth is `db/migrations/`, a sequence of goose migrations numbered 00001 through 00044. This document reflects the state after all of them.

Conventions across the schema: UUIDs for IDs (UUIDv7 where the application mints them, for sortability). Enumerations are `TEXT` with a `CHECK` constraint, never native Postgres `ENUM`, to keep schema evolution painless. `updated_at` is maintained by application code, not a trigger; there are no triggers anywhere.

## How migrations run

Production applies the migrations embedded in the `psmith` binary: `psmith install` runs `CREATE EXTENSION IF NOT EXISTS vector` as a preflight, then goose up. The dev loop uses the external `goose` CLI through `make migrate-up` and `make migrate-down`. Tests clone a fresh database per test from `template1` via `pgtestdb`. See [../operations/installation.md](../operations/installation.md).

`sqlc` generates the `internal/store` query layer from `db/queries` against this schema. goose keeps its own version-bookkeeping table that no migration here defines.

## Extensions

pgvector is the only required extension, used by `messages.embedding`. It is not installed by any migration because the extension is untrusted and a non-superuser cannot self-install it. It is installed out of band: by the `psmith install` preflight for real databases, and into `template1` for the test harness.

## Migration history

| # | File | What it does |
|---|---|---|
| 00001 | initial | Core schema: `users`, `sessions`, `catalog_model_providers`, `catalog_models`, `user_model_providers`, `user_models`, `profiles`, `conversations`, `contexts`, `messages`, `stream_runs`, `stream_chunks`, `harness_sessions`. |
| 00002 | usage_cost_compression_marker | Token-usage and cost columns on `messages` (NUMERIC(12,6)); `provider_usage_raw` JSONB; adds `compression_summary` to the `messages.role` CHECK. |
| 00003 | context_current_leaf | `contexts.current_leaf_message_id` (FK to messages, ON DELETE SET NULL). |
| 00004 | profile_plugins | `profile_plugins` (ordered per-profile plugin pipeline) plus a name index. |
| 00005 | stream_run_cache_observability | `prefix_hashes`, `prefix_length`, `cache_stable_prefix_length`, `cache_trailing_depth` on `stream_runs`; partial index for rows with prefix hashes. |
| 00006 | edit_delete_compaction_reshape | `messages.parent_id` FK to ON DELETE CASCADE; `stream_runs.parent_message_id` and `result_message_id` to ON DELETE SET NULL; adds `messages.edited_at`. |
| 00007 | auto_titles | `profiles.title_provider_id` (FK), `title_model_id`, `title_guide`; `contexts.title`. |
| 00008 | profile_description_parent_only | `profiles.description` (NOT NULL default empty), `profiles.parent_only` (NOT NULL default false). |
| 00009 | profile_favorite | `profiles.favorite` (NOT NULL default false). |
| 00010 | user_model_favorite | `user_models.favorite` (NOT NULL default false). |
| 00011 | backfill_user_model_metadata | Data-only backfill of OpenRouter `catalog_provider_id` and catalog metadata onto `user_models`. No schema change. |
| 00012 | message_error_payload | `messages.error_payload` JSONB. |
| 00013 | profile_title_provider_kind | `profiles.title_provider_kind` (sentinel for non-server titlers, e.g. `apple_foundation`). |
| 00014 | user_model_provider_default_settings | `user_model_providers.default_settings` JSONB (bottom layer of the call-settings chain). |
| 00015 | user_model_provider_delete_cascades | All FKs pointing at `user_model_providers(id)` become ON DELETE SET NULL; relaxes `stream_runs.provider_id` and `harness_sessions.provider_id` to nullable. |
| 00016 | message_thinking_duration | `messages.thinking_duration_ms`. |
| 00017 | drop_catalog_tables | Drops `catalog_models` and `catalog_model_providers`; the runtime catalog moved in-memory. |
| 00018 | gemini_explicit_cache | `gemini_caches` table (superseded by 00020). |
| 00019 | message_explicit_cache_attached | `messages.explicit_cache_attached`. |
| 00020 | rename_gemini_to_explicit_cache | Replaces `gemini_caches` with the provider-agnostic `explicit_caches` (adds `provider_type`, renames `cache_name` to `cache_ref`); backfills and drops `gemini_caches`. |
| 00021 | message_tool_calls | `messages.tool_calls` JSONB. |
| 00022 | user_plugin_settings | `user_plugin_settings` (per-user, per-plugin global config) plus a user index. |
| 00023 | encrypted_secret_columns | `config_encrypted` BYTEA on `user_model_providers`, `user_plugin_settings`, `profile_plugins`; relaxes `config` to nullable on the first two. |
| 00024 | message_finish_reason | `messages.finish_reason`. |
| 00025 | cost_events | `cost_events` append-only ledger plus a provider/time index. |
| 00026 | files_and_attachments | `files` (unique on user plus sha256) and `message_attachments`. |
| 00027 | messages_tool_cost_usd | `messages.tool_cost_usd` NUMERIC(12,6). |
| 00028 | user_langfuse_config | `user_langfuse_config` (per-user singleton, encrypted secret key). |
| 00029 | users_system_profiles_seeded | `users.system_profiles_seeded`. |
| 00030 | profiles_welcome_message | `profiles.welcome_message`. |
| 00031 | messages_is_welcome | `messages.is_welcome`. |
| 00032 | backfill_untitled_conversations_and_contexts | Data-only title backfill. No schema change. |
| 00033 | conversation_plugins_and_disabled | `profile_plugins.disabled`; new `conversation_plugins` table plus a name index. |
| 00034 | message_embeddings | `messages.embedding` `vector(768)`, `embedding_model`, `embedding_at`; the triple-NULL CHECK; an HNSW partial index and an unembedded partial index. Requires pgvector. |
| 00035 | user_embedder_config | `user_embedder_config` (per-user singleton, encrypted api key). |
| 00036 | device_tool_calls | `device_tool_calls` audit log plus two indexes. |
| 00037 | profile_default | `profiles.is_default` plus a partial unique index (one default per user). |
| 00038 | conversation_archive | `conversations.archived_at` (NULL = active; timestamps the archive action). |
| 00039 | conversation_pin | `conversations.pinned_at` (NULL = unpinned; ordering key for pinned rows). |
| 00040 | user_tts_config | `user_tts_config` (per-user speech settings: synthesizer choice, voice, credential reuse). |
| 00041 | message_headers_trailers | `messages.message_headers` / `message_trailers` — plugin envelope contributions beside the user's own content. |
| 00042 | messages_context_created_index | `messages (context_id, created_at DESC, id DESC)` index for chain walks and tail probes. |
| 00043 | user_mcp_servers | `user_mcp_servers` (user-level MCP server registry, encrypted specs) plus a user index and per-user name uniqueness. |
| 00044 | messages_parent_index | `messages (parent_id)` index for the stitch-delete reparent (2026-07-21 perf round). |

Tables that no longer exist: `catalog_model_providers` and `catalog_models` (dropped in 00017), `gemini_caches` (dropped in 00020).

## Tables

### Identity

**users** — `id` PK; `username` unique; `display_name` nullable; `password_hash`; `is_admin` (default false); `created_at`, `updated_at`; `system_profiles_seeded` (default false). No outbound FKs.

**sessions** — `token_hash` PK (sha256 of the bearer token); `user_id` FK to users ON DELETE CASCADE; `client_label` nullable; `created_at`, `last_used_at`, `expires_at`. Indexes on `user_id` and `expires_at`.

### Providers and models

**user_model_providers** — `id` PK; `user_id` FK ON DELETE CASCADE; `type` (driver name); `label`; `config` JSONB nullable; `default_settings` JSONB nullable; `config_encrypted` BYTEA nullable; timestamps. Unique on `(user_id, type, label)`. Index on `user_id`. The plaintext `config` was relaxed to nullable when `config_encrypted` arrived; encrypted deployments store the blob in `config_encrypted`.

**user_models** — composite PK `(user_model_provider_id, model_id)`; FK to the provider ON DELETE CASCADE; `display_name`; `context_window`, `max_output_tokens` nullable; four pricing columns (`input_price_per_million`, `output_price_per_million`, `cache_read_per_million`, `cache_write_per_million`); `knowledge_cutoff` DATE; `modalities` TEXT[]; `capabilities` JSONB; `default_settings` JSONB; `metadata_source` CHECK in (`catalog`, `driver`, `manual`); `metadata_snapshot_at`; `enabled_at`; `favorite`. This row is the user-owned metadata snapshot. It is deliberately not foreign-keyed to any catalog table.

### Profiles

**profiles** — `id` PK; `user_id` FK ON DELETE CASCADE; `parent_profile_id` self-FK (NO ACTION); `name`; `system_message`, `default_user_message`, `compression_guide` nullable; `compression_mode` CHECK in (`REPLACE`, `APPEND`); `compression_provider_id` FK to providers ON DELETE SET NULL; `compression_model_id`; `default_settings` JSONB; `title_provider_id` FK to providers ON DELETE SET NULL; `title_model_id`, `title_guide`, `title_provider_kind` nullable; `description` (NOT NULL default empty); `parent_only`, `favorite` (default false); `welcome_message` nullable; timestamps. Index on `user_id`.

### Conversations, contexts, messages

**conversations** — `id` PK; `user_id` FK ON DELETE CASCADE; `profile_id` FK (NO ACTION); `title` nullable; `settings` JSONB nullable; timestamps. Index on `user_id`.

**contexts** — `id` PK; `conversation_id` FK ON DELETE CASCADE; `parent_context_id` self-FK (NO ACTION, the context this was compressed from); `context_activation_time` (newest wins for "active"); `created_at`; `current_leaf_message_id` FK to messages ON DELETE SET NULL; `title` nullable. Index on `(conversation_id, context_activation_time DESC)`.

**messages** — the widest table. `id` PK; `context_id` FK ON DELETE CASCADE; `parent_id` self-FK ON DELETE CASCADE (the message tree); `role` CHECK in (`system`, `context`, `user`, `assistant`, `compression_summary`); `content` NOT NULL; `raw_content` nullable (the pre-plugin form, set only when a transform changed the content); `thinking` JSONB nullable (raw per-provider shape); `thinking_provider_type`, `thinking_rendered_text` nullable; `provider_id` FK to providers ON DELETE SET NULL; `model_id` nullable; `created_at`. Usage and cost: `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens`, `provider_usage_raw` JSONB, and the matching `*_cost_usd` NUMERIC(12,6) columns plus `total_cost_usd`. Lifecycle and features: `edited_at`, `error_payload` JSONB, `thinking_duration_ms`, `explicit_cache_attached`, `tool_calls` JSONB, `finish_reason`, `tool_cost_usd`, `is_welcome` (default false). Embeddings: `embedding` `vector(768)`, `embedding_model`, `embedding_at`, all nullable and governed by a triple-NULL CHECK (all three NULL together or all three set together). Indexes: `(context_id, parent_id)`; an HNSW index on `embedding` with `vector_cosine_ops` partial on `embedding IS NOT NULL`; and an unembedded index on `created_at` partial on `embedding IS NULL`.

### Streaming

**stream_runs** — `id` PK; `conversation_id` FK ON DELETE CASCADE; `context_id` FK (NO ACTION); `parent_message_id` FK ON DELETE SET NULL; `provider_id` FK ON DELETE SET NULL (nullable); `model_id`; `status` CHECK in (`running`, `completed`, `errored`, `cancelled`, `interrupted`); `purpose` CHECK in (`assistant_response`, `compression`); `started_at`, `ended_at`; `error_payload` JSONB; `result_message_id` FK ON DELETE SET NULL; `result_context_id` FK (the new context a compression produced); the four cache-observability columns from 00005. Indexes: partial on `status = 'running'`; on `conversation_id`; and a partial on `(context_id, started_at DESC)` for rows carrying prefix hashes.

**stream_chunks** — composite PK `(stream_run_id, sequence)`; FK to the run ON DELETE CASCADE; `chunk_type`; `payload` JSONB; `created_at`. Transient: pruned after the run finalizes plus a safety window.

**harness_sessions** — `id` PK; `conversation_id` FK ON DELETE CASCADE; `provider_id` FK ON DELETE SET NULL (nullable); `external_session_id` (the harness's own id); `state` JSONB; `created_at`, `last_used_at`. Present for the stateful-provider design; no driver populates it yet.

### Plugins

**profile_plugins** — composite PK `(profile_id, ordinal)`; FK to profiles ON DELETE CASCADE; `plugin_name`; `config` JSONB nullable; `config_encrypted` BYTEA nullable; `disabled` (default false); timestamps. Index on `plugin_name`. The ordered pipeline attached to a profile.

**conversation_plugins** — composite PK `(conversation_id, ordinal)`; FK to conversations ON DELETE CASCADE; same `plugin_name`, `config`, `config_encrypted`, `disabled`, timestamps. Index on `plugin_name`. The per-conversation override layer.

**user_plugin_settings** — composite PK `(user_id, plugin_name)`; FK to users ON DELETE CASCADE; `config` JSONB nullable; `config_encrypted` BYTEA nullable; timestamps. Index on `user_id`. Per-user plugin globals, for example a shared API key a plugin needs.

### Caching, cost, files, integrations

**explicit_caches** — composite PK `(context_id, provider_type, model_id)`; FK to contexts ON DELETE CASCADE; `cache_ref` (the provider's cache handle); `prefix_message_count`; `prefix_hash`; `created_at`, `expires_at`. Index on `expires_at`. Tracks server-managed explicit caches (Google `cachedContents`, Anthropic 1-hour TTL).

**cost_events** — `id` BIGSERIAL PK; `provider_id` FK ON DELETE CASCADE; `model_id`; `amount_usd` NUMERIC(20,10); `message_id` FK ON DELETE SET NULL; `occurred_at`. Index on `(provider_id, occurred_at DESC)`. The append-only spend ledger that `ListProviderCosts` aggregates.

**files** — `id` PK; `user_id` FK ON DELETE CASCADE; `sha256`; `mime_type`; `size_bytes` BIGINT; `original_filename` nullable; `created_at`. Unique on `(user_id, sha256)` (content-addressed dedup). Index on `(user_id, created_at DESC)`.

**message_attachments** — composite PK `(message_id, ordinal)`; FK to messages ON DELETE CASCADE; `file_id` FK to files ON DELETE CASCADE; `kind` CHECK in (`image`, `audio`, `document`, `video`); `role_hint` CHECK in (`user_supplied`, `tool_result`, `model_generated`, `compressed_reference`). Index on `file_id`.

**user_langfuse_config** — `user_id` PK (one row per user); FK ON DELETE CASCADE; `host` (default the Langfuse US cloud host); `public_key` (default empty); `secret_key_encrypted` BYTEA nullable; `enabled` (default false); timestamps.

**user_embedder_config** — `user_id` PK (one row per user); FK ON DELETE CASCADE; `type`; `config` JSONB (default empty object); `api_key_encrypted` BYTEA nullable; `enabled` (default true); timestamps.

**user_mcp_servers** — `id` PK; `user_id` FK ON DELETE CASCADE; `name` (UNIQUE per user via `(user_id, name)`); `config` JSONB nullable (legacy plaintext fallback); `config_encrypted` BYTEA nullable; timestamps. Index on `user_id`. One row per registered MCP server; the spec JSON matches the mcp plugin's config blob shape so pipeline resolution merges it directly. Referenced from pipeline rows by `plugin_name = 'mcp:<id>'`; deleting a row leaves references dangling by design (they degrade to a no-op at build time).

**device_tool_calls** — `id` PK; `user_id` FK ON DELETE CASCADE; `conversation_id` FK ON DELETE CASCADE; `message_id` FK ON DELETE SET NULL; `tool_name`; `input_json`, `output_json` JSONB nullable; `status` CHECK in (`ok`, `error`, `timeout`); `error_message` nullable; `invoked_at`, `completed_at`. Indexes on `(user_id, invoked_at DESC)` and `(conversation_id, invoked_at DESC)`. The audit trail for on-device tool calls.

## Foreign-key posture

Two patterns, applied deliberately.

Ownership edges cascade. Deleting a user removes their sessions, providers, profiles, conversations, plugin settings, and cost events. Deleting a conversation removes its contexts, runs, plugin overrides, and device-tool calls. Deleting a context removes its messages. Deleting a message removes its attachments and its child messages. Deleting a provider removes its enabled models and cost events.

Audit and display edges set null, so the referencing row survives the delete with a dangling link cleared. This covers `messages.provider_id`, `stream_runs.{provider_id, parent_message_id, result_message_id}`, `harness_sessions.provider_id`, `profiles.{compression_provider_id, title_provider_id}`, `contexts.current_leaf_message_id`, `cost_events.message_id`, and `device_tool_calls.message_id`. A historical stream run keeps its row even after the message it produced is deleted.

## Enumerations (TEXT plus CHECK)

- `messages.role`: `system`, `context`, `user`, `assistant`, `compression_summary`.
- `user_models.metadata_source`: `catalog`, `driver`, `manual`.
- `profiles.compression_mode`: `REPLACE`, `APPEND`.
- `stream_runs.status`: `running`, `completed`, `errored`, `cancelled`, `interrupted`.
- `stream_runs.purpose`: `assistant_response`, `compression`.
- `message_attachments.kind`: `image`, `audio`, `document`, `video`.
- `message_attachments.role_hint`: `user_supplied`, `tool_result`, `model_generated`, `compressed_reference`.
- `device_tool_calls.status`: `ok`, `error`, `timeout`.

## Other notable features

- The only auto-increment is `cost_events.id` (BIGSERIAL). Everything else uses application-minted UUIDs.
- `messages.embedding` is the only vector column, fixed at 768 dimensions to match the default embedding model. sqlc maps it to a nullable `*pgvector.Vector`, so an unembedded row reads as `nil`.
- The triple-NULL CHECK on the embedding columns guarantees a row is either fully embedded or fully unembedded, never half-written.
- No native `ENUM` types, no triggers, no stored or virtual generated columns.
