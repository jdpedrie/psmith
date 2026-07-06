# Building, codegen, and tests

This document covers building the binaries, regenerating the protobuf and SQL bindings, and the test layers. The entry points are the `Makefile` targets.

## Building

```bash
make build    # go build -o bin/psmithd ./cmd/psmithd
make run      # go run ./cmd/psmithd
```

The operator CLI builds with `go build ./cmd/psmith`. The Docker image builds both binaries with `CGO_ENABLED=0`, `-trimpath`, and stripped symbols. See [installation.md](installation.md) for the Docker flow.

## Code generation

Two generators produce code that is checked in. Regenerate after changing a `.proto` or a `.sql` query.

### Protobuf to Go and Swift

```bash
make proto    # buf generate
```

`buf.gen.yaml` runs four remote plugins:

- `protocolbuffers/go` and `connectrpc/go` write Go into `gen/` with `paths=source_relative`. The Go import path is `gen/psmith/v1` (package `psmithv1`) and `gen/psmith/v1/psmithv1connect` for the service stubs.
- `apple/swift` and `connectrpc/swift` write Swift into `clients/PsmithSwift/Sources/PsmithKit/Generated` with public visibility, async methods on, and callback methods off.

`buf.yaml` sets the module root at `proto`, lint level STANDARD, breaking-change detection at FILE level. The protos live under `proto/psmith/v1/`.

### SQL to Go

```bash
make sqlc     # sqlc generate
```

`sqlc.yaml` reads queries from `db/queries`, the schema from `db/migrations`, and writes the `store` package into `internal/store`. It uses `pgx/v5`, emits pointers for nullable types, and emits a `Querier` interface. Type overrides map `uuid` to `github.com/google/uuid.UUID`, `timestamptz` to `time.Time`, and `vector` to `github.com/pgvector/pgvector-go.Vector` (pointer when nullable, so an unembedded row surfaces as `nil`).

### Lint

```bash
make lint     # buf lint + go vet ./...
make tidy     # go mod tidy
```

## Tests

### Go

```bash
make test     # go test ./...
```

Pure functions get plain unit tests. Anything that touches Postgres uses `pgtestdb` through `internal/testutil.Pool(t)`, which hands each test a fresh, fully migrated database cloned from `template1`. The `vector` extension must be present in `template1` (see [installation.md](installation.md)); without it every migrated test database fails at migration 00034.

Override the test database connection with the `PGTESTDB_*` variables in [configuration.md](configuration.md).

### The fake LLM

`fakellm` (under `fakellm/`) is an `httptest.Server` that speaks the three upstream wire formats: Anthropic Messages, OpenAI Chat Completions, and OpenAI Responses. Tests enqueue scripted completions, point a driver's base URL at `fake.URL()`, and exercise the real SDK, driver, supervisor, and database path without reaching a real provider. This is how the streaming, retry, and tool-loop tests run deterministically. It is the right tool when a test needs the wire parsing to actually happen rather than a stubbed driver. The full reference (the script model, the server API, the flavor differences, and the gotchas) is in [fakellm.md](fakellm.md).

### Swift

```bash
make swift-test           # L1 + L2
make swift-test-l1        # PsmithKit integration tests
make swift-test-l2        # PsmithMac SwiftUI snapshot tests
make swift-test-l2-record # re-baseline snapshots after intentional UI changes
```

Two layers, described in full in `testing-plan.md`:

- L1 drives every public Repository and ViewModel method against a freshly spawned `psmithd` subprocess on an ephemeral port with its own database. It is a real client-to-server integration test.
- L2 renders load-bearing SwiftUI views against committed PNG baselines.

The project convention, enforced in `CLAUDE.md`, is that a backend change ships with tests and a Swift change ships with the matching L1 or L2 coverage.

## App build and run targets

```bash
make mac-build        # build the Swift package for macOS
make mac-app          # build and wrap in PsmithMac.app
make mac-app-run      # build, wrap, launch
make ios-project      # xcodegen the Xcode project from project.yml
make ios-build        # build the iOS app for the simulator
make ios-app-run      # xcodegen, build, install, launch on the simulator
```

The iOS Xcode project is generated; `clients/psmithd-ios/project.yml` is the source of truth, not the `.xcodeproj`. The provider-logo SVGs are converted to PNGs during the iOS build because iOS cannot decode raw SVG bytes from arbitrary file URLs.

For the iOS app specifically (prerequisites, the simulator loop, running on a physical device, signing, and troubleshooting) see [../clients/building-ios.md](../clients/building-ios.md).
