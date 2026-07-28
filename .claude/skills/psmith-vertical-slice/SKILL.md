---
name: psmith-vertical-slice
description: "Walk a single feature through every layer Psmith has, in dependency order, with the tests CLAUDE.md requires at each layer. Use when shipping a feature that spans proto, database, Go service, RPC handler, PsmithKit, and both SwiftUI clients."
trigger: /psmith-vertical-slice
---

# /psmith-vertical-slice

Walks one feature through every layer, in dependency order, with the tests
CLAUDE.md requires at each. The point is to never merge a half-slice: backend
without UI, UI without tests.

## Usage

```
/psmith-vertical-slice <feature-description>
```

E.g. `/psmith-vertical-slice add a "pin conversation" toggle that surfaces pinned conversations at the top of the list`.

## Layer order and the gates between

```
1. proto/psmith/v1/*.proto        gate: make proto succeeds
2. db/migrations/ + sqlc          gate: make migrate-up + make sqlc succeed
3. server/<package>/*.go          gate: make test (pgtestdb) green
4. cmd/psmithd RPC handler        gate: smoke via grpcurl
5. PsmithKit Repository method    gate: make swift-test-l1 green
6. PsmithKit ViewModel update     gate: make swift-test-l1 green
7. PsmithMac SwiftUI view         gate: make swift-test-l2 + manual mac-app-run
8. PsmithiOS SwiftUI view         gate: manual ios-app-run
```

Don't skip a gate. If layer 3 isn't green, layer 5 papers over the bug with a
Swift-side workaround you will regret.

## Layer 1 — Proto

```proto
// proto/psmith/v1/<service>.proto
rpc DoTheThing(DoTheThingRequest) returns (DoTheThingResponse);

message DoTheThingRequest { string id = 1; bool toggle = 2; }
message DoTheThingResponse {}  // ALWAYS named, even when empty
```

CLAUDE.md hard rule: **every RPC gets a dedicated request and response message
pair.** Never `google.protobuf.Empty`, never a bare domain message. It preserves
wire-compat headroom, so any response can grow a field later without a schema
break.

```bash
make proto    # regenerates Go + Swift bindings
```

## Layer 2 — Database

Only if storage changes.

```bash
# 00NNN, incrementing from the highest in db/migrations/
goose create <description> sql
# edit with -- +goose Up / -- +goose Down
make migrate-up
# add or change queries in db/queries/*.sql
make sqlc      # regenerates server/store/
```

`server/store/` is generated. Never hand-edit it; edit `db/queries/*.sql` and
regenerate, or your change vanishes the next time anyone runs `make sqlc`.

## Layer 3 — Go service

The bulk of the coverage lives here. `pgtestdb` for anything touching Postgres:
each test gets a fresh migrated database, no fixture pollution. Stdlib
`testing`; the repo does not use testify.

```go
func TestDoTheThing_Toggle(t *testing.T) {
	db := testutil.NewDB(t)
	svc := NewService(db, ...)
	if err := svc.DoTheThing(ctx, "convo-id", true); err != nil {
		t.Fatalf("DoTheThing: %v", err)
	}
	// assert DB state
}
```

Pass `context.Context` down the call chain. Only the top-level entry point
creates one.

```bash
make test
```

## Layer 4 — RPC handler

```go
func (h *Handler) DoTheThing(ctx context.Context, req *connect.Request[v1.DoTheThingRequest]) (*connect.Response[v1.DoTheThingResponse], error) {
	user := auth.UserFromContext(ctx)
	if err := h.svc.DoTheThing(ctx, req.Msg.Id, req.Msg.Toggle); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&v1.DoTheThingResponse{}), nil
}
```

Smoke it with `make run` plus a `grpcurl` call before touching Swift.

## Layer 5 — PsmithKit Repository

`clients/PsmithSwift/Sources/PsmithKit/Repository/<Name>Repository.swift`.
Wraps the generated ConnectRPC client and converts proto types to domain types.

```swift
public func doTheThing(id: String, toggle: Bool) async throws {
	let req = Psmith_V1_DoTheThingRequest.with {
		$0.id = id
		$0.toggle = toggle
	}
	_ = try await client.doTheThing(req)
}
```

Note which transport the service uses. `PsmithClient` holds two: unary RPCs get
a short timeout, streaming ones get 600s to sit above the server's 60s idle
timeout. Routing is by whether the generated service exposes
`AsyncStreamInterface`. Putting a unary call on the streaming transport means a
dead server hangs for ten minutes instead of failing.

Then the L1 integration test in `clients/PsmithSwift/Tests/PsmithKitTests/`,
driven against a fresh local psmithd:

```swift
func testDoTheThing() async throws {
	let server = try await TestPsmithdServer.spawn()
	defer { Task { await server.shutdown() } }
	let client = try await server.authenticated()
	try await client.<repo>.doTheThing(id: "...", toggle: true)
}
```

```bash
make swift-test-l1
```

## Layer 6 — ViewModel

Add the action to the relevant `@Observable @MainActor final class`. Update
in-memory state optimistically OR refetch. Pick one and say why in a comment.

Non-UI code belongs in PsmithSwift, not in an app target, so iOS can reuse it.

## Layer 7 — Mac UI

`clients/psmithd-mac/PsmithMac/`. If the view has no AppKit-specific parts, put
it in `clients/PsmithSwift/Sources/PsmithUI/Composite/` instead so iOS reuses
it. `/psmith-mirror-screen` covers the extraction pattern.

Add an L2 snapshot test for any non-trivial state:

```bash
make swift-test-l2-record   # baseline the new view
make swift-test-l2          # assert no diff
```

Verify by eye with `make mac-app-run`. Snapshots catch layout regressions; only
a person catches "this button is in the wrong place semantically".

`make mac-app-run` pipes through `tail` and swallows compile errors. When
something looks wrong, run `swift build` in `clients/psmithd-mac` directly. After
a change to a public PsmithKit type, wipe `clients/psmithd-mac/.build` first, or
the incremental cache produces a broken binary.

## Layer 8 — iOS UI

`clients/psmithd-ios/PsmithiOS/`. If layer 7 put the view in PsmithUI, this is
`import PsmithUI` plus thin SwiftUI binding. Otherwise mirror the Mac shape with
iOS idioms: NavigationStack over NavigationSplitView, sheet over popover, `.menu`
Picker over `.segmented`.

iOS is the daily driver. It gets the same care as Mac, not less.

```bash
make ios-app-run
```

## Final verification

```bash
make test           # Go
make swift-test     # L1 + L2
make mac-app-run    # eyeball
make ios-app-run    # eyeball
```

Then update the docs under `docs/` that this slice touched, and commit. A task
isn't done if the docs no longer match.

## Don't

- Don't merge a slice without tests at every layer.
- Don't add an RPC returning a domain message or `google.protobuf.Empty`.
- Don't skip the iOS layer because Mac works. Cheaper not to create the gap than to close it later.
- Don't put view-model logic in views. The `@Observable` models exist so views stay declarative and logic stays testable.
- Don't add a `Co-Authored-By` trailer or any AI attribution to the commit.
