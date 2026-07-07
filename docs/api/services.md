# Service reference

Per-service RPC reference. Read [overview.md](overview.md) first for the conventions that hold everywhere (auth, error codes, sparse updates, the request/response pairing). Every RPC below is `Name(NameRequest) → NameResponse` even where the response is empty; the tables omit the boilerplate and call out the notable fields. All RPCs require a bearer session except `AuthService.Login` and `AuthService.Probe`.

## AuthService

Sessions, self-service password management, and admin user management. `proto/psmith/v1/auth.proto`.

| RPC | Notes |
|---|---|
| `Probe` | Unauthenticated. Server availability and version ping. Use before login. |
| `Login` | Unauthenticated. Username + password (+ optional client label) → session token and expiry. The token is returned once; store it. |
| `Logout` | Revoke the current session. |
| `WhoAmI` | The authenticated user. |
| `ChangePassword` | Self-service: old password + new password. |
| `CreateUser` | Admin. Create a user (username, password, admin flag). |
| `ListUsers` | Admin. All users. |
| `GetUser` | Admin. One user. |
| `UpdateUser` | Admin. Sparse (display name, admin flag) with `clear_fields`. |
| `DeleteUser` | Admin. |
| `AdminResetPassword` | Admin. Reset another user's password. |

`LoginResponse` carries the session token, its expiry, and the `User`. The token never appears again, so a client that loses it must log in afresh. See [auth-and-users.md](../design/auth-and-users.md).

## ConversationsService

The chat core: conversation and context lifecycle, the message tree, sending and editing, branching, compaction, and per-conversation plugin overrides. `proto/psmith/v1/conversations.proto`.

Conversations:

| RPC | Notes |
|---|---|
| `CreateConversation` | Profile id (+ optional title, settings). Returns the conversation, its initial context, and seed messages (system, optional default user). |
| `ListConversations` | Keyset-paginated (`page_size` capped at 100, opaque `page_token`, `next_page_token` on the response). Optional `order` (recently used / recently created), `title_query` substring, `profile_id` filter — filters and cursor compose. |
| `GetConversation` | The conversation and its active context. |
| `UpdateConversation` | Sparse: title, settings. |
| `DeleteConversation` | Delete. |

Contexts:

| RPC | Notes |
|---|---|
| `ListContexts` | All contexts in a conversation (live and retired). |
| `ActivateContext` | Set a context's activation time to now, making it active (fork reactivation). |
| `SetCurrentLeaf` | Move a context's viewing cursor to a specific message (branch navigation). |
| `UpdateContext` | Sparse: title. |
| `CreateContextManual` | A fresh context without compaction; mode (REPLACE / APPEND) selects framing, seeds an initial user message. |
| `PromoteCompactionToNewContext` | Second half of compaction: promote a `compression_summary` message into a new active context seeded with a `context`-role message. See [compression.md](../design/compression.md). |

Messages:

| RPC | Notes |
|---|---|
| `ListMessages` | Context id; optional `leaf_message_id` pin and `full_tree` flag. Default returns the active leaf chain. |
| `GetMessage` | One message. |
| `EditMessage` | Mutate content and optionally role (user ↔ assistant only). Rejected with an in-flight run. |
| `DeleteMessage` | `cascade` flag: false reparents children, true removes the subtree. |

Sending and compaction (asynchronous; return a stream run to subscribe to):

| RPC | Notes |
|---|---|
| `SendMessage` | Conversation id, content, optional `parent_message_id`, per-turn `provider_id`/`model_id`/`CallSettings`, `regenerate` flag, `attachment_file_ids`, `device_facts`. Returns the persisted user message and the `StreamRun`. |
| `Compact` | Trigger compression on the active context. Returns a `StreamRun`. Profile (or per-call override) must supply the compression provider, model, and guide. |
| `CountContextTokens` | Token count for the active context as it would be sent to a target model (`provider_id`, `model_id` required). |

Per-conversation plugins:

| RPC | Notes |
|---|---|
| `GetConversationPlugins` | The literal conversation-level override rows only. |
| `SetConversationPlugins` | Atomically replace the conversation overrides. A `disabled` entry subtracts an inherited plugin. |
| `ResolveConversationPipeline` | The merged view: profile chain + conversation overrides, each entry tagged with its source (profile / conversation). |

`SendMessageResponse` returns both the `user_message` and the `stream_run`; the assistant reply arrives over `StreamsService.SubscribeStream`, not in this response. See [streaming.md](../design/streaming.md) and [data-model.md](../design/data-model.md).

## StreamsService

Subscribe to and control streaming runs. `proto/psmith/v1/streams.proto`.

