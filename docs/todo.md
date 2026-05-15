# Reeve — deferred work

Master list of known-deferred items. Update as new deferrals are introduced and as items get done. Cross-references go to the relevant package or doc section.

The architecture doc's "Open threads" section captures the *strategic* deferrals (encryption, sharing model, transform pipeline, vision/files, tool use). This doc is the *tactical* version: in-flight TODOs left during implementation, plus a priority view of what's missing from the main system.

---

## Main system priorities — what's not done yet

Ordered by impact on getting Reeve to a "useful for sustained personal chat" state. Refer to the categorized sections below for implementation detail.

### Critical — long-running usage breaks without these

1. ~~**`ConversationsService.Compact`**~~ ✅ **Done.** User-triggered compression. Resolves compression model + guide + mode from the profile inheritance chain, builds a transcript prompt, hands to driver + supervisor. Supervisor's `PurposeCompression` terminal handler dual-writes a `role=compression_summary` message in the OLD context (with usage/cost) plus a new Context with a `role=context` message containing the calculated REPLACE/APPEND content. History-builder skips `role=compression_summary`. Migration 00002 added the new role to the CHECK constraint. Smoke-tested end-to-end against the local model.
2. ~~**`ConversationsService.CountContextTokens`**~~ ✅ **Done.** Builds the wire prefix via `history.Build`, calls driver's `TokenCounter`. Returns `Unimplemented` for drivers without a TokenCounter (currently the openai-compatible driver — Anthropic has it). Response includes `context_window` from the user_model snapshot so the UI gets token_count + window in one round trip. Client-side advisory ("approaching limit") happens by the UI comparing the two — no server-side threshold.
3. ~~**Token usage + cost recording**~~ ✅ **Done.** `messages` carries reported `input/output/cache_read/cache_write/reasoning_tokens` + raw provider blob, plus computed `input/output/cache_read/cache_write/total_cost_usd` from the `user_models` pricing snapshot. Both Anthropic + OpenAI drivers emit `ChunkUsage`; supervisor computes costs at materialization using the user_model pricing snapshot. Compression runs record usage/cost on the `compression_summary` message row.

### Architecture-flagship features not yet built

