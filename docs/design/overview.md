# Overview

Reeve is a self-hosted AI chat orchestrator. One Go server owns every conversation, every provider credential, and every byte of model output. Clients are thin: they render state and send commands, and they can disconnect at any moment without losing work. The iOS app is the reference client and the one the author uses daily.

This document is the entry point to the design. It says what Reeve is, what it optimizes for, and how the pieces fit. The per-subsystem documents go deep; start here for the shape.

## What it is

Reeve is "ChatGPT with any model, any provider, and a lot of configuration." It mixes cloud APIs (Anthropic, OpenAI, Google, OpenRouter, anything OpenAI-compatible) behind one chat surface, and it exposes the knobs that off-the-shelf chat UIs hide:

- Pick the model per turn. Ask Claude for code, hand the result to Gemini for review, settle it with GPT-5, all in one conversation.
- Branch from any message. A conversation is a tree, not a list.
- Compress context on demand into a new context with a summary you edit before committing.
- Attach configuration as profiles: a system message, a default model, compression behavior, and a plugin pipeline, with single-parent inheritance.
- Run tools. Server-side tool plugins (web search, memory, image generation) and on-device tools the model calls mid-turn (Calendar, Reminders, Health, an Obsidian vault on iOS).

It is a personal project for one developer. Scope and tradeoffs favor "one person using this every day" over "platform for many tenants." Auth and per-user ownership are built in from the start so multi-user stays possible, but no sharing model exists yet.

## What it optimizes for

Two priorities shape almost every decision.

**Stream resilience for a mobile client.** When the iOS app backgrounds, the OS kills its network connections and the in-flight provider stream dies with them. Reeve routes all provider traffic through the server. The server consumes the upstream stream to completion regardless of client state, persists every chunk, and lets clients disconnect and reconnect freely. Background the app, come back five minutes later, the answer is finished and waiting. This single requirement is why the server owns history and why streaming is durable from the first design.

**Operational simplicity.** One Go binary, one Postgres, no message broker, no workflow engine, no Kubernetes. The server is a single process. Streaming durability is `INSERT INTO stream_chunks` plus an in-process pub/sub broker, not a distributed system. Adding a provider driver means writing Go and recompiling, not loading a plugin at runtime. The cost of this simplicity is that "plugin" means "compiled-in Go," and horizontal scale is not a goal.

## Topology

```
                 ┌───────────────────────────────────────────┐
   clients       │                 reeved (Go)               │
 ┌──────────┐    │  ConnectRPC services (auth, conversations, │     ┌──────────┐
 │  iOS app │◀──▶│  streams, model-providers, profiles,       │◀───▶│ Postgres │
 │  Mac app │    │  files, embedder, langfuse, device-tools,  │     │ (pgvector)│
 └──────────┘    │  events)                                   │     └──────────┘
                 │                                            │
                 │  stream supervisor (goroutine per run)     │────▶ upstream providers
                 │  + in-process pub/sub broker               │      (Anthropic, OpenAI,
                 │  history builder, plugin pipeline,          │       Google, OpenAI-compat)
                 │  embeddings worker, catalog (in memory)     │
                 └───────────────────────────────────────────┘
```

The server is the source of truth. It holds the model catalog, every provider credential, and all conversation, context, and message storage. Clients hold a read-through cache and a draft buffer, nothing authoritative.

## Stack

