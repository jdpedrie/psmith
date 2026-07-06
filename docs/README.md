# Psmith documentation

Psmith is a self-hosted AI chat orchestrator: one Go server owns every conversation and provider credential, and thin clients render state and stream output without losing work when they disconnect. The iOS app is the reference client.

Start with [design/overview.md](design/overview.md). It explains what Psmith is, what it optimizes for, and how a turn flows end to end, then points into the rest.

This tree is the authoritative documentation. The older single-file planning and design notes (`architecture.md`, `ios-plan.md`, `ios-screens.md`, `harness-plan.md`, `multimodal-plan.md`, `conformance.md`, `device-tools-design.md`) have been removed; their content lives here now, reorganized by subsystem.

## Design

How the system works, one subsystem per document.

- [design/overview.md](design/overview.md) — what Psmith is, goals, topology, stack, the shape of a turn.
- [design/data-model.md](design/data-model.md) — conversation, context, the message tree, roles, profiles, inheritance, editing, branching.
- [design/providers.md](design/providers.md) — drivers, provider instances, enabled models, the live catalog, stateless vs stateful, per-driver behavior.
- [design/history-builder.md](design/history-builder.md) — building the wire prefix: walking the tree, role mapping, thinking, tool history, attachments, plugin contributions.
- [design/streaming.md](design/streaming.md) — the stream supervisor, durable chunks, the broker, retry, subscribe and replay, the chunk vocabulary.
- [design/plugins.md](design/plugins.md) — the plugin interface set, the pipeline and its inheritance, where each capability runs, the shipped catalog.
- [design/tools.md](design/tools.md) — the tool loop, server tools, device tools, the brokers, elicitation.
- [design/compression.md](design/compression.md) — two-stage compaction and the context lifecycle.
- [design/embeddings-and-search.md](design/embeddings-and-search.md) — embedder config, the background worker, semantic history search, the memory plugin.
- [design/auth-and-users.md](design/auth-and-users.md) — sessions, the interceptor, bootstrap, admin, ownership, the events bus.
- [design/encryption.md](design/encryption.md) — at-rest encryption, the master key, the file-URL sub-key, threat tiers.
- [design/titles-cost-observability.md](design/titles-cost-observability.md) — auto-titles, the cost ledger, Langfuse tracing.

## API

The wire contract.

- [api/overview.md](api/overview.md) — conventions, auth, error codes, sparse updates, streaming, the enums, the service list.
- [api/services.md](api/services.md) — per-service RPC reference for all ten ConnectRPC services.
- [api/non-rpc-endpoints.md](api/non-rpc-endpoints.md) — `/files/{id}`, `/mcp`, `/healthz`, and the device-tool and elicitation respond endpoints.

## Schema

- [schema/database.md](schema/database.md) — the full current Postgres schema, the migration history, and the special features.

## Operations

Running it.

- [operations/installation.md](operations/installation.md) — the three ways to run Psmith (Docker Compose, Docker, from source), the encryption key, the first user, and migrations.
- [operations/configuration.md](operations/configuration.md) — every environment variable.
- [operations/building-and-codegen.md](operations/building-and-codegen.md) — building, buf and sqlc codegen, the test layers, the fake LLM.
- [operations/fakellm.md](operations/fakellm.md) — the fake-LLM test harness: flavors, the script model, the server API, gotchas.

## Clients

- [clients/client-spec.md](clients/client-spec.md) — the provider-agnostic contract any client must honor: auth, the RPC flows, streaming and reconnection, offline behavior, device tools, elicitation, file upload, ordering and idempotency.
- [clients/ios-reference.md](clients/ios-reference.md) — the iOS reference implementation: PsmithKit and PsmithUI layering, the stream hub, repositories, view models, account switching, the offline queue, the cache, device-tool dispatch, the screens.
- [clients/building-ios.md](clients/building-ios.md) — building and running the iOS app: prerequisites, the simulator loop, the make targets, running on a physical device, signing, troubleshooting.
- [clients/web.md](clients/web.md) — the server-rendered web client: templ + htmx (with the SSE extension), in-process service calls, cookie sessions, SSE streaming. Early but functional.

## Project notes

- [testing-plan.md](testing-plan.md) — the Swift two-layer test harness plan.
- [todo.md](todo.md) — tactical deferred work from in-flight implementation.