4. ~~**Branch navigation: per-context `current_leaf_message_id`**~~ ✅ **Done.** Migration 00003 added `current_leaf_message_id UUID REFERENCES messages(id) ON DELETE SET NULL` on `contexts`. `SendMessage` parent resolution now: explicit > cursor > latest-by-created_at; cursor advances on user-message insert AND on assistant materialization. New `ConversationsService.SetCurrentLeaf(context_id, message_id)` RPC validates that the message belongs to the context (empty `message_id` clears). `ListMessageAncestorChain` now returns `sibling_count` (count of OTHER messages sharing this row's parent) via subquery in the recursive CTE, surfaced as `Message.sibling_count` for fork indicators. `Context.current_leaf_message_id` exposed on the proto. Tests cover all three resolution branches, cursor advancement, fork indicators, and SetCurrentLeaf cross-context / cross-user / not-found / clear cases.

5. ~~**Transform pipeline**~~ ✅ **Reframed and shipped as Chat Plugins.** See [internal/plugins/](../internal/plugins/) and the "Chat plugins" section in [architecture.md](architecture.md). MVP cut wired end-to-end: required `Plugin` interface + opt-in sub-interfaces (`SystemPrompter`, `OutgoingUserTransformer`, `HistoryTransformer`, `ChunkTransformer`, `DisplayTransformer`, `ToolProvider`, `Configurable`); migration `00004_profile_plugins.sql` with all-or-nothing parent-chain inheritance; pipeline resolved per-conversation in `conversations.Service`; `SystemPrompter` + `HistoryTransformer` plumbed through `history.Build`; `DisplayTransformer` populates `Message.display_content` in `ListMessages` / `GetMessage` / `SendMessage`; first concrete plugin `lettered_choices` exercises four sub-interfaces (Configurable + SystemPrompter + HistoryTransformer + DisplayTransformer). `HistoryTransformer` receives a `HistoryPos{FromHead, FromHeadSameRole}` so role-aware policies ("keep last N assistant turns") are robust under forks. Not yet wired: `ChunkTransformer` (no driver yet needs one), `OutgoingUserTransformer` (interface exists, no concrete plugin), `ToolProvider` (blocked on tool-use end-to-end execution — still in Open Threads), and the empirical cache-observability mechanism (specced in architecture, not yet implemented).

6. **Stateful harness drivers (Claude Code, Codex, pi.dev)** — entirely missing. Two parts: (a) per-harness Layer-1 implementations (subprocess management, NDJSON event parsing, session lifecycle), (b) Layer-2 abstraction + the stateful-send code path in `SendMessage` (currently only handles `StatelessProvider`). Architecture treats these as first-class; was a stated original motivator (mixing cloud APIs with local agentic CLIs). Detailed phasing + per-harness cheat sheet + data model + UX in [`harness-plan.md`](harness-plan.md).

### Real bugs in shipped code

5. ~~**Stream supervisor concurrent-subscriber race**~~ ✅ **Done.** Added `fanoutCursor int64` to `runState` (highest sequence ever fanned out, updated under broker mutex). Subscribe restructured to do replay+register atomically under the broker lock, with the DB read clamped to `[fromSequence, fanoutCursor]`. While the lock is held the broker can't advance the cursor, so chunks delivered via replay-from-DB never overlap with chunks delivered via live fan-out. Confirmed stable across 20× runs of `TestSubscribe_TwoConcurrent_BothReceiveAll` (previously flaked ~25%). Trade-off: broker fan-out blocks for the duration of one new-subscriber's replay DB read; in practice that's a fast index range scan on `(stream_run_id, sequence)`.

### Untested-but-probably-works (cheap verifications) — ✅ Done

6. ~~**Multi-turn conversations**~~ ✅ Tests in [internal/conversations/service_multi_turn_test.go](../internal/conversations/service_multi_turn_test.go): parent-chain correctness across 3 turns, empty assistant content, long stream, and a documented concurrent-sends race (see "Known issues" below).
7. ~~**Forking**~~ ✅ Tests in [internal/conversations/service_fork_test.go](../internal/conversations/service_fork_test.go): fork from deep ancestor, fork from system message, fork from assistant (regenerate pattern), reject cross-context parent, parent-not-found, two forks off same parent (sibling_count), fork to a different model (cross-model history.Build).
8. ~~**Context reactivation**~~ ✅ Tests in [internal/conversations/service_reactivation_test.go](../internal/conversations/service_reactivation_test.go): send-to-reactivated, preserved-cursor-drives-next-send, idempotent reactivate, cross-user, and reactivation-across-compression (the new context becomes orphaned-but-intact).

### Known issues uncovered by smoke tests

- ~~**Concurrent SendMessage on the same context can produce a chain instead of siblings.**~~ ✅ **Done.** SendMessage's critical section (resolve-parent → insert-user-message → advance-cursor) is now wrapped in a transaction with `SELECT FOR UPDATE` on the contexts row via the new `GetContextByIDForUpdate` query. Concurrent sends on the same context serialize: each TX observes the previous's committed cursor and parents off it. The driver.Send + supervisor.Start (slow HTTP) deliberately stay **outside** the TX so the row lock is held only for ~3 quick DB ops — no possibility of blocking other requests on network I/O, and the supervisor's later `UpdateContextCurrentLeaf` (during materialization) never overlaps with the SendMessage TX. Replacement test `TestMultiTurn_ConcurrentSendsSerialize` runs 5 goroutines × concurrent send and asserts all messages persist with valid parent chains; passes 10/10.

  **UX note:** the deterministic shape is "second send becomes a follow-up to the first" rather than "two siblings under the same parent." This matches the cursor's "tip you're sending from" semantics. If a UI wants the siblings shape (e.g., "press send twice in fast succession" → parallel branches), it should pass `parent_message_id` explicitly.

### Nice-to-have

- `AddManualModel`, `RefreshUserModelMetadata` RPCs. (`UpdateUserModel` shipped for `default_settings` only; metadata-edit fields still TODO.)
- `ListConversations` real pagination.
- **Search conversations and messages.** `ListConversations.title_query` ships a server-side `ILIKE '%q%'` against `conversations.title`. Extend to: full-text search across message content (probably `tsvector` + GIN on `messages.content`), with hits surfacing the matching message snippet alongside the conversation in the sidebar's Search mode. Today the Search pill only matches titles; users with thousands of conversations will need content search too.
- ~~`streamsvc` test coverage.~~ ✅ Tests in [internal/streamsvc/service_test.go](../internal/streamsvc/service_test.go): SubscribeStream (invalid UUID, not found, happy path with chunks+terminal, FromSequence resume, already-terminal DB-replay path), CancelStream (invalid UUID, not found, happy path verifying status flips to "cancelled"), GetStreamRun (invalid UUID, not found, happy path), and pure-function tests for the four wire converters (statusToProto, purposeToProto, chunkTypeToProto, streamRunToProto with full + minimal field sets). 14 tests via real httptest + Connect client. Client-cancel-mid-stream is a useful follow-up but tests Connect/HTTP lifecycle more than streamsvc's contract; left as a note in the file. Also fixed `chunkTypeToProto` to map `providers.ChunkUsage → CHUNK_TYPE_USAGE` (it had been silently dropped to UNSPECIFIED, so subscribers never saw usage chunks on the wire even though they were persisted to `stream_chunks`); the SubscribeStream happy-path test now pushes a usage chunk through the supervisor and asserts it arrives at the subscriber.
- Multi-device per user (per-device key-pair pairing).

---

## iOS streaming reconnection + background story

✅ **Phases 1–3 done.** `StreamHub` lives in `clients/ReeveSwift/Sources/ReeveKit/StreamSubscriber/StreamHub.swift` as an app-lifetime owner of active runs; `ConversationViewModel` reads streaming state through it. Server-side `Streams.ListActiveRuns` (`internal/streamsvc/service.go`, tests in `service_test.go`) lets `AppModel` adopt in-flight runs on launch and lets `ConversationsModel` derive a "generating…" indicator on each `ConversationRow`. Re-entering a mid-generation chat now repaints the streaming bubble immediately.

**Phase 4 (real iOS backgrounding past the ~30s suspend) still deferred** — `beginBackgroundTask` would buy the grace window; APNs silent push is the only path past that and is a non-starter without a hosted APNs story. Document the current behaviour: backgrounding for >30s during generation triggers a brief resubscribe-and-replay on return.

---

## Deferred RPCs (proto contract exists, no implementation yet)

- **`ModelProvidersService.AddManualModel`** — for models not in catalog or driver discovery (local fine-tunes, custom endpoints serving non-listed models). Workaround today: direct `INSERT INTO user_models`. Proto stub: not yet defined; pattern would mirror EnableModels but accept the full UserModel shape.

- **`ModelProvidersService.UpdateUserModel`** — partially shipped. The RPC exists and currently writes only `default_settings` (per-model layer of the CallSettings resolution chain). Letting users hand-edit other snapshotted metadata (context window, display name, etc.) is still TODO — extend `UpdateUserModelRequest` with the additional optional fields and route them through new sqlc queries.

- **`ModelProvidersService.RefreshUserModelMetadata`** — explicit re-snapshot of a UserModel from current catalog. Proto stub: not yet defined.

- **`ConversationsService.Compact`** — proto contract in [proto/reeve/v1/conversations.proto](../proto/reeve/v1/conversations.proto). Not implemented; covered by `UnimplementedConversationsServiceHandler`. Requires: resolve compression model from profile; build full-context prefix; call driver with compression_guide as system; route through supervisor with `PurposeCompression`; **caller-side goroutine** subscribes to the compression run, accumulates summary text, creates a new Context with the summary as a `role=context` message (REPLACE or APPEND per profile); activates new context. Stream supervisor agent intentionally left context-creation to the caller.

- **`ConversationsService.CountContextTokens`** — proto contract exists. Requires: build prefix via history-builder, type-assert driver to `providers.TokenCounter`, call. Anthropic driver has `CountTokens`; OpenAI driver intentionally doesn't (no consistent endpoint across compat servers, no tiktoken helper in `openai-go`). Return `Unimplemented` for drivers that don't satisfy.

---

## Implementation gaps inside shipped code

### Drivers

- **`internal/providers/anthropic`** — tool-use input is one-way: outbound `tool_result` blocks not yet translated from `WireMessage`. `signature_delta` and `citations_delta` events silently dropped (no normalized chunk slot). `MessageDeltaEvent` (usage / stop_reason) not surfaced — needs a chunk type when added.

- **`internal/providers/openai`** — tool use tracks one active call (parallel tool calls would need a map keyed by `output_index`). `TokenCounter` intentionally not implemented (see proto-deferral note above). Thinking round-trip only works when stored shape matches Responses-API `ResponseReasoningItem`; cross-shape thinking silently omitted.

### History builder

- **`internal/history`** — cross-provider thinking is **omitted entirely** when destination ≠ producer. The architecture doc's "Thinking handling" section spec'd "render to plain text and inject into content" for this case. Deferred until tool use lands so we don't have to redo it. Code comment in `history.go` references this.

### Stream supervisor

- **`internal/stream`** — `PurposeCompression` runs persist chunks and finalize WITHOUT materializing a message; the future Compact handler must subscribe to the run and create the new context itself. Documented in `stream.go`. Slow-subscriber back-pressure: drops the subscriber (closes their channel) when the 64-chunk buffer fills — they can resubscribe with `lastSeen+1`. No replay tests cover the gap-fill race between DB replay and broker registration explicitly (covered implicitly by live-tail tests).

- **`internal/stream` flaky test: `TestSubscribe_TwoConcurrent_BothReceiveAll`** — fails ~20-30% of runs with subscriber receiving MORE chunks than emitted (duplicates, not loss). Suggests the gap-fill DB read after broker registration overlaps with live-broker delivery, causing chunks to be delivered both via replay and via live-tail. Single-subscriber paths work fine (SendMessage end-to-end verified). Concurrent multi-subscriber not yet exercised in production code, but should be fixed before relying on it. Likely fix area: tighten the handoff between "last replayed sequence" and "first live-broker sequence" so the broker only forwards chunks strictly after the cursor.

### Conversations / SendMessage

- **Stateful provider sends not wired in `SendMessage`** — currently `SendMessage` requires the driver to satisfy `providers.StatelessProvider`; harness providers (when they exist) need a separate code path that calls `StartSession` / `SendInSession`.

- **`internal/conversations` `var _ = time.Now`** in service.go is a leftover safety-net for an import that's now genuinely used. Cleanup nit; harmless.

### Drivers not yet built

- **`claude-code-subprocess` driver** — package doesn't exist. Stateful provider; would manage a `claude` CLI process per session, talk to it via NDJSON over stdio, expose the `--list-models` (or hardcoded) catalog. Community reference: `severity1/claude-agent-sdk-go`.
- **`codex-subprocess` driver** — package doesn't exist. Same shape as above; talks to Codex CLI via JSON-RPC over stdio. Community reference: `hishamkaram/codex-agent-sdk-go`.

### Subsystems not yet built

- **`internal/transforms`** — package doesn't exist. Architecture spec'd outbound (full-message) and inbound (stream-processor) transforms with stable/non-stable flags, raw-vs-transformed storage, scope rules (global / per-provider / per-model / per-message-tag), explicit ordering. Tied to a "Transform-configuration schema" question (still open: where do transforms attach — profile, provider, conversation, or all of the above).

---

## Test gaps

- **`internal/streamsvc`** — no tests yet. Thin shim over supervisor; should at least cover SubscribeStream success/error paths, CancelStream, GetStreamRun, and `ErrNotFound` mapping.
- **End-to-end multi-turn** — single smoke test of one user → assistant turn done. Multi-turn (user → assistant → user → assistant), forking (`SendMessage` with `parent_message_id` pointing at a non-leaf), and context reactivation flows not yet smoke-tested.

---

## Strategic deferrals (also in architecture.md "Open threads")

Recorded here for grep-ability; the canonical discussion is in [architecture.md](architecture.md):

- **Tool use** as a first-class feature, plus its structural coupling with thinking on Anthropic.
- **Vision / file attachments** in `WireMessage`.
- **Transform-configuration schema** (where transforms attach: profile, provider instance, conversation, or combination). Inbound and outbound transform pipelines not yet built — the architecture is specified but no `internal/transforms` package exists.
- **Resource sharing model** — v1 is per-user-only. Add `visibility = {private, shared}` on `user_model_providers` when a second user actually exists.
- **Encryption** — Tier A (column at rest) and Tier B (per-user keys) sketched in architecture.md "Encryption (deferred)" section.

---

## Smaller items

- **Connect server-streaming via raw curl** doesn't pretty-print — Connect's wire format isn't plain newline-delimited JSON. For terminal smoke testing, write a small `clarkctl` helper or use `buf curl` to subscribe to streams.
- **`REEVE_CATALOG_REFRESH_INTERVAL` smoke-tested only at "0" (disabled).** Periodic refresh path not exercised in tests.
- **`ListConversations` pagination** — `page_size` capped at 100, `page_token` ignored (returns all in one page). Real pagination deferred.
- **`ListProviderTypes` `display_name`** — currently humanized via `humanizeName`. Could come from driver metadata if drivers exposed a `DisplayName()` method.
- **`ListProviderTypes` `config_schema`** — empty bytes for v1; UI hardcodes config forms. JSON Schema generation per-driver is a future ergonomic win.
- **Unit-tested `internal/store` queries** — no direct tests of the sqlc-generated layer (covered transitively by every service test).

- ~~**`stream_chunks` are never pruned.**~~ ✅ **Done.** New background goroutine `internal/stream/cleanup.StartChunkCleanup` started from `cmd/reeved/main.go`. Sweeps every 10 minutes via `PruneFinalizedStreamChunks`, deleting chunks whose `stream_run.ended_at` is more than 1h in the past (configurable via `CleanupConfig`). Single goroutine on a timer (per-run `time.AfterFunc` was the alternative; rejected because it doesn't survive server restarts and would re-leak chunks orphaned by mid-finalization crashes). Tests cover finalized-runs-pruned, retention-window-protects-fresh-runs, and graceful-shutdown-on-context-cancel.

- ~~**Retry from an errored message.**~~ ✅ **Done.** Errored assistant rows on Mac (`ConversationView.swift::erroredBody`) and iOS (`MessageRow.swift`) now render an inline "Retry" button below the error text + partial-content disclosure; tap fires `reloadFromMessage(id:)` which forks off the same parent (existing regenerate-mode SendMessage path). Errored `compression_summary` rows in the shared `CompressionSummaryCard` render Retry alongside Dismiss; tap fires `compact()` with the current profile defaults — the failed summary stays visible in history until dismissed so the user can read the error. No new RPCs needed; `reloadFromMessage` and `compact()` already do the right thing. **Open follow-up:** for compaction retry the user can't override the model from the inline button — they have to dismiss and use the Compact page. Acceptable for v1; revisit if users hit it.

- **Apple Foundation Models on-device titler.** Migration 00013 + protobuf `title_provider_kind` field + sentinel `"apple_foundation"` ship the structural pieces. Mac client (`clients/reeved-mac/ReeveMac/AppleFoundationTitler.swift`) wraps `LanguageModelSession`. `ConversationViewModel.maybeGenerateLocalTitle` fires after the first assistant turn lands when the resolved profile has the kind set, then persists via the existing `UpdateConversation` RPC. Server-side hook (`internal/conversations/titles.go`) skips its cloud call when the kind sentinel resolves. **Open follow-ups:** (a) extend `LocalTitler` with iOS-side implementation when an iOS app exists; (b) consider falling back to the configured cloud title model when `AppleFoundationTitler.isAvailable` returns false (today the kind sentinel is "all-or-nothing"); (c) the trigger uses the local cached profile map for parent-chain resolution — if the profile cache is empty it skips silently, which is fine for the Mac startup flow but worth flagging.

- **Anthropic SDK upgrade for native `ttl` field.** The `AnthropicExtras.cache_ttl` follow-up shipped the 1-hour TTL via the SDK's `metadata.SetExtraFields` escape hatch (anthropic-sdk-go v1.4 doesn't expose `ttl` on the non-beta `CacheControlEphemeralParam` directly — the beta path does). The escape hatch produces the correct wire payload (`"cache_control":{"type":"ephemeral","ttl":"1h"}`), but it's brittle: if the SDK adds a typed `TTL` field in a later release, the marshalling could double-emit or conflict. Drop the `SetExtraFields` call in `internal/providers/anthropic/send.go::applyAutoCacheControl` once the SDK exposes a typed `TTL` field, or alternatively switch the driver to the `betamessage` API (which already has `BetaCacheControlEphemeralTTL`).

- **Per-context cache-savings cost split (`ContextListView.swift`).** The contexts page metadata strip currently shows total `cumulativeCostUsd`. The Model Settings work added cache observability to per-message popovers (computed client-side as `cache_read_tokens × input_price × discount` where the discount is 90% on Anthropic and 50% on OpenAI/Google). Doing the same per-context aggregate client-side would require summing across all messages in the context — fine but expensive on large contexts. Cleaner fix: extend the per-context aggregate the server stamps on `ReeveContext` (alongside `cumulativeCostUsd` and `lastMessageTotalTokens`) to also surface `cache_savings_usd` (or a `would_have_cost_usd`). Then the chip on each row shows "billed $X · saved $Y" cleanly. Frontend has a TODO comment in the metadata strip already.

---

## Plugin hook ideas

Captured after surveying the existing `plugins.Plugin` surface (`Configurable`, `SystemPrompter`, `OutgoingUserTransformer`, `HistoryTransformer`, `ChunkTransformer`, `DisplayTransformer`, `ToolProvider`, `MessageLifecycleHook` is `onAssistantMaterialized` today — internal-only). Three gaps are obvious enough they're worth designing now; the rest noted-but-deferred until a concrete plugin pulls on them.

### Worth designing now

- ~~**`AssistantContentTransformer`**~~ ✅ **Done.** See `plugins/plugins.go::AssistantContentTransformer` + `Pipeline.TransformAssistantContent`. Wired in `internal/stream/consume.go::materializeAssistant`. Capability flag bridged to proto + Swift; UI capability chip "Assistant" on the profile-form plugin card.
- ~~**`MessageLifecycleHook`**~~ ✅ **Done.** See `plugins/plugins.go::MessageLifecycleHook` + `Pipeline.FireMessagePersisted`. Fires on user-message inserts (in `SendMessage` after the TX commits), assistant materialization (in `materializeAssistant`), and compression summaries (in `materializeCompression`). Detached goroutines per hook with panic-recovery so one bad plugin can't take down siblings. Capability flag bridged + UI chip "Lifecycle".

- **`PreSendContextInjector`** — non-persisted, per-turn injection of synthetic wire messages BEFORE the user turn. Distinct from `SystemPrompter` (static, persisted across turns) and `OutgoingUserTransformer` (mutates the user row that gets persisted). Returns zero or more `providers.WireMessage` values that splice into the wire prefix only for this turn. Unblocks the RAG/memory family: vector-search prior conversations and inject top-K snippets; pull recent calendar/email; inject project-scoped docs; auto-search on trigger keywords. Without this, RAG plugins either pollute the persisted user message (bust the prefix cache every turn — `basic_grounding`'s reason for being) or jam everything into the system slot (useless when relevant docs change per-turn).
  ```go
  type PreSendContextInjector interface {
      // Empty slice = no contribution this turn.
      InjectPreSend(userContent string) []providers.WireMessage
  }
  ```

- **`ContentRenderer` (server-driven UI fragments)** — generalises the display path from text-rewrites into structured rendering. Today the chain is `string → DisplayTransformer chain → string` and the Mac client renders the result as Markdown. New shape: `string → DisplayTransformer chain → string → ContentRenderer chain → []ContentPart`, where each part is either literal text or a typed `UIFragment` the client renders with a native SwiftUI view. The whole point is that this is **NOT tool-specific** — any plugin can opt in. `lettered_choices` is the immediate motivating case: it strips delimiters today, but the choices block could be a tappable card-list of options instead of a markdown bullet list. `brave_search` would render its tool result as cards. A future "mermaid" plugin would substitute fenced ```mermaid blocks with rendered SVG.

  ```go
  type ContentRenderer interface {
      // Walks the (possibly already-display-transformed) string and
      // returns an ordered mix of literal text spans and structured
      // UI fragments. Plugins downstream in the pipeline operate on
      // the parts list, free to split/replace any text part. A
      // returned single-text-part = pass-through.
      RenderContent(content string, role MessageRole) []ContentPart
  }

  type ContentPart struct {
      // Exactly one of Text or Fragment is set.
      Text     string
      Fragment *UIFragment
  }

  type UIFragment struct {
      Component string          // "card_list" | "choice_list" | "key_value" | ...
      Props     json.RawMessage // schema per Component, validated client-side
      // Optional: stable id so the client can preserve view-state
      // (selection, expand, scroll position) across re-renders.
      Key string
  }
  ```

  Initial component set scoped to what we'd actually use:
  - **`card_list`** — `[{title, description, url?, image?, badges?}]` — Brave Search and any future search plugin.
  - **`choice_list`** — `[{label, value}]` plus an `action` template (`compose:{value}` to drop the choice into the composer, or `tool:foo?bar={value}` to fire a tool). `lettered_choices` ships this on day one.
  - **`key_value`** — `[{key, value}]` definition-list — for "stat-style" plugins (weather, status).
  - **`image`** / **`image_grid`** — `[{url, alt?, caption?}]` — plugins that return media.
  - **`error`** — `{message, code?, retry?: action}` — typed error rendering.
  - **`raw_json`** — explicit fallback the existing JSON pretty-print path migrates to.

  Each component lives as a SwiftUI view in `clients/reeved-mac/ReeveMac/PluginRenderers/`; plugins are pure-Go authors describing structure, not native code. The same proto fragment ships to a future iOS/web client and they render their own component set. **Behaviour** rides on declarative `action` strings on interactive components: `compose:{text}`, `tool:{name}?{key}={value}`, `external:{https://…}` (with the link-safety prompt), `nav:conversation:{id}`. Anything beyond that is a signal the action set should grow, NOT that we should ship a JS sandbox.

  Wire shape: a new `Message.ui_fragments []UIFragment` proto field (per message, ordered, may be empty); persisted alongside content. Server runs ContentRenderer pipeline at materialisation (assistant turns) AND at fetch (read-time, so old messages benefit when a renderer plugin is added later — the fragments are derived, not stored, so re-deriving on read is correct).

  Open design questions worth chewing on before starting:
  - Read-time vs write-time rendering. Read-time means the same content adapts as the active pipeline changes; write-time freezes the rendering. Read-time is more flexible but adds work to every fetch.
  - Span replacement vs whole-content replacement. The `[]ContentPart` model lets one plugin replace just a substring while another renders the surrounding text. Worth it for composability (e.g. a `citations` plugin co-existing with `mermaid`); cost is a trickier API shape than "give me one fragment."
  - DisplayTransformer migration path. They're a strict subset of ContentRenderer (single text part out). Either keep both interfaces and document overlap, or deprecate DisplayTransformer in favor of ContentRenderer-emitting-text. Lean toward keeping both — DisplayTransformer is simpler when you only need a regex strip, and there's no reason to force every plugin to learn the parts model.

Suggested order: `AssistantContentTransformer` + `MessageLifecycleHook` first (each ~few-hundred lines, low surface). `ContentRenderer` is the bigger piece (proto change, Swift component scaffolding, action-dispatch wiring) — worth deferring until at least one plugin's needs (`lettered_choices`'s choice cards is the clearest candidate) drives the schema. `PreSendContextInjector` once a concrete RAG/memory plugin pulls on it.

### Considered, deferred until a real use case lands

- **`ToolMiddleware`** (wrap `ExecuteTool` for validation/logging/rate-limiting). No current need; revisit when an audit-style tool plugin is requested.
- **`CompressionTransformer`** (pre/post compression hooks). Per-profile guide + provider/model knobs already cover the customization users actually ask for.
- **`HealthCheck`** (declare readiness; UI shows "warming up / unhealthy"). Required-field warning chip already covers the most common "missing API key" case.
- **`ProviderRequestMutator`** (tweak `SendRequest` per-call). Overlaps heavily with the resolved CallSettings layer; a plugin that wants dynamic temperature is doing something exotic.
- **`StreamCancelHook`** (notify on cancel). Becomes useful when a long-running tool plugin (e.g. shell-execution) lands; design with the real use case in hand.
- **`ConversationLifecycleHook`** (created/deleted). Narrow use cases; `MessageLifecycleHook` covers most of what people want here.
- **`TitleGenerator`** (pluginify auto-titling). Current Apple-Foundation + cloud-model + per-profile-guide path is already configurable; haven't hit the wall.

---

## How to use this doc

When you defer something, add a one-bullet entry here with: package/file, what was skipped, why, and (if known) when to revisit. When you complete an item, delete it.

Companion to [architecture.md](architecture.md): strategic threads stay in the architecture doc's "Open threads"; tactical implementation TODOs live here.
