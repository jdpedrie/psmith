# Installation and deployment

Reeve is one Go server (`reeved`) plus one Postgres database. There is a second binary, the `reeve` operator CLI, that applies migrations, creates users, and mints encryption keys. Both binaries ship in the Docker image and land on `PATH`.

This document covers a fresh install, local development, and Docker deployment. For the full env-var list see [configuration.md](configuration.md). For codegen and tests see [building-and-codegen.md](building-and-codegen.md).

## Prerequisites

- Go 1.25 (the Docker build uses `golang:1.25-alpine`; the go.mod toolchain pins the version).
- Postgres 14 or newer with the pgvector extension available. The dev setup uses the `pgvector/pgvector:pg16` image.
- For the clients: macOS 26 and Xcode 17. For the iOS client, `xcodegen` (`brew install xcodegen`) and `librsvg` (`brew install librsvg`).
- Only if you regenerate code: `buf` and `sqlc`. Only for the dev migration loop: `goose`.

## One required decision before first run

Reeve encrypts provider credentials and plugin secrets at rest with AES-256-GCM. The key comes from `REEVE_MASTER_KEY` (base64 of 32 bytes). Mint one once per environment and keep it safe:

```bash
export REEVE_MASTER_KEY=$(go run ./cmd/reeve genkey)
```

If you do not set it, the server still starts, but it logs a loud warning and writes config blobs in plaintext through a no-op cipher. Losing the key after rows are encrypted means losing the ability to read those rows. There is a dev-only escape hatch, `REEVE_DEV_AUTOKEY=1`, that mints a throwaway key per process; data written under it is unreadable after a restart. See [encryption.md](../design/encryption.md).

## Postgres

The `Makefile` and the test harness assume Postgres on port 5433 with credentials `clark:clark` and database `clark`. The port is off the default 5432 to avoid clashing with other local databases. The `clark` naming predates the project rename and is kept for the container and credentials only.

```bash
docker run -d --name clark-postgres \
  -e POSTGRES_USER=clark -e POSTGRES_PASSWORD=clark -e POSTGRES_DB=clark \
  -p 5433:5432 pgvector/pgvector:pg16
```

### pgvector and template1

Message embeddings use a `vector(768)` column, so the `vector` extension must exist in the target database. The extension is untrusted, which means a non-superuser cannot install it, and the migrations deliberately do not try. Two paths handle this:

- `reeve install` runs `CREATE EXTENSION IF NOT EXISTS vector` as a preflight before applying migrations, so a normal install works if the connecting role can create the extension.
- The test harness clones each test database from `template1`. Install the extension once into `template1` so every cloned database inherits it:

```bash
docker exec clark-postgres psql -U clark -d template1 -c "CREATE EXTENSION IF NOT EXISTS vector"
```

If migration 00034 fails with a missing-extension error, this is why.

## Apply the schema

`reeve install` applies the goose migrations baked into the binary. No source tree and no separate goose install are needed. This is the recommended path for any real deployment.

```bash
go run ./cmd/reeve install                      # uses the local dev DSN
go run ./cmd/reeve install -db <postgres-url>   # against any reachable database
go run ./cmd/reeve install -status              # show what is applied, change nothing
go run ./cmd/reeve install -target 30           # migrate up to a specific version
```

DSN resolution order for the CLI: the `-db` flag, then `REEVE_DSN`, then `DATABASE_URL`, then the local dev default `postgres://clark:clark@localhost:5433/clark?sslmode=disable`.

For iterating on a new migration file during development, `make migrate-up` and `make migrate-down` use the external `goose` CLI against `db/migrations` with `GOOSE_DBSTRING` defaulting to the local dev DSN.

## Create the first user

Reeve always requires auth. There is no single-user bypass. There are two ways to get the first account.

Bootstrap from env vars on first run. If no users exist and both `REEVE_BOOTSTRAP_ADMIN_USERNAME` and `REEVE_BOOTSTRAP_ADMIN_PASSWORD` are set, the server creates that admin on startup. If no users exist and the bootstrap vars are not set, the server still starts, but every authenticated RPC rejects until a user exists.

Or create one directly with the CLI, which works against a fresh database without a running server:

```bash
go run ./cmd/reeve useradd -u john          # prompts for the password, no echo
go run ./cmd/reeve useradd -u alice -no-admin
```