| RPC | Notes |
|---|---|
| `SubscribeStream` | Server-streaming. `stream_run_id` + `from_sequence`. Replays persisted chunks from the sequence, live-tails new ones, emits a terminal `StreamRun`, closes. Each response is a oneof of `Chunk` or terminal `StreamRun`. |
| `CancelStream` | Cancel an in-flight run. Idempotent and safe on an already-terminal run. |
| `GetStreamRun` | Snapshot of one run. |
| `ListActiveRuns` | The user's currently-running runs; optional conversation filter. Lets a fresh client reattach to runs started elsewhere. |

`Chunk` is `sequence` (int64, monotonic per run), `type` (the `ChunkType` enum), and a `payload` byte blob whose shape depends on the type. `StreamRun` carries the ids, the status and purpose enums, timing, an error payload on failure, the result message and context ids, and cache-observability fields (prefix length, cache-stable prefix length, cache trailing depth) used to diagnose prompt-cache behavior. The full vocabulary and the reconnection contract are in [client-spec.md](../clients/client-spec.md).

## FilesService

Content-addressed file upload and retrieval. `proto/psmith/v1/files.proto`.

| RPC | Notes |
|---|---|
| `UploadFile` | Client-streaming. A header (`mime_type`, `size_bytes`, optional `original_filename`) then byte chunks. 50 MB cap. Dedupes on (user, sha256). Returns file id, hash, MIME, size, filename, created-at. |
| `GetFileURL` | Mint a short-lived signed URL for `/files/{id}?token=...`, usable by an unauthenticated image loader. |
| `ListFiles` | The caller's recent files (metadata only, no bytes); optional limit. |

The download itself is a plain HTTP endpoint, not an RPC; see [non-rpc-endpoints.md](non-rpc-endpoints.md). The storage and signing mechanics are in [encryption.md](../design/encryption.md).

## ProfilesService

Profiles and their plugin pipelines. `proto/psmith/v1/profiles.proto`.

Profiles:

| RPC | Notes |
|---|---|
| `CreateProfile` | Optional `parent_profile_id` for inheritance; name, system message, default user message, compression and title config, `title_provider_kind` (sentinel for a client-side titler like `apple_foundation`), `welcome_message`, defaults. |
| `ListProfiles` | The caller's profiles. `page_size = 0` (the default) returns everything — clients that treat the list as a lookup table rely on that; `page_size > 0` opts into keyset paging (`page_token` / `next_page_token`, capped at 100 per page). |
| `GetProfile` | One profile; with `resolve` it also returns the parent-chain-resolved view. |
| `UpdateProfile` | Sparse with `clear_fields` (clearing reverts a field to inherited); `parent_profile_id` re-parents. |
| `DeleteProfile` | Delete. |

Plugins:

| RPC | Notes |
|---|---|
| `ListPluginTypes` | All registered plugin types: name, display, description, config fields, capabilities, requested device facts, required model capabilities. |
| `GetProfilePlugins` | The rows attached to this profile only (empty = inherit all). |
| `SetProfilePlugins` | Atomically replace the pipeline; order is execution order; config is validated. |
| `GetUserPluginSettings` / `ListUserPluginSettings` | A user's global (cross-profile) config for a plugin / all of them. |
| `UpsertUserPluginSettings` | Insert-or-update a user's global config for one plugin. |

`PluginType` exposes `config_fields` (each with a type: number, text, textarea, boolean, select, model-picker; plus required, global, merge mode, and category) and a `capabilities` struct mirroring the plugin interface set. This is what lets a client render a plugin config form generically. See [plugins.md](../design/plugins.md).

## ModelProvidersService

Provider instances, model discovery and enablement, testing, and cost. `proto/psmith/v1/model_providers.proto`.

Types and templates:

| RPC | Notes |
|---|---|
| `ListProviderTypes` | The driver types compiled into the server (anthropic, openai-compatible, google), with config schemas. |
| `ListProviderTemplates` | A curated catalog of provider presets to accelerate "add a provider." |

Provider CRUD:

| RPC | Notes |
|---|---|
| `CreateUserModelProvider` | Encrypts and stores credentials. |
| `ListUserModelProviders` / `GetUserModelProvider` | List / one (the latter with enabled models). |
| `UpdateUserModelProvider` | Sparse: label, config, default settings. |
| `DeleteUserModelProvider` | Delete (does not touch historical messages). |

Models:

| RPC | Notes |
|---|---|
| `DiscoverModels` | Ask the driver what the provider offers. Returns discovered models (not persisted) with metadata and an `already_enabled` flag. |
| `EnableModels` / `DisableModels` | Snapshot metadata into `user_models` rows / drop them. |
| `ListUserModels` / `ListAllUserModels` | Enabled models on one provider / flat across all providers (drives the picker). |
| `ToggleUserModelFavorite` | Favorite flag for the picker's favorites section. |
| `UpdateUserModel` | Default settings + metadata, with explicit clear flags for nullable fields. |
| `AddManualModel` | Describe a model by hand (not from catalog or discovery). |

