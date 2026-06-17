# Installation

Spalt is one Go server (`spaltd`) and one Postgres database (with the pgvector extension). A second binary, the `spalt` operator CLI, applies migrations, creates users, and mints encryption keys. Both binaries ship in the Docker image and land on `PATH`.

There are three ways to run it, from least to most setup:

1. [Docker Compose](#1-docker-compose-recommended): the server and database together, one command. Recommended for a real deployment.
2. [Docker](#2-docker-single-container): the server container against a Postgres you run yourself.
3. [From source](#3-from-source-go-build): `go build` / `go run`, for development or hosts without Docker.

Every path needs the same two things: an [encryption key](#encryption-key) and a [first user](#first-user). Each walkthrough sets them up inline; the [shared concepts](#shared-concepts) section at the end explains them in depth. For the full environment-variable list see [configuration.md](configuration.md).

## 1. Docker Compose (recommended)

`docker-compose.yml` runs Postgres (pgvector) and spaltd together. It builds the image from the local Dockerfile, waits for the database to pass its healthcheck, and persists both the database and the file-storage volume. spaltd self-migrates on every start, so there is no separate migration step.

```bash
cp .env.example .env
# edit .env: at minimum set POSTGRES_PASSWORD and SPALT_MASTER_KEY.
# generate a key with:
#   openssl rand -base64 32
docker compose -p spalt up -d
docker compose -p spalt exec spaltd spalt useradd -u alice   # prompts for a password
# open http://localhost:8080
```

Configuration is environment-only, read from `.env`:

- `POSTGRES_PASSWORD` is required: the Postgres image refuses to start without it.
- `SPALT_MASTER_KEY` is the at-rest encryption key. The server runs without it but stores provider API keys and plugin secrets in plaintext (see [encryption key](#encryption-key)). Set it before adding any provider.
- Optional: `SPALT_PORT` (host port, default 8080), `SPALT_PUBLIC_BASE_URL` (your public origin when behind a proxy), and `SPALT_BOOTSTRAP_ADMIN_USERNAME` / `SPALT_BOOTSTRAP_ADMIN_PASSWORD` to auto-create an admin on first boot instead of running `useradd`.

The database does not publish a host port (spaltd reaches it over the private compose network). Add a `ports:` mapping to the `db` service only if you want direct `psql` access. The data lives in two named volumes (`db-data`, `spalt-data`); `docker compose -p spalt down` keeps them, `down -v` deletes them.

Common operations:

```bash
docker compose -p spalt logs -f spaltd        # follow server logs
docker compose -p spalt exec spaltd spalt install -status   # migration status
docker compose -p spalt pull && docker compose -p spalt up -d --build   # upgrade
```

## 2. Docker (single container)

The repo's multi-stage Dockerfile builds both binaries into one Alpine image (around 45 MB) that runs as a non-root `spalt` user and exposes 8080. Use this when you already run Postgres elsewhere.

```bash
docker build -t spalt .

docker run -d --name spaltd -p 8080:8080 \
  -e SPALT_DSN='postgres://USER:PASS@host.docker.internal:5432/spalt?sslmode=disable' \
  -e SPALT_MASTER_KEY="$(openssl rand -base64 32)" \
  -e SPALT_BOOTSTRAP_ADMIN_USERNAME=alice \
  -e SPALT_BOOTSTRAP_ADMIN_PASSWORD=changeme \
  spalt
```

The entrypoint runs `spalt install` before starting `spaltd` whenever `SPALT_DSN` is set, so a plain `docker run` creates the pgvector extension, applies migrations, then serves. (It passes the DSN to the CLI explicitly because `spalt install` reads `-db` or `DATABASE_URL`, not `SPALT_DSN`.) For non-`spaltd` commands the entrypoint skips the install step, so `docker run --rm spalt spalt genkey` just runs the CLI.

Operator commands against a running container:

```bash
docker exec -it spaltd spalt useradd -u bob       # add another user
docker exec -it spaltd spalt install -status      # migration status
```

Notes:

- `host.docker.internal` reaches the host's Postgres on macOS and Windows. On Linux use `--network=host` with `localhost`, or point the DSN at the bridge IP.
- The connecting Postgres role needs permission to run `CREATE EXTENSION vector` (the preflight in `spalt install` does this). A superuser or database owner works.
- Mount a volume at `/data` to persist file attachments across container replacements: `-v spalt-data:/data` (the image creates `/data` owned by the runtime user). spaltd writes there by default.
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

Message embeddings use a `vector(768)` column, so the `vector` extension must exist in the target database. `spalt install` runs `CREATE EXTENSION IF NOT EXISTS vector` as a preflight, so a normal install handles it if the connecting role can create extensions. The test harness additionally needs the extension in `template1` (it clones each test DB from there):

```bash
docker exec clark-postgres psql -U clark -d template1 -c "CREATE EXTENSION IF NOT EXISTS vector"
```

### Build, migrate, run

```bash
# build both binaries (or use `go run ./cmd/...` directly)
go build -o spaltd ./cmd/spaltd
go build -o spalt  ./cmd/spalt

# apply the schema (migrations are baked into the binary)
./spalt install -db 'postgres://clark:clark@localhost:5433/clark?sslmode=disable'

# run the server
export SPALT_DSN='postgres://clark:clark@localhost:5433/clark?sslmode=disable'
export SPALT_MASTER_KEY="$(./spalt genkey)"
export SPALT_BOOTSTRAP_ADMIN_USERNAME=alice
export SPALT_BOOTSTRAP_ADMIN_PASSWORD=changeme
./spaltd
# spaltd listening addr=:8080
```

The DSN resolution order for the CLI is the `-db` flag, then `SPALT_DSN`, then `DATABASE_URL`, then the local dev default (`postgres://clark:clark@localhost:5433/clark?sslmode=disable`). Because the dev default matches the container above, `./spalt install` and `make run` work with no flags during development.

Useful make targets for the dev loop:

```bash
make run            # go run ./cmd/spaltd with the dev DSN
make migrate-up     # external goose against db/migrations (for iterating on a new migration)
make migrate-down
make test           # full Go test suite (each DB test gets a fresh migrated database)
```

Unlike the Docker paths, running `spaltd` from source does **not** apply migrations on startup. Run `spalt install` yourself first (the Docker entrypoint is what automates it in those paths).

## Shared concepts

### Encryption key

Spalt encrypts provider credentials and plugin secrets at rest with AES-256-GCM. The key comes from `SPALT_MASTER_KEY`, the base64 encoding of 32 random bytes. Mint one once per environment and keep it safe:

```bash
openssl rand -base64 32        # or: spalt genkey  (or: go run ./cmd/spalt genkey)
```

If the key is unset the server still starts, but it logs a loud warning and writes config blobs in plaintext through a no-op cipher. The key is effectively immutable: once rows are encrypted under it, losing or changing it means losing the ability to read them. Set it before you add any provider. There is a dev-only escape hatch, `SPALT_DEV_AUTOKEY=1`, that mints a throwaway key per process; data written under it is unreadable after a restart. See [encryption.md](../design/encryption.md).

### First user

Spalt always requires auth; there is no single-user bypass and no signup. Get the first account one of two ways.

Bootstrap from env on first run: if no users exist and both `SPALT_BOOTSTRAP_ADMIN_USERNAME` and `SPALT_BOOTSTRAP_ADMIN_PASSWORD` are set, the server creates that admin on startup. If no users exist and those vars are unset, the server still runs but every authenticated RPC rejects until a user exists.

Or create one with the CLI, which writes the row directly and works against a fresh database without a running server (or admin):

```bash
spalt useradd -u alice              # prompts for the password, no echo
spalt useradd -u bob -p hunter2     # password inline
spalt useradd -u guest -no-admin    # regular (non-admin) user
```

`useradd` defaults to creating an admin; pass `-no-admin` for a regular user. In Docker, prefix with `docker compose -p spalt exec spaltd` or `docker exec -it spaltd`.

### Schema migrations

`spalt install` applies the goose migrations baked into the binary. No source tree and no separate goose install is needed. It is the recommended path for any deployment, and the Docker entrypoint runs it automatically before `spaltd`.

```bash
spalt install                 # apply everything (uses DSN resolution above)
spalt install -db <url>       # against a specific database
spalt install -status         # show what is applied, change nothing
spalt install -target 30      # migrate up to a specific version
```

### Configuration

The server reads `SPALT_DSN` (required) and listens on `SPALT_ADDR` (default `:8080`). The full list of environment variables, with defaults and effects, is in [configuration.md](configuration.md).

### Behind a reverse proxy

spaltd serves cleartext HTTP/2 (h2c) and does not terminate TLS. For anything beyond localhost, run it behind a TLS-terminating reverse proxy and set `SPALT_PUBLIC_BASE_URL` to the public origin (for example `https://spalt.example.com`) so signed file URLs resolve. The proxy must support HTTP/2 to the upstream for streaming responses to flow.

## Clients

The macOS and iOS apps share a Swift package, `SpaltSwift`, that ships `SpaltKit` (repositories, view models, domain types, the Connect client) and `SpaltUI` (cross-platform SwiftUI views). The iOS app is the reference client. There is also a server-rendered web client built into spaltd (see [../clients/web.md](../clients/web.md)).

```bash
make mac-app-run    # build the package, wrap it in SpaltMac.app, launch
make ios-app-run    # xcodegen, build for the simulator, install, launch
```

`make ios-app-run` defaults to the `iPhone 17 Pro` simulator; override with `IOS_SIMULATOR='iPhone 16'`. On first launch the client asks for the spaltd URL (the simulator can hit `http://localhost:8080` directly), probes it, then asks for credentials. To run on a physical device, open `clients/spaltd-ios/SpaltiOS.xcodeproj` in Xcode after `make ios-project` and let Xcode sign with a Personal Team.

For the full iOS build-and-run guide (prerequisites, the make targets, device signing, troubleshooting) see [../clients/building-ios.md](../clients/building-ios.md), and [../clients/ios-reference.md](../clients/ios-reference.md) for the client architecture.
