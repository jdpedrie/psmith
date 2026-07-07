# Providers

A provider is how Psmith talks to a model backend. There are three layers to keep straight: the **driver** is compiled-in Go code that speaks one backend's wire format; a **provider instance** is a user's configured connection to a backend (a base URL and a credential); and an **enabled model** is a snapshot of one model the user has turned on under an instance. The driver is code, the instance and the model are rows. This document covers all three, the model-metadata catalog, the stateless-versus-stateful split, and the per-driver behavior.

## Drivers

A driver implements the `Provider` interface in `internal/providers/providers.go`: `Type()`, `Stateful()`, `DiscoverModels()`, and `RenderThinkingToText()`. Each driver lives in its own subpackage and registers itself in `init()` under a type string. Three are shipped:

- **anthropic** — Anthropic Messages API.
- **openai-compatible** — any OpenAI-shaped backend (OpenAI itself, Azure, OpenRouter, local servers, and so on), covering both Chat Completions and the Responses API.
- **google** — Google Gemini.

The registry is a compile-time map. `Register(typeName, constructor)` panics on a duplicate so a collision fails at startup, and `Build(typeName, deps, config)` instantiates a driver from a type string, a `Deps` struct (the model-metadata catalog and a logger), and the instance's config JSON. `IsRegistered` lets the settings RPCs validate a type before persisting. Adding a backend means writing a new subpackage and registering it; nothing else in the system needs to know the type string ahead of time.

## Provider instances

A provider instance (`user_model_providers`) is a user's configured connection: a driver type, a label, a base URL, and an encrypted credential blob. The credential is encrypted at rest with the master key (see [encryption.md](encryption.md)) and never leaves the server in a response. A user can have several instances of the same driver type (two OpenAI-compatible endpoints with different keys, say), each with its own label and credential.

Instances are created and tested through the model-providers service. The test RPC builds the driver from the row and makes one cheap call to confirm the credential and base URL work, returning success inline rather than as an error so the UI can show a clear result.

## Enabled models

Discovering a backend's models and enabling one are separate steps. For a provider with a catalog identity (Anthropic and Google implicitly; openai-compatible instances via `catalog_provider_id` in their config), the `DiscoverModels` RPC lists the catalog's models for that provider — curated, metadata-rich, and free of the alias noise a live `/v1/models` can leak. For whitelisted driver types whose live listing is clean (`liveUnionTypes`, currently Anthropic), the service additionally asks the driver for its live list and unions in anything the catalog snapshot hasn't picked up yet: a model released hours ago exists on the provider's API before models.dev catalogs it, and it must still be discoverable. Live-only entries carry driver-source metadata (no pricing or limits) until the catalog catches up, and a live-listing failure just serves the catalog list. Providers with no catalog hint at all (LM Studio, Ollama, custom endpoints) use live driver discovery alone. The user then enables specific models, which snapshots them into `user_models` rows.

The snapshot matters. An enabled model carries its own copy of pricing (input, output, cache-read, and cache-write per million tokens), its capabilities, and its default call settings, frozen at enable time. A turn is costed against that snapshot, so an upstream price change does not silently rewrite past turns, and the model picker does not depend on a live network call. Re-running discovery and re-enabling refreshes the snapshot.

For models neither the catalog nor discovery knows — brand-new releases, fine-tunes, gateway aliases — `AddManualModel` creates a `user_models` row from user-supplied metadata (`metadata_source = 'manual'`). Both the Mac and iOS clients expose it as "Add custom model" on the provider detail.

## The model-metadata catalog

`internal/modelmeta` holds a `LiveCatalog` that enriches discovered models with metadata (context window, capabilities, pricing hints) from models.dev. It is lazy: it fetches on first use and caches in memory, with no background ticker and no catalog tables in the database. The snapshot carries a max age (12h): the first lookup past it re-fetches in-line while concurrent callers serve the stale copy, a failed refresh serves stale and backs off five minutes before retrying, and the explicit Refresh RPC still forces a fetch. Without the max age a long-running daemon served its launch-day model list forever, which is how "the new model isn't in discovery" happened. `DiscoverModels` is handed the catalog through `Deps` so a driver can enrich its raw model list with the metadata models.dev knows.