Testing and cost:

| RPC | Notes |
|---|---|
| `TestUserModelProvider` | Verify auth and reachability; returns ok, error, model count, latency. |
| `TestUserModel` | Send a tiny test prompt; returns ok, latency, token counts, sample text; optional settings override for constraint discovery. |
| `ListProviderCosts` | Per-provider cost rollup from the ledger; optional since/until window; returns per-provider totals and a grand total. See [titles-cost-observability.md](../design/titles-cost-observability.md). |
| `RefreshModelCatalog` / `GetCatalogStatus` | Refresh the in-memory model-metadata catalog from models.dev / report its status (provider and model counts, last refresh). The catalog is the lazy in-memory `LiveCatalog`, not database tables; refresh re-fetches, status reports the in-memory snapshot. |

An enabled `UserModel` carries a pricing snapshot, capabilities, modalities, a metadata source (catalog / driver / manual), and optional `ModelConstraints` (a temperature range or locked value, plus a list of unsupported settings paths). The constraints are how a client knows to render a locked or hidden setting. See [providers.md](../design/providers.md).

`CallSettings` (in `types.proto`) is the shared settings shape: common knobs (temperature, top-p, max output tokens, stop sequences), top-k for Anthropic and Google, a universal `thinking` block, per-provider extras (`AnthropicExtras` with cache control, `OpenAIExtras` with seed / penalties / response format / service tier, `GoogleExtras` with safety settings), and an explicit-cache toggle.

## EmbedderService

Per-user embedder config for semantic search. `proto/psmith/v1/embedder.proto`.

| RPC | Notes |
|---|---|
| `GetEmbedderConfig` | Never `NotFound`; returns a disabled zero-value when absent. The API key is never returned (only `api_key_set`). |
| `UpdateEmbedderConfig` | Sparse upsert. API key semantics: unset = unchanged, empty = clear, value = encrypt and replace. |
| `DeleteEmbedderConfig` | Remove the config row. |
| `TestEmbedderConfig` | Fire one synthetic embed; returns ok, error, latency. |
| `ListEmbedderTypes` | The registered embedder drivers. |
| `GetEmbedderStats` | The unembedded-message count and whether the worker is active (drives the progress chip). |

See [embeddings-and-search.md](../design/embeddings-and-search.md).

## LangfuseService

Per-user Langfuse tracing config. `proto/psmith/v1/langfuse.proto`.

| RPC | Notes |
|---|---|
| `GetLangfuseConfig` | Never `NotFound`; disabled zero-value when absent. Secret never returned (only `secret_key_set`). |
| `UpdateLangfuseConfig` | Sparse upsert. Secret semantics: unset = unchanged, empty = clear, value = encrypt and replace. Enabling requires both keys. |
| `DeleteLangfuseConfig` | Remove the config row. |
| `TestLangfuseConfig` | Fire a synthetic trace; returns ok, error, latency. |

See [titles-cost-observability.md](../design/titles-cost-observability.md).

## DeviceToolsService

Device-tool capability registration, catalog, and audit log. The dispatch itself rides the stream and the respond endpoint, not an RPC. `proto/psmith/v1/device_tools.proto`.

| RPC | Notes |
|---|---|
| `RegisterCapabilities` | The client advertises the tool names it supports plus an attributes map (os, os version, app version, device model). |
| `ListSupportedTools` | The server's catalog: name, display, description, input schema, category, required permissions. |
| `ListDeviceToolCalls` | The caller's recent device-tool invocations (audit log). Paginated recent-first; optional conversation filter, before-timestamp, limit. Each call carries the tool name, input, output, status (ok / error / timeout), error message, and timestamps. |

The full dispatch flow (a `DEVICE_TOOL_USE` chunk, run on device, POST to the respond endpoint) is in [tools.md](../design/tools.md) and [non-rpc-endpoints.md](non-rpc-endpoints.md).

## EventsService

Account-scoped server push. `proto/psmith/v1/events.proto`.

| RPC | Notes |
|---|---|
| `SubscribeAccountEvents` | Server-streaming. Pushes `AccountEvent`s as they fire. No replay; a reconnect starts fresh. Today the only variant is `ProfileChanged` (profile id + kind: created / updated / deleted); the oneof leaves room for more. |

Treat it as a refresh hint, not a source of truth; the recovery for a missed event is the same re-fetch used everywhere. See [auth-and-users.md](../design/auth-and-users.md) for the bus design.
