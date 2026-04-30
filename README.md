# Clark

Clark is a self-hosted AI chat orchestrator. It mixes cloud APIs (Anthropic, OpenAI, Google, OpenRouter, anything OpenAI-compatible) and — eventually — local agentic CLIs behind a single chat UI, with a server that owns history so iOS clients can disconnect and reconnect without losing tokens mid-stream.

It's a personal project. The roadmap, scope, and tradeoffs are biased toward "one developer using this every day," not "platform for many tenants."

![Conversation view](docs/screenshots/capital.png)

## Why this exists

Off-the-shelf chat UIs make easy things easy and hard things impossible. Clark trades polish for knobs:

- **Mix providers in one conversation** — pick the model per turn. Ask Claude for code, hand the result to Gemini for review, settle the dispute with GPT-5.
- **Server-owned streams** — the server consumes upstream provider streams to completion regardless of client state. Background the iOS app, return five minutes later, the message is finished and waiting.
- **Branching message trees** — every conversation is a tree, not a list. Fork from any message; the UI shows sibling counts and lets you switch branches.
- **Manual context compression** — when you're approaching a model's context window, compress on demand into a new context with a summary you can edit before committing.
- **Profiles as configuration bundles** — system message + default model + compression behavior + plugins, attached to a conversation. Profiles inherit from parents, so "experiment from the smoke-test profile but with a different system message" is a one-field override.
- **Plugins as compile-time Go code** — chat plugins are a single Go interface set covering system-prompt contribution, outgoing message rewrites, history transforms, inbound chunk processing, and display rewrites. Bundled in one config row so paired behaviors stay coherent.

## Status

Working today, exercised daily by the author:

- Anthropic, OpenAI (Chat Completions + Responses APIs), Google Gemini, and any OpenAI-compatible endpoint (Ollama, OpenRouter, vLLM, llama.cpp, LM Studio, …).
- Streaming, branching, editing, deleting, manual compression with two-stage promotion.
- Per-message + per-context cost and token tracking.
- Auto-titling via a small cheap model (or Apple Foundation Models on-device on macOS).
- Per-conversation overrides for `temperature`, `max_output_tokens`, thinking budget, etc., with 4-layer resolution (conversation → profile → model → provider).
- macOS client (SwiftUI, Liquid Glass).

Deferred:

- Tool use (the plugin interface is settled; the wire-translation work is tracked in `docs/todo.md`).
- iOS / web clients.
- Stateful subprocess providers (Claude Code, Codex) — interface is sketched.
- Multi-user sharing — `provider`/`profile`/`conversation` are per-user only.
- Encryption-at-rest beyond host-level disk encryption (sketched in `docs/architecture.md`).

## Architecture

The full design — provider model, conversation/context/message data model, streaming subsystem, plugin interface, threat tiers — lives in [`docs/architecture.md`](docs/architecture.md). Read it before working in the repo.

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

