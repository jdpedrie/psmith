# Configuration

Spalt is configured entirely through environment variables. There is no config file. This document lists every variable the code reads, what it controls, and its default.

Per-user settings (provider credentials, embedder config, Langfuse keys, plugin secrets) are not env vars. They live in the database, set through the API, and are encrypted at rest. Env vars configure the process, not the user.

## Server variables (`spaltd`)

| Variable | Default | Required | What it controls |
|---|---|---|---|
| `SPALT_DSN` | none | yes | Postgres connection string, passed straight to the pool. The server exits if it is empty. |
| `SPALT_ADDR` | `:8080` | no | HTTP listen address. `host:port` or `:port`. |
| `SPALT_MASTER_KEY` | none | no (strongly recommended) | base64 of exactly 32 bytes. The AES-256-GCM key for at-rest secret encryption and the seed for the file-URL HMAC signing key. Unset means a no-op cipher and plaintext config, with a loud warning. A malformed value (bad base64 or wrong length) is a hard error. |
| `SPALT_DEV_AUTOKEY` | none | no | Set to `1` to mint an ephemeral 32-byte key per process. Dev convenience only; data written under it cannot be read after a restart. Ignored when `SPALT_MASTER_KEY` is set. |
| `SPALT_BOOTSTRAP_ADMIN_USERNAME` | none | no | First-run admin username. Acts only when zero users exist. |
| `SPALT_BOOTSTRAP_ADMIN_PASSWORD` | none | no | First-run admin password (bcrypt-hashed). Both username and password must be set for bootstrap to fire. |
| `SPALT_DATA_DIR` | `spaltd-data` (relative to the working directory) | no | Root for file storage. A `files/` subdirectory is created at mode 0700 on boot. |
| `SPALT_PUBLIC_BASE_URL` | empty | no | Base URL prepended to the signed `/files/{id}` URLs the server hands back. Empty means the client prepends its own base. |
| `SPALT_EMBEDDER` | none | no | Name of a server-wide fallback embedder used when a user has no embedder config. Only `openai` is registered (an OpenAI-compatible driver that also covers Ollama-style endpoints). |
| `SPALT_EMBEDDER_CONFIG` | none | no | JSON config for the fallback embedder named by `SPALT_EMBEDDER`. Read only when that is set. |
| `SPALT_DEBUG_GEMINI_REQUEST` | none | no | Any non-empty value dumps the outgoing Gemini request for debugging. |

### Things that look like config but are not

- There is no `SPALT_CATALOG_REFRESH_INTERVAL`. The model catalog is in-memory and lazy. It fetches models.dev once on first lookup and refreshes only on the admin `RefreshModelCatalog` RPC. There is no periodic refresh.
- There is no log-level variable. The server uses the default structured logger throughout.
- `SPALT_TZ` appears only in a Dockerfile comment. No code reads it. Timezone for grounding is a per-plugin config field, not an env var.

## Operator CLI variables (`spalt`)

The CLI (`install`, `useradd`) resolves the database in this order: the `-db` flag, then `SPALT_DSN`, then `DATABASE_URL`, then the local dev default `postgres://clark:clark@localhost:5433/clark?sslmode=disable`.

| Variable | Used by | Notes |
|---|---|---|
| `SPALT_DSN` | `install`, `useradd` | Primary DSN source after the `-db` flag. |
| `DATABASE_URL` | `install`, `useradd` | Fallback DSN if `SPALT_DSN` is unset. |
| `SPALT_MASTER_KEY` | the one-off secret-backfill script | The script refuses to run under an ephemeral dev key. |

## Migration variables (dev loop)

`make migrate-up` and `make migrate-down` pass these to the external `goose` CLI. They are not read by the server or by `spalt install`.

| Variable | Default |
|---|---|
| `GOOSE_DRIVER` | `postgres` |
| `GOOSE_DBSTRING` | `postgres://clark:clark@localhost:5433/clark?sslmode=disable` |
| `GOOSE_MIGRATION_DIR` | `db/migrations` |

## Test variables

The Go test harness uses `pgtestdb`, which clones a fresh database per test. Override the connection with these (defaults match the dev container):

| Variable | Default |
|---|---|
| `PGTESTDB_HOST` | `localhost` |
| `PGTESTDB_PORT` | `5433` |
| `PGTESTDB_USER` | `clark` |
| `PGTESTDB_PASSWORD` | `clark` |
| `PGTESTDB_DB` | `clark` |

## A note on TLS

The server speaks cleartext HTTP/2 (h2c) and does not terminate TLS. There is no TLS-related env var because TLS is a fronting-proxy concern. For any deployment beyond localhost, terminate TLS at a reverse proxy and forward to `SPALT_ADDR`.
