# Installation

Psmith is one Go server (`psmithd`) and one Postgres database (with the pgvector extension). A second binary, the `psmith` operator CLI, applies migrations, creates users, and mints encryption keys. Both binaries ship in the Docker image and land on `PATH`.

There are three ways to run it, from least to most setup:

1. [Docker Compose](#1-docker-compose-recommended): the server and database together, one command. Recommended for a real deployment.
2. [Docker](#2-docker-single-container): the server container against a Postgres you run yourself.
3. [From source](#3-from-source-go-build): `go build` / `go run`, for development or hosts without Docker.

Every path needs the same two things: an [encryption key](#encryption-key) and a [first user](#first-user). Each walkthrough sets them up inline; the [shared concepts](#shared-concepts) section at the end explains them in depth. For the full environment-variable list see [configuration.md](configuration.md).

## 1. Docker Compose (recommended)

`docker-compose.yml` runs Postgres (pgvector) and psmithd together. It builds the image from the local Dockerfile, waits for the database to pass its healthcheck, and persists both the database and the file-storage volume. psmithd self-migrates on every start, so there is no separate migration step.

```bash
cp .env.example .env
# edit .env: at minimum set POSTGRES_PASSWORD and PSMITH_MASTER_KEY.
# generate a key with:
#   openssl rand -base64 32
docker compose -p psmith up -d
docker compose -p psmith exec psmithd psmith useradd -u alice   # prompts for a password
# open http://localhost:8080
```

Configuration is environment-only, read from `.env`:

- `POSTGRES_PASSWORD` is required: the Postgres image refuses to start without it.
- `PSMITH_MASTER_KEY` is the at-rest encryption key. The server runs without it but stores provider API keys and plugin secrets in plaintext (see [encryption key](#encryption-key)). Set it before adding any provider.
- Optional: `PSMITH_PORT` (host port, default 8080), `PSMITH_PUBLIC_BASE_URL` (your public origin when behind a proxy), and `PSMITH_BOOTSTRAP_ADMIN_USERNAME` / `PSMITH_BOOTSTRAP_ADMIN_PASSWORD` to auto-create an admin on first boot instead of running `useradd`.

The database does not publish a host port (psmithd reaches it over the private compose network). Add a `ports:` mapping to the `db` service only if you want direct `psql` access. The data lives in two named volumes (`db-data`, `psmith-data`); `docker compose -p psmith down` keeps them, `down -v` deletes them.

Common operations:

```bash
docker compose -p psmith logs -f psmithd        # follow server logs
docker compose -p psmith exec psmithd psmith install -status   # migration status
docker compose -p psmith pull && docker compose -p psmith up -d --build   # upgrade
```

## 2. Docker (single container)

The repo's multi-stage Dockerfile builds both binaries into one Alpine image (around 45 MB) that runs as a non-root `psmith` user and exposes 8080. Use this when you already run Postgres elsewhere.

```bash
docker build -t psmith .

docker run -d --name psmithd -p 8080:8080 \
  -e PSMITH_DSN='postgres://USER:PASS@host.docker.internal:5432/psmith?sslmode=disable' \
  -e PSMITH_MASTER_KEY="$(openssl rand -base64 32)" \
  -e PSMITH_BOOTSTRAP_ADMIN_USERNAME=alice \
  -e PSMITH_BOOTSTRAP_ADMIN_PASSWORD=changeme \
  psmith
```

The entrypoint runs `psmith install` before starting `psmithd` whenever `PSMITH_DSN` is set, so a plain `docker run` creates the pgvector extension, applies migrations, then serves. (It passes the DSN to the CLI explicitly because `psmith install` reads `-db` or `DATABASE_URL`, not `PSMITH_DSN`.) For non-`psmithd` commands the entrypoint skips the install step, so `docker run --rm psmith psmith genkey` just runs the CLI.

Operator commands against a running container:

```bash
docker exec -it psmithd psmith useradd -u bob       # add another user
docker exec -it psmithd psmith install -status      # migration status
```

Notes:

- `host.docker.internal` reaches the host's Postgres on macOS and Windows. On Linux use `--network=host` with `localhost`, or point the DSN at the bridge IP.
- The connecting Postgres role needs permission to run `CREATE EXTENSION vector` (the preflight in `psmith install` does this). A superuser or database owner works.
- Mount a volume at `/data` to persist file attachments across container replacements: `-v psmith-data:/data` (the image creates `/data` owned by the runtime user). psmithd writes there by default.
- `GET /healthz` returns `{"ok":true}` with no auth and no database hit. Use it for orchestrator liveness probes.

## 3. From source (`go build`)

For development, or a host where you would rather not run the server in Docker. You still need a Postgres with pgvector somewhere; the quickest is a container.

### Prerequisites

- Go 1.25 (the go.mod toolchain pins the version).
- Postgres 14 or newer with the pgvector extension available.
- Only if you regenerate code: `buf` and `sqlc`. Only for the dev migration loop: `goose`.

### Postgres

The `Makefile` and the test harness default to a Postgres on port 5433 with credentials `clark:clark` and database `clark`. The port is off 5432 to avoid clashing with other local databases; the `clark` naming predates the project rename and is kept for the dev container and credentials only.

```bash
docker run -d --name clark-postgres \
  -e POSTGRES_USER=clark -e POSTGRES_PASSWORD=clark -e POSTGRES_DB=clark \
  -p 5433:5432 pgvector/pgvector:pg18
```

Message embeddings use a `vector(768)` column, so the `vector` extension must exist in the target database. `psmith install` runs `CREATE EXTENSION IF NOT EXISTS vector` as a preflight, so a normal install handles it if the connecting role can create extensions. The test harness additionally needs the extension in `template1` (it clones each test DB from there):

```bash
docker exec clark-postgres psql -U clark -d template1 -c "CREATE EXTENSION IF NOT EXISTS vector"
```

### Build, migrate, run

```bash
# build both binaries (or use `go run ./cmd/...` directly)
go build -o psmithd ./cmd/psmithd
go build -o psmith  ./cmd/psmith

# apply the schema (migrations are baked into the binary)
./psmith install -db 'postgres://clark:clark@localhost:5433/clark?sslmode=disable'

# run the server
export PSMITH_DSN='postgres://clark:clark@localhost:5433/clark?sslmode=disable'
export PSMITH_MASTER_KEY="$(./psmith genkey)"
export PSMITH_BOOTSTRAP_ADMIN_USERNAME=alice
export PSMITH_BOOTSTRAP_ADMIN_PASSWORD=changeme
./psmithd
# psmithd listening addr=:8080
```

The DSN resolution order for the CLI is the `-db` flag, then `PSMITH_DSN`, then `DATABASE_URL`, then the local dev default (`postgres://clark:clark@localhost:5433/clark?sslmode=disable`). Because the dev default matches the container above, `./psmith install` and `make run` work with no flags during development.

Useful make targets for the dev loop:

```bash
make run            # go run ./cmd/psmithd with the dev DSN
make migrate-up     # external goose against db/migrations (for iterating on a new migration)
make migrate-down
make test           # full Go test suite (each DB test gets a fresh migrated database)
```

Unlike the Docker paths, running `psmithd` from source does **not** apply migrations on startup. Run `psmith install` yourself first (the Docker entrypoint is what automates it in those paths).

## Shared concepts

### Encryption key

Psmith encrypts provider credentials and plugin secrets at rest with AES-256-GCM. The key comes from `PSMITH_MASTER_KEY`, the base64 encoding of 32 random bytes. Mint one once per environment and keep it safe:

```bash
openssl rand -base64 32        # or: psmith genkey  (or: go run ./cmd/psmith genkey)
```

If the key is unset the server still starts, but it logs a loud warning and writes config blobs in plaintext through a no-op cipher. The key is effectively immutable: once rows are encrypted under it, losing or changing it means losing the ability to read them. Set it before you add any provider. There is a dev-only escape hatch, `PSMITH_DEV_AUTOKEY=1`, that mints a throwaway key per process; data written under it is unreadable after a restart. See [encryption.md](../design/encryption.md).

### First user

Psmith always requires auth; there is no single-user bypass and no signup. Get the first account one of two ways.

Bootstrap from env on first run: if no users exist and both `PSMITH_BOOTSTRAP_ADMIN_USERNAME` and `PSMITH_BOOTSTRAP_ADMIN_PASSWORD` are set, the server creates that admin on startup. If no users exist and those vars are unset, the server still runs but every authenticated RPC rejects until a user exists.

Or create one with the CLI, which writes the row directly and works against a fresh database without a running server (or admin):

```bash
psmith useradd -u alice              # prompts for the password, no echo
psmith useradd -u bob -p hunter2     # password inline
psmith useradd -u guest -no-admin    # regular (non-admin) user
```

`useradd` defaults to creating an admin; pass `-no-admin` for a regular user. In Docker, prefix with `docker compose -p psmith exec psmithd` or `docker exec -it psmithd`.

### Schema migrations

`psmith install` applies the goose migrations baked into the binary. No source tree and no separate goose install is needed. It is the recommended path for any deployment, and the Docker entrypoint runs it automatically before `psmithd`.

```bash
psmith install                 # apply everything (uses DSN resolution above)
psmith install -db <url>       # against a specific database
psmith install -status         # show what is applied, change nothing
psmith install -target 30      # migrate up to a specific version
```

### Configuration

The server reads `PSMITH_DSN` (required) and listens on `PSMITH_ADDR` (default `:8080`). The full list of environment variables, with defaults and effects, is in [configuration.md](configuration.md).

### Behind a reverse proxy

psmithd serves cleartext HTTP/2 (h2c) and does not terminate TLS. For anything beyond localhost, run it behind a TLS-terminating reverse proxy and set `PSMITH_PUBLIC_BASE_URL` to the public origin (for example `https://psmith.example.com`) so signed file URLs resolve. The proxy must support HTTP/2 to the upstream for streaming responses to flow.

## Clients

The macOS and iOS apps share a Swift package, `PsmithSwift`, that ships `PsmithKit` (repositories, view models, domain types, the Connect client) and `PsmithUI` (cross-platform SwiftUI views). The iOS app is the reference client. There is also a server-rendered web client built into psmithd (see [../clients/web.md](../clients/web.md)).

```bash
make mac-app-run    # build the package, wrap it in PsmithMac.app, launch
make ios-app-run    # xcodegen, build for the simulator, install, launch
```

`make ios-app-run` defaults to the `iPhone 17 Pro` simulator; override with `IOS_SIMULATOR='iPhone 16'`. On first launch the client asks for the psmithd URL (the simulator can hit `http://localhost:8080` directly), probes it, then asks for credentials. To run on a physical device, open `clients/psmithd-ios/PsmithiOS.xcodeproj` in Xcode after `make ios-project` and let Xcode sign with a Personal Team.

For the full iOS build-and-run guide (prerequisites, the make targets, device signing, troubleshooting) see [../clients/building-ios.md](../clients/building-ios.md), and [../clients/ios-reference.md](../clients/ios-reference.md) for the client architecture.