- **Server** — Go, single binary (`clarkd`), Postgres for storage, ConnectRPC for transport (HTTP/2, server-streaming RPCs, first-class Go/TS/Swift codegen).
- **Catalog** — model metadata refreshed periodically from [models.dev](https://models.dev).
- **macOS client** — SwiftUI on macOS 26 (Liquid Glass). Shared `ClarkKit` Swift package for repositories/view models so future iOS reuses the non-UI layer.
- **No multi-provider framework** — drivers use each vendor's official SDK directly so provider-specific features (Anthropic `cache_control` + thinking, OpenAI Responses, Google `safetySettings`) survive intact.

## Repo layout

```
clarkd/                   # convenience launcher
cmd/clarkd/               # server entrypoint
cmd/seeduser/             # admin user bootstrap utility
proto/clark/v1/           # ConnectRPC service definitions
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
  ClarkSwift/             # shared Swift package (ClarkKit + tests)
  clarkd-mac/             # macOS app + snapshot tests
docs/
  architecture.md         # design decisions
  testing-plan.md         # Swift L1+L2 testing strategy
  todo.md                 # tactical follow-ups
  screenshots/
```

## Running it

### Prerequisites

- Go 1.22+
- Docker (for the dev Postgres) — or your own Postgres 14+ instance
- macOS 26 (Liquid Glass) + Xcode 17 if you want the macOS client
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

### 2. Migrate

```bash
make migrate-up
```

### 3. Bootstrap and run the server

The server requires `CLARK_DSN`. On first run, if no users exist and `CLARK_BOOTSTRAP_ADMIN_USERNAME` + `CLARK_BOOTSTRAP_ADMIN_PASSWORD` are set, the server creates an admin user; if no users and no bootstrap env vars, it refuses to start.

```bash
export CLARK_DSN='postgres://clark:clark@localhost:5433/clark?sslmode=disable'
export CLARK_BOOTSTRAP_ADMIN_USERNAME=john
export CLARK_BOOTSTRAP_ADMIN_PASSWORD=changeme
make run
# clarkd listening addr=:8080
```

Other env vars:

| Var | Default | Purpose |
|---|---|---|
| `CLARK_ADDR` | `:8080` | Listen address |
| `CLARK_DSN` | _(required)_ | Postgres connection string |
| `CLARK_BOOTSTRAP_ADMIN_USERNAME` | — | One-shot admin bootstrap |
| `CLARK_BOOTSTRAP_ADMIN_PASSWORD` | — | One-shot admin bootstrap |
| `CLARK_CATALOG_REFRESH_INTERVAL` | `24h` | models.dev refresh cadence; `0` disables |

### 4. macOS client

```bash
make mac-app-run
```

`make mac-app-run` builds the Swift package, wraps the binary in a `ClarkMac.app` bundle (so macOS gives it a Dock icon and can be screenshotted/automated), and launches it. Sign in with your bootstrap credentials.

![Providers and enabled models](docs/screenshots/settings.png)

Add a provider (Settings → Providers → +), pick a type (`anthropic`, `openai-compatible`, `google`), paste the API key, and the client will let you discover and enable specific models. Then create a profile pointing at one of those models:

![Profile detail](docs/screenshots/profiles.png)

…and you're ready to chat. The conversation list groups by profile or sorts by recent activity:

![Conversation with errored stream](docs/screenshots/conversation.png)

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
make swift-test      # ClarkKit L1 (integration) + ClarkMac L2 (snapshot)
make swift-test-l1   # ClarkKit only
make swift-test-l2   # snapshot only
make swift-test-l2-record  # re-baseline snapshots after intentional UI changes
```

The repo's testing posture is documented in [`docs/testing-plan.md`](docs/testing-plan.md). Short version:

- **Backend** — Go unit tests for pure functions, [`pgtestdb`](https://github.com/peterldowns/pgtestdb) for anything that touches Postgres (each test gets a fresh, migrated DB).
- **Swift L1** — every public Repository/ViewModel method gets an integration test that drives it against a freshly-spawned `clarkd` subprocess on an ephemeral port + isolated DB.
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

Implement `providers.Provider` plus either `StatelessProvider.Send` (full prefix every turn — server owns history) or `StatefulProvider.{StartSession, SendInSession, TerminateSession}` (long-lived harness session — harness owns history). Then add a blank import in `cmd/clarkd/main.go` so the package is linked. See `internal/providers/anthropic/`, `internal/providers/openai/`, and `internal/providers/google/` as references.

### Adding a chat plugin

Plugins live in `plugins/`. The required interface is just `Name()` + `Description()`; every behavior is an opt-in interface (`SystemPrompter`, `OutgoingUserTransformer`, `HistoryTransformer`, `ChunkTransformer`, `DisplayTransformer`, `ToolProvider`). See [`plugins/lettered_choices.go`](plugins/lettered_choices.go) for a working example that uses three of those interfaces at once. The full plugin contract — including the cache-observability story for plugins that mutate prefix bytes — is in `docs/architecture.md`.

## Authentication

Auth is always required — there's no single-user bypass code path. Sessions are opaque tokens hashed in the DB, default 30-day TTL, refreshed on use. Clients carry `Authorization: Bearer <token>` per request; a Connect interceptor resolves the user and attaches them to the request `context.Context`. RPCs never carry an explicit `user_id` — it's implicit in the auth context.

API tokens for programmatic access are deferred but trivial to add (same `sessions` mechanism with `expires_at = NULL`).

## License

Personal project, no license declared yet. If you have a use for any of this, open an issue.
