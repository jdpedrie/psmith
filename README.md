# Reeve

Reeve is a self-hosted AI chat orchestrator. It mixes cloud APIs (Anthropic, OpenAI, Google, OpenRouter, anything OpenAI-compatible) and — eventually — local agentic CLIs behind a single chat UI, with a server that owns history so iOS clients can disconnect and reconnect without losing tokens mid-stream.

It's a personal project. The roadmap, scope, and tradeoffs are biased toward "one developer using this every day," not "platform for many tenants."

> **Human Note:**
>
> Reeve was built to scratch an itch. It's entirely vibe-coded, but I use it frequently and it works well. It's "ChatGPT with any model and provider and a lot of configuration". I make no claims as to the code quality, because I didn't write it, but I did do my best to constrain the architectural path to something which seemed sane to me.

![Conversation view](docs/screenshots/capital.png)

## Why this exists

Off-the-shelf chat UIs make easy things easy and hard things impossible. Reeve trades polish for knobs:

- **Mix providers in one conversation** — pick the model per turn. Ask Claude for code, hand the result to Gemini for review, settle the dispute with GPT-5.
- **Server-owned streams** — the server consumes upstream provider streams to completion regardless of client state. Background the iOS app, return five minutes later, the message is finished and waiting.
- **Branching message trees** — every conversation is a tree, not a list. Fork from any message; the UI shows sibling counts and lets you switch branches.
- **Manual context compression** — when you're approaching a model's context window, compress on demand into a new context with a summary you can edit before committing.
- **Profiles as configuration bundles** — system message + default model + compression behavior + plugins, attached to a conversation. Profiles inherit from parents, so "experiment from the smoke-test profile but with a different system message" is a one-field override.
- **Plugins as compile-time Go code** — chat plugins are a single Go interface set covering system-prompt contribution, outgoing message rewrites, history transforms, inbound chunk processing, and display rewrites. Bundled in one config row so paired behaviors stay coherent.

## Status

Working today, exercised daily by the author:

- Anthropic, OpenAI (Chat Completions + Responses APIs), Google Gemini, and any OpenAI-compatible endpoint (Ollama, OpenRouter, vLLM, llama.cpp, LM Studio, …).
- **13 built-in provider presets** (OpenAI, Anthropic, Google, xAI, DeepSeek, Groq, OpenRouter, Mistral, Together, Cerebras, Qwen, Ollama, Perplexity) with per-provider quirks: xAI's `x-grok-conv-id` cache header, OpenRouter's `HTTP-Referer`/`X-Title` app identity, Qwen's `enable_thinking` body field, Ollama's `/api/tags` discovery for local model metadata, and more.
- Streaming, branching, editing, deleting, manual compression with two-stage promotion.
- "Save and Resend" on assistant rows chains a NEW assistant after the edit (two assistants in a row), with synthetic-user wire injection so OpenAI/Gemini accept the trailing-assistant prefix.
- Per-message + per-context cost and token tracking, plus a **cache-efficiency dot** (red/yellow/green) on each assistant message — at-a-glance signal of how much of the prompt was served from provider-side cache.
- **Anthropic prompt caching** (auto `cache_control` placement at the stable-prefix boundary), **OpenAI `prompt_cache_key`** routing, **Google implicit caching** + explicit `cachedContents` API support (Go-only; no UI yet).
- Auto-titling via a small cheap model (or Apple Foundation Models on-device on macOS).
- Per-conversation overrides for `temperature`, `max_output_tokens`, thinking budget, etc., with 4-layer resolution (conversation → profile → model → provider).
- **macOS** client (SwiftUI, Liquid Glass) and **iOS** client (SwiftUI, iOS 26) sharing repositories, view models, domain types, and most views via the `ReeveSwift` package. The iOS app handles ScenePhase backgrounding by reattaching to in-flight server streams from the last received chunk on resume.
- **Offline-tolerant iOS** — SwiftData read-through cache means recent conversations stay readable when reeved is unreachable. A `/healthz` probe flips a connectivity banner + disables Send. Composer drafts persist per conversation across navigation and app kills. User-tunable cache cap (default 100 MB) under Settings → General.
- **Tool use, end to end** — server-side tool plugins (web search, memory, image generation) and on-device tools the model calls mid-turn (Calendar, Reminders, Health, Obsidian vault on iOS), with results fed back into the stream, an audit log, and a per-call permission model. Mid-call elicitation lets a tool ask the user for input without that input entering the model's context.
- **Semantic history search, MCP, tracing** — opt-in message embeddings power a `search_history` context tool; a `/mcp` endpoint exposes a curated subset of the API as MCP tools; per-user Langfuse config emits traces.