- Server: Go, a single binary named `reeved`. An operator CLI named `reeve` handles migrations, user creation, and key generation.
- Storage: Postgres, with the pgvector extension for message embeddings.
- Transport: ConnectRPC over HTTP/2 (h2c, cleartext; put a TLS proxy in front for anything beyond localhost). Chosen for first-class Go and Swift codegen, browser support without a gRPC-Web proxy, and clean server-streaming for token streams. Any endpoint that carries model output is a streaming RPC.
- Provider SDKs: each vendor's official SDK directly (`anthropic-sdk-go`, `openai-go`, `go-genai`). No multi-provider framework, so provider-specific features survive intact: Anthropic `cache_control` and extended thinking, OpenAI Responses API, Google `safetySettings`.
- Database access: `pgx` with `sqlc` for query codegen. No ORM.
- Model metadata: an in-memory `LiveCatalog` that lazy-fetches [models.dev](https://models.dev) on first lookup. There is no catalog table and no refresh ticker.

## How a turn works

The end-to-end path of one message, at a glance. Each step has its own document.

1. The client calls `SendMessage`. The server writes the user message row (durable immediately), resolves the provider and model, builds the wire prefix, and starts a stream run. It returns the user message and a `stream_run_id`, then returns. The provider call runs asynchronously in a supervisor goroutine.
2. The history builder composes the prefix from the active context: the system message, framing rows, and the user/assistant turns along the current branch, with role mapping, thinking handling, and the profile's plugin transforms applied. See [history-builder.md](history-builder.md).
3. The supervisor consumes the provider's stream, normalizes each event into a small chunk vocabulary, buffers chunks, and writes them to `stream_chunks` with monotonic sequence numbers. See [streaming.md](streaming.md).
4. If the model calls tools, the supervisor runs the tool loop: dispatch each call to the owning plugin, feed results back, repeat until the model stops. Device tools round-trip through the connected client. See [tools.md](tools.md).
5. The client subscribes to `SubscribeStream(stream_run_id, from_sequence)`. The server replays persisted chunks from the cursor, then live-tails over the broker, and ends with one terminal `StreamRun`. The client can drop and resubscribe at any point.
6. On terminal, the server materializes the assistant message from the accumulated chunks, records usage and cost, fires the post-assistant hook (auto-title, Langfuse), and prunes the transient chunks after a safety window.

## The core data shapes

Three nested resources, covered in [data-model.md](data-model.md):

- A **conversation** is the top-level chat. It points at a profile and carries settings.
- A **context** is a coherent history horizon: the slice of conversation built up since the last compression. A conversation has many contexts; the one with the newest activation time is active. The history builder always builds from the active context.
- A **message** belongs to a context and is tree-shaped via `parent_id`. Linear chats are degenerate trees; forking creates branches.

Provider configuration is three layers, covered in [providers.md](providers.md): a compile-time driver (`anthropic`, `openai-compatible`, `google`), a user-owned provider instance (credentials and endpoint), and a user-enabled model (a metadata snapshot the user controls).

## What is deliberately not here

- No multi-provider abstraction framework. Reeve's own Go interface is the common shape.
- No Temporal or workflow engine. The hard problem is token durability plus client reconnection, which a table and a goroutine solve. A workflow engine cannot revive a dead provider socket, so it would add operational weight for no gain. Revisit only if Reeve grows multi-step agent orchestration with independently resumable steps across processes.
- No runtime-loadable plugins. Plugins are compiled-in Go. Adding one is a recompile.
- No end-to-end encryption of message bodies. The server's value is processing plaintext (compression, history building, plugin pipelines, embeddings). E2E breaks all of it. Provider and plugin credentials are encrypted at rest; message bodies are not. For genuine "no provider sees this" privacy, run a local model through the OpenAI-compatible driver. See [encryption.md](encryption.md).

## Not yet built

- Stateful subprocess providers (Claude Code, Codex). The schema (`harness_sessions`) and the interface split exist; no driver does. The design lives in `harness-plan.md`.
- A web client.
- Background push on iOS. Local notifications fire while the app is in memory; APNs needs a paid Apple Developer account.
- Multi-user sharing. Providers, profiles, and conversations are per-user.

## Where to go next

- New to the system: read [data-model.md](data-model.md), then [streaming.md](streaming.md).
- Writing a client: read [../clients/client-spec.md](../clients/client-spec.md) and the API reference under [../api/](../api/overview.md).
- Operating it: read [../operations/installation.md](../operations/installation.md) and [../operations/configuration.md](../operations/configuration.md).
- Extending it: read [providers.md](providers.md) and [plugins.md](plugins.md).