Separately, `ConstraintsFor(providerType, modelID)` returns hard constraints a model imposes on call settings, resolved by exact match, then model-id prefix, then provider-type default. The shipped case: OpenAI's gpt-5 and o-series models lock temperature at 1.0 and reject an explicit `temperature` or `top_p`. The catalog encodes that as a locked-at constraint, the OpenAI driver omits the sampling parameters for those models, and the client renders the setting as locked rather than as an editable slider. This is why a model can show a fixed setting that the four-layer resolution cannot override.

## Stateless versus stateful

The interface splits on who owns history.

A **stateless** provider implements `Send(ctx, SendRequest)` and gets the full wire prefix every turn. The server owns history, builds the prefix from the message tree ([history-builder.md](history-builder.md)), and sends it whole. All three shipped drivers are stateless. This is the model that makes Psmith's stream resilience work: because the server holds the authoritative history and re-sends it, a turn does not depend on any provider-side session surviving.

A **stateful** provider would implement `StartSession` / `SendInSession` / `TerminateSession` and get only the newest message, with the backend holding the running session. The interface exists for a harness-style backend, but no stateful driver is implemented today. `Stateful()` returns false for everything shipped.

A driver can optionally implement `TokenCounter` (count tokens for a candidate prefix, used to inform compaction) and `ExplicitCacheProvider` (server-managed explicit caching).

## The send request and chunks

`SendRequest` carries the model id, the wire messages, the resolved call settings, the conversation id (threaded through so a driver can use it as a provider-specific cache key like OpenAI's `prompt_cache_key`), and the tool definitions. The messages are already wire-shaped: role rewriting and cross-provider thinking injection happened in the history builder before the driver sees them. A driver translates the tool definitions into its native shape, or silently drops them if it does not support tools.

`Send` returns a channel of chunks. The chunk vocabulary (text, thinking, tool-use, usage, error, done, and the rest) is shared across all drivers and documented in [streaming.md](streaming.md). Each driver's job is to parse its backend's stream into that common vocabulary so the supervisor and the client never see a provider-specific shape.

## Cross-provider thinking

Extended thinking is provider-specific on the wire. Anthropic emits signed thinking blocks that must be replayed verbatim; other providers represent reasoning differently or not at all. Two mechanisms bridge this. `RenderThinkingToText` converts a stored thinking blob to plain text for injection into a different provider's prefix (deterministic, computed once and cached). And the `thinking_signature` chunk captures Anthropic's block seal during a stream so a later tool round can replay the block intact. The result is that you can branch or continue a conversation across providers and the reasoning history degrades gracefully into text rather than breaking the next turn.

## Explicit caching

`ExplicitCacheProvider` is the optional interface for server-managed explicit caching, where the conversations service orchestrates the lifecycle (look up a stored ref, check expiry, check that the prefix hash still matches, then attach or create-and-store) and the driver provides three primitives: create a cache over a prefix, apply a valid ref to a request and trim the covered messages off the tail, and delete a ref. Two mechanisms fit the same shape: Gemini's upstream `cachedContents` resource (a real create and delete against the backend) and a future Anthropic explicit-cache toggle (stateless `cache_control` breakpoint placement, where create returns a sentinel and delete is a no-op). Drivers that do not implement the interface are silently no-op'd when the toggle is on.

## Adding a provider

The `/psmith-add-provider` skill scaffolds a new driver. The shape is always the same: a subpackage with a `Driver` type implementing `Provider` and `StatelessProvider`, an `init()` that registers the type string, a config struct unmarshaled from the instance's JSON, a `DiscoverModels` that lists and enriches models, and a `Send` that translates the backend's stream into the common chunk vocabulary. Tests point the driver's base URL at the fake LLM ([building-and-codegen.md](../operations/building-and-codegen.md)) and exercise the real parsing path.
