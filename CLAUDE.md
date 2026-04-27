# Clark

Self-hosted AI chat orchestrator. Architecture and design decisions live in [docs/architecture.md](docs/architecture.md) — read it before working in this repo.

**Deferred work — tactical TODOs from in-flight implementation — lives in [docs/todo.md](docs/todo.md).** Update it whenever you defer something or complete an item there. Strategic deferrals (encryption tiers, sharing model, transform pipeline, etc.) live in `architecture.md` under "Open threads"; the todo doc captures the implementation-level loose ends that would otherwise be lost across compactions.

Project planning belongs in this repo (under `docs/`), not in the global Claude memory folder.

## Local dev setup

Tests and the smoke-test database use a dedicated Postgres container `clark-postgres` on port **5433** (kept off 5432 to avoid clashing with other projects):

```bash
docker run -d --name clark-postgres \
  -e POSTGRES_USER=clark -e POSTGRES_PASSWORD=clark -e POSTGRES_DB=clark \
  -p 5433:5432 pgvector/pgvector:pg16
```

Defaults baked into `Makefile` (`GOOSE_DBSTRING`) and `internal/testutil` (pgtestdb config) point at this instance with credentials `clark:clark`. Override via env vars (`PGTESTDB_HOST/PORT/USER/PASSWORD/DB`) if your setup differs.

## Conventions

- **Protos: every RPC has a dedicated request and response message pair.** Never return a domain message (e.g. `Profile`, `Conversation`) directly, and never return `google.protobuf.Empty`. Even no-data responses use `message FooResponse {}`. This preserves wire-compat headroom — fields can be added to any response without breaking the schema.

- **Complete test coverage on everything written.** Unit tests are sufficient (no need for end-to-end suites unless asked). For code that touches Postgres, use [`github.com/peterldowns/pgtestdb`](https://github.com/peterldowns/pgtestdb) — each test gets a fresh, migrated database via the goose migrator. Pure functions get pure unit tests; DB code gets pgtestdb. Don't merge a vertical slice without tests.