Deferred:

- Web client.
- APNs push notifications on iOS — local UNUserNotifications fire while the app is in memory; full background pushes need a paid Apple Developer account.
- Stateful subprocess providers (Claude Code, Codex) — interface is sketched.
- Multi-user sharing — `provider`/`profile`/`conversation` are per-user only.
- Encryption-at-rest beyond host-level disk encryption (sketched in `docs/design/encryption.md`).

## Architecture

The full documentation lives under [`docs/`](docs/README.md): system design (one document per subsystem), the API and database references, installation and deployment, and the client spec. Start at [`docs/README.md`](docs/README.md), or jump straight to [`docs/design/overview.md`](docs/design/overview.md). Read it before working in the repo.

```
┌──────────────┐    ┌────────────────────────┐    ┌──────────────┐
│  Provider    │───▶│  Stream supervisor     │───▶│  Postgres    │
│  (Anthropic, │    │  (goroutine per run)   │    │  stream_runs │
│   OpenAI,    │    │                        │    │  + chunks    │
│   harness…)  │    │  + in-process pub/sub  │    └──────┬───────┘
└──────────────┘    └─────────┬──────────────┘           │
                              │                          │
                              ▼                          │
                       ┌──────────────┐                  │
                       │  Subscribers │◀─────────────────┘
                       │  (clients)   │   (replay from
                       └──────────────┘    sequence N)
```

Stack:

- **Server** — Go, single binary (`reeved`), Postgres for storage, ConnectRPC for transport (HTTP/2, server-streaming RPCs, first-class Go/TS/Swift codegen).
- **Model metadata** — in-process `LiveCatalog` (no DB cache, no periodic refresh goroutine). On first lookup the server fetches [models.dev](https://models.dev) once into memory; subsequent reads are instant. Snapshot the result onto each `user_models` row at provider-add time so per-message cost calc is local and deterministic.
- **macOS + iOS clients** — SwiftUI on macOS 26 / iOS 26. The shared `ReeveSwift` package ships two products: `ReeveKit` (repositories, view models, domain types, ConnectRPC client) and `ReeveUI` (cross-platform SwiftUI views — chat bubbles, model picker, settings forms, theme system, provider logos). Per-platform shells (`reeved-mac`, `reeved-ios`) supply OS-native bindings (clipboard, notifications) via thin SwiftUI environment-injected protocols defined in `ReeveKit/Platform/`.
- **No multi-provider framework** — drivers use each vendor's official SDK directly so provider-specific features (Anthropic `cache_control` + thinking, OpenAI Responses, Google `safetySettings`) survive intact. The OpenAI-compatible driver carries a small `Quirks` overlay for the 11 OAI-compat presets so each provider's deviations (cache headers, extra body fields, custom discovery endpoints) live in one slot per preset rather than forking the driver.

## Repo layout

```
cmd/reeved/               # server entrypoint
cmd/reeve/                # operator CLI — useradd today, more later
proto/reeve/v1/           # ConnectRPC service definitions
gen/                      # generated Go bindings (buf)
db/migrations/            # goose-format SQL migrations
internal/
  auth/                   # session tokens, bootstrap, interceptor
  conversations/          # conversation/context/message CRUD + send
  history/                # prefix builder (system→context→user/assistant)
  modelmeta/              # models.dev catalog ingest
  modelproviders/         # provider/model CRUD + discovery
  profiles/               # profiles + parent-chain resolver
  providers/              # driver registry + per-provider drivers
    anthropic/  google/  openai/
  store/                  # sqlc-generated query layer
  stream/                 # supervisor, broker, run lifecycle
plugins/                  # in-tree chat plugins
clients/
  ReeveSwift/             # shared Swift package: ReeveKit + ReeveUI + tests
  reeved-mac/             # macOS app + snapshot tests
  reeved-ios/             # iOS app (xcodegen-driven; project.yml is canonical)
docs/
  README.md               # documentation index
  design/                 # one doc per subsystem
  api/                    # the wire contract
  schema/                 # database schema + migration history
  operations/             # install, configure, build
  clients/                # client spec + iOS reference
  testing-plan.md         # Swift L1+L2 testing strategy
  todo.md                 # tactical follow-ups
  screenshots/
scripts/
  convert-svgs-to-pngs.sh # iOS-side provider-logo PNGs (rsvg-convert)
```

## Running it

### Prerequisites

- Go 1.22+
- Docker (for the dev Postgres) — or your own Postgres 14+ instance
- macOS 26 (Liquid Glass) + Xcode 17 if you want the macOS or iOS client
- For the iOS client: `xcodegen` (`brew install xcodegen`) to regenerate the Xcode project from `clients/reeved-ios/project.yml`, and `librsvg` (`brew install librsvg`) so `rsvg-convert` can materialise the iOS-side provider-logo PNGs
- `buf` and `sqlc` if you regenerate code (`brew install bufbuild/buf/buf sqlc`)
- `goose` for migrations (`go install github.com/pressly/goose/v3/cmd/goose@latest`)

### 1. Postgres

The repo's `Makefile` and tests assume a Postgres on **port 5433** with credentials `clark:clark`:

```bash
docker run -d --name clark-postgres \
  -e POSTGRES_USER=clark -e POSTGRES_PASSWORD=clark -e POSTGRES_DB=clark \
  -p 5433:5432 pgvector/pgvector:pg16
```

Override with `PGTESTDB_HOST`, `PGTESTDB_PORT`, `PGTESTDB_USER`, `PGTESTDB_PASSWORD`, `PGTESTDB_DB`, or `GOOSE_DBSTRING` if your setup differs.

### 2. Apply schema

```bash
go run ./cmd/reeve install                                # uses local dev DSN
go run ./cmd/reeve install -db <postgres-url>             # against any reachable DB
go run ./cmd/reeve install -status                        # what's applied so far
```

`reeve install` ships the goose-format migrations baked into the binary (no source tree, no external `goose` install needed) and is the recommended setup path for production deployments. `make migrate-up` stays as the dev-loop tool when iterating on a new migration file.

### 3. Bootstrap and run the server

The server requires `REEVE_DSN`. On first run, if no users exist and `REEVE_BOOTSTRAP_ADMIN_USERNAME` + `REEVE_BOOTSTRAP_ADMIN_PASSWORD` are set, the server creates an admin user; if no users and no bootstrap env vars, it refuses to start.

```bash
export REEVE_DSN='postgres://clark:clark@localhost:5433/clark?sslmode=disable'
export REEVE_BOOTSTRAP_ADMIN_USERNAME=john
export REEVE_BOOTSTRAP_ADMIN_PASSWORD=changeme
export REEVE_MASTER_KEY=$(go run ./cmd/reeve genkey)   # AES-256 key for at-rest secrets
make run
# reeved listening addr=:8080
```

Other env vars:

| Var | Default | Purpose |
|---|---|---|
| `REEVE_ADDR` | `:8080` | Listen address |
| `REEVE_DSN` | _(required)_ | Postgres connection string |
| `REEVE_BOOTSTRAP_ADMIN_USERNAME` | — | One-shot admin bootstrap |
| `REEVE_BOOTSTRAP_ADMIN_PASSWORD` | — | One-shot admin bootstrap |
| `REEVE_MASTER_KEY` | — | base64-encoded 32-byte AES-256-GCM key. When set, provider API keys + plugin credentials land encrypted in `*.config_encrypted` columns. Mint with `reeve genkey`. Without it the server boots with a loud warning and stores config blobs in plaintext. |
| `REEVE_DEV_AUTOKEY` | — | Set to `1` to mint a throwaway key per process (dev convenience; data won't survive a restart). Mutually exclusive with `REEVE_MASTER_KEY`. |

### 4. Or run in Docker

The repo ships a multi-stage Dockerfile that builds both `reeved` and the `reeve` operator CLI into a single ~45 MB Alpine image. Both binaries land on `PATH` so `docker exec` can run install/useradd/genkey against a running container.

```bash
docker build -t reeve .

# Apply schema migrations (one-shot)
docker run --rm \
  -e REEVE_DSN='postgres://clark:clark@host.docker.internal:5433/clark?sslmode=disable' \
  --entrypoint reeve reeve install

# Run the server
docker run -d --name reeved \
  -p 8080:8080 \
  -e REEVE_DSN='postgres://clark:clark@host.docker.internal:5433/clark?sslmode=disable' \
  -e REEVE_MASTER_KEY=$(go run ./cmd/reeve genkey) \
  -e REEVE_BOOTSTRAP_ADMIN_USERNAME=john \
  -e REEVE_BOOTSTRAP_ADMIN_PASSWORD=changeme \
  reeve

# Operator commands against the running container
docker exec -it reeved reeve useradd alice
docker exec -it reeved reeve install -status
```

Notes:

- `host.docker.internal` reaches the host's Postgres on macOS / Windows. On Linux pass `--network=host` and use `localhost`, or point the DSN at the container/host bridge IP.
- The image runs as a non-root `reeve` user. `GET /healthz` returns 200 — handy for container orchestrator liveness probes.
- Build context is filtered via `.dockerignore` to skip the Swift clients (`clients/`) and editor caches.

### 5. macOS client

```bash
make mac-app-run
```

`make mac-app-run` builds the Swift package, wraps the binary in a `ReeveMac.app` bundle (so macOS gives it a Dock icon and can be screenshotted/automated), and launches it. Sign in with your bootstrap credentials.

![Providers and enabled models](docs/screenshots/providers.png)

The Providers sidebar lists every built-in preset always — configured ones at the top with a green status dot, the rest in an "Available" section greyed out with a `+` affordance. Click any preset → the form opens pre-filled (base URL, label, env-var hint), you paste the API key. The toolbar `+` is reserved for fully-custom OpenAI-compatible endpoints (self-hosted, a fork of a known provider, anything not covered by a preset). Discover models on the provider's detail tab; enable the ones you want. Then create a profile pointing at one:

![Profile detail](docs/screenshots/profiles.png)

…and you're ready to chat. The conversation list groups by profile or sorts by recent activity:

![Conversation with errored stream](docs/screenshots/conversation.png)

### 6. iOS client

```bash
make ios-app-run
```

`make ios-app-run` runs `xcodegen` to materialise the Xcode project from `clients/reeved-ios/project.yml`, converts the provider-logo SVGs into PNGs (iOS can't decode raw SVG bytes from arbitrary file URLs), builds the app for the iPhone simulator, boots the simulator, installs the bundle, and launches it. Defaults to `iPhone 17 Pro`; override via `IOS_SIMULATOR='iPhone 16'` (or any other installed simulator runtime).

First launch: enter the URL of your reeved instance (the simulator can hit `http://localhost:8080` directly), the app probes it to confirm, then asks for credentials. The "Change server" link on the credentials screen lets you bounce back to the URL screen — single-server-at-a-time stays for v1; "log out, change server, log back in" is the multi-server workflow.

<p align="left">
  <img src="docs/screenshots/ios-chats.png" alt="iOS chats list" width="260">
  <img src="docs/screenshots/ios-conversation.png" alt="iOS conversation view" width="260">
  <img src="docs/screenshots/ios-providers.png" alt="iOS providers settings" width="260">
</p>

The iOS app is at parity with the Mac app for everyday chat: streaming, branching, editing, deleting, manual compression, all settings panes (Providers / Profiles / Plugins / Appearance / Notifications), per-message cost + cache-efficiency dot, in-bubble token usage and timestamp. ScenePhase backgrounding cancels the local SSE subscription and resumes from the last received chunk on return, so a backgrounded stream keeps streaming on the server and rejoins live when the app foregrounds. Local notifications fire when an assistant turn finishes while the app is unfocused (suppressed when `applicationState == .active`).

To run on a physical device: open `clients/reeved-ios/ReeveiOS.xcodeproj` in Xcode after `make ios-project`, pick your device, and let Xcode handle code signing with your free Personal Team. Profiles auto-rotate every 7 days on the free tier.

## Development

### Generated code

```bash
make proto    # regenerate ConnectRPC bindings (Go + Swift)
make sqlc     # regenerate query bindings from db/queries/*.sql
make lint     # buf lint + go vet
make tidy     # go mod tidy
```

### Tests

```bash
make test            # full Go test suite (unit + pgtestdb integration)
make swift-test      # ReeveKit L1 (integration) + ReeveMac L2 (snapshot)
make swift-test-l1   # ReeveKit only
make swift-test-l2   # snapshot only
make swift-test-l2-record  # re-baseline snapshots after intentional UI changes
```

The repo's testing posture is documented in [`docs/testing-plan.md`](docs/testing-plan.md). Short version:

- **Backend** — Go unit tests for pure functions, [`pgtestdb`](https://github.com/peterldowns/pgtestdb) for anything that touches Postgres (each test gets a fresh, migrated DB).
- **Swift L1** — every public Repository/ViewModel method gets an integration test that drives it against a freshly-spawned `reeved` subprocess on an ephemeral port + isolated DB.
- **Swift L2** — every load-bearing SwiftUI view (or non-trivial state of one) gets a snapshot test against committed PNG baselines.

`CLAUDE.md` makes this a hard rule: don't merge a vertical slice without tests. `pgtestdb` failures usually mean the connection string in `internal/testutil` doesn't match your Postgres — set `PGTESTDB_*` env vars to override.

### Adding a provider driver

Drivers live in `internal/providers/<name>/` and self-register in `init()`:

```go
package myprovider

func init() { providers.Register("my-provider", New) }

func New(deps providers.Deps, config json.RawMessage) (providers.Provider, error) {
    // …
}
```

Implement `providers.Provider` plus either `StatelessProvider.Send` (full prefix every turn — server owns history) or `StatefulProvider.{StartSession, SendInSession, TerminateSession}` (long-lived harness session — harness owns history). Then add a blank import in `cmd/reeved/main.go` so the package is linked. See `internal/providers/anthropic/`, `internal/providers/openai/`, and `internal/providers/google/` as references.

### Adding a chat plugin

Plugins live in `plugins/`. The required interface is just `Name()` + `Description()`; every behavior is an opt-in interface (`SystemPrompter`, `OutgoingUserTransformer`, `HistoryTransformer`, `ChunkTransformer`, `DisplayTransformer`, `ToolProvider`). See [`plugins/lettered_choices.go`](plugins/lettered_choices.go) for a working example that uses three of those interfaces at once. The full plugin contract is in [`docs/design/plugins.md`](docs/design/plugins.md).

## Authentication

Auth is always required — there's no single-user bypass code path. Sessions are opaque tokens hashed in the DB, default 30-day TTL, refreshed on use. Clients carry `Authorization: Bearer <token>` per request; a Connect interceptor resolves the user and attaches them to the request `context.Context`. RPCs never carry an explicit `user_id` — it's implicit in the auth context.

API tokens for programmatic access are deferred but trivial to add (same `sessions` mechanism with `expires_at = NULL`).

## License

MIT — see [`LICENSE`](LICENSE).