`useradd` defaults to creating an admin. Pass `-no-admin` for a regular user. It writes the row directly, so it does not need the server or an existing admin.

## Run the server

The server requires `REEVE_DSN`. A minimal run:

```bash
export REEVE_DSN='postgres://clark:clark@localhost:5433/clark?sslmode=disable'
export REEVE_MASTER_KEY=$(go run ./cmd/reeve genkey)
export REEVE_BOOTSTRAP_ADMIN_USERNAME=john
export REEVE_BOOTSTRAP_ADMIN_PASSWORD=changeme
make run
# reeved listening addr=:8080
```

The server listens on `REEVE_ADDR` (default `:8080`) using cleartext HTTP/2 (h2c). It does not terminate TLS. For anything beyond localhost, run it behind a TLS-terminating reverse proxy.

### What happens on startup

In order: connect to Postgres and ping; bootstrap the admin if no users exist; build the in-memory model catalog (lazy, no fetch yet); start the stream supervisor and flip any `running` stream runs left by a crash to `interrupted`; start the chunk-cleanup goroutine; load the encryption cipher; start the embeddings worker and resolver; register the post-login profile-seeding hook and backfill system profiles; build the auth interceptor with the `Login` and `Probe` procedures exempt; create the file storage directory; derive the file-URL signing key; build every service; register the Connect handlers plus the plain-HTTP endpoints (`/healthz`, `/files/{id}`, `/mcp`, the elicitation and device-tool respond endpoints); and listen. Shutdown on SIGINT or SIGTERM drains the Langfuse buffer and stops the HTTP server with a 10 second timeout.

Migrations are not run at server startup. Apply them with `reeve install` (the Docker entrypoint does this automatically; see below).

## Docker

The repo ships a multi-stage Dockerfile that builds both binaries into one Alpine image (around 45 MB). The image runs as a non-root `reeve` user and exposes 8080.

```bash
docker build -t reeve .

# Apply migrations once (the entrypoint also does this for `reeved`, see note)
docker run --rm \
  -e REEVE_DSN='postgres://clark:clark@host.docker.internal:5433/clark?sslmode=disable' \
  --entrypoint reeve reeve install

# Run the server
docker run -d --name reeved -p 8080:8080 \
  -e REEVE_DSN='postgres://clark:clark@host.docker.internal:5433/clark?sslmode=disable' \
  -e REEVE_MASTER_KEY=<your key> \
  -e REEVE_BOOTSTRAP_ADMIN_USERNAME=john \
  -e REEVE_BOOTSTRAP_ADMIN_PASSWORD=changeme \
  reeve

# Operator commands against the running container
docker exec -it reeved reeve useradd alice
docker exec -it reeved reeve install -status
```

The entrypoint script runs `reeve install` automatically before starting `reeved` when `REEVE_DSN` is set, so a plain `docker run` migrates then serves. It passes the DSN explicitly because the CLI reads `-db` or `DATABASE_URL`, not `REEVE_DSN`. For non-`reeved` commands (for example `docker run reeve reeve genkey`) it skips the migration step.

Notes:

- `host.docker.internal` reaches the host's Postgres on macOS and Windows. On Linux use `--network=host` with `localhost`, or point the DSN at the bridge IP.
- `GET /healthz` returns `{"ok":true}` with no auth and no database hit. Use it for orchestrator liveness probes.
- The build context is filtered by `.dockerignore` to skip the Swift clients and editor caches.

## Clients

The macOS and iOS apps share a Swift package, `ReeveSwift`, that ships `ReeveKit` (repositories, view models, domain types, the Connect client) and `ReeveUI` (cross-platform SwiftUI views). The iOS app is the reference client.

```bash
make mac-app-run    # build the package, wrap it in ReeveMac.app, launch
make ios-app-run    # xcodegen, build for the simulator, install, launch
```

`make ios-app-run` defaults to the `iPhone 17 Pro` simulator; override with `IOS_SIMULATOR='iPhone 16'`. On first launch the client asks for the reeved URL (the simulator can hit `http://localhost:8080` directly), probes it, then asks for credentials. To run on a physical device, open `clients/reeved-ios/ReeveiOS.xcodeproj` in Xcode after `make ios-project` and let Xcode sign with a Personal Team.

See [../clients/ios-reference.md](../clients/ios-reference.md) for the client architecture.
