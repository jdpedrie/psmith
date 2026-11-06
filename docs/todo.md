# Psmith — deferred work

Master list of known-deferred items. Update as new deferrals are introduced and as items get done. Cross-references go to the relevant package or doc section.

The architecture doc's "Open threads" section captures the *strategic* deferrals (encryption, sharing model, transform pipeline, vision/files, tool use). This doc is the *tactical* version: in-flight TODOs left during implementation, plus a priority view of what's missing from the main system.

---

## Main system priorities — what's not done yet

Ordered by impact on getting Psmith to a "useful for sustained personal chat" state. Refer to the categorized sections below for implementation detail.

### Architecture-flagship features not yet built

- **Stateful harness drivers** — shipped for Claude Code (`server/providers/claudecode` + `claudesdk/`) and Codex (`server/providers/codex` + `codexsdk/`), including the `SendMessage` stateful path. Live-verified end to end: two turns through `SendMessage` against the real `codex` binary, the second recalling the first from a session it was never re-sent. See the stateful-send-path section of [design/providers.md](design/providers.md). Still open: a `pi` driver, and the client affordances below.

### Nice-to-have

- **Search conversations and messages.** `ListConversations.title_query` ships a server-side `ILIKE '%q%'` against `conversations.title`. Extend to: full-text search across message content (probably `tsvector` + GIN on `messages.content`), with hits surfacing the matching message snippet alongside the conversation in the sidebar's Search mode. Today the Search pill only matches titles; users with thousands of conversations will need content search too.
- Multi-device per user (per-device key-pair pairing).

---

## iOS streaming — Phase 4

**Real iOS backgrounding past the ~30s suspend** is still deferred. `beginBackgroundTask` would buy the grace window; APNs silent push is the only path past that and is a non-starter without a hosted APNs story. Current behaviour: backgrounding for >30s during generation triggers a brief resubscribe-and-replay on return.

---

## Server architecture (assessment 2026-08-11)

Full findings and reasoning in [server-assessment.md](server-assessment.md). Ordered by what to do first; none is urgent today, the first three are what shows up as concurrency rises.

~~1. **`TouchSession` writes on every authenticated request** ~~ **Done** (`2136e93`): touches only when `last_used_at` is older than five minutes.
~~2. **Chunk persistence is one round-trip per chunk**~~ **Done** (`2136e93`): one UNNEST insert per flush.
~~3. **`SendMessage` resolves the profile four times**~~ **Done** (`c6c419a`): request-scoped `profileCache` installed at the top of the send.
~~4. **Provider open sequence copy-pasted six times**~~ **Done**: `server/providerkit` owns load / ownership / decrypt / build / assert.
~~5. **Attachment bytes re-read every turn**~~ **Done**: `storage.ReadCache` removes the repeated backend reads, and `providers.FileUploader` + `provider_files` stop the bytes crossing the wire on every send. Google implements the uploader; Anthropic and OpenAI both have Files APIs and can adopt the same interface, and keep inlining until they do.
~~6. **Decompose `SendMessage`**~~ **Done**: 669 → 280 lines across `prepareTurn` (resolve, writes nothing), `commitUserMessage` (the transaction, whole and visible) and `buildSendRequest` (the turn's shape). What remains in `SendMessage` is the tool-loop closures and the supervisor handoff, which are the parts that genuinely belong to starting a run.
~~7. Smaller items~~ **Done**: `stream_chunks.payload` is JSON (migration 00050); pool size is explicit (`PSMITH_DB_MAX_CONNS`, default 25); and the three unbounded reads are bounded. `ListStreamChunks` gained an upper bound plus paging, the two full-tree reads gained a cap with an explicit `truncated` flag on the response rather than a cursor. Every `row_limit` in the schema treats zero as unbounded, so an omitted field degrades to the old behaviour instead of silently returning nothing.

## Implementation gaps inside shipped code

### Drivers

- **`server/providers/anthropic` `citations_delta`** — silently dropped because no normalized chunk type exists for it yet. Narrow (only fires when Anthropic citations are attached); add a chunk slot when a use case lands.

- **`server/providers/openai` cross-shape thinking round-trip** — the persisted thinking shape only round-trips cleanly when it matches the Responses-API `ResponseReasoningItem`. Cross-shape thinking (e.g. assistant turn produced by Anthropic, then sent through OpenAI) is silently omitted on the way back in.

- **Thinking effort, the loose ends** — the level is one knob everywhere now (`ThinkingEffort` in `proto/psmith/v1/types.proto`), but three translations are approximate. Gemini 3 takes `thinkingLevel` (low/high, medium on 3.1) and only tolerates `thinkingBudget` for compatibility; the google driver still derives a budget, which needs per-model detection to fix. A level a model rejects (xhigh outside the newest OpenAI and xAI families) surfaces as a 400; the constraints table could carry the supported levels so the clients grey out the rest. And the stateful drivers (Codex, Claude Code) ignore the setting entirely, though Codex's app-server has a reasoning-effort config it could carry.

- **Stream heartbeats** — drivers drop keepalive frames on the floor (empty Chat Completions deltas, `response.created` / `response.in_progress` on Responses), so the supervisor's first-chunk and idle timers cannot tell a working upstream from a wedged one and both had to grow to five minutes for reasoning models (`server/stream/send_retry.go`). A heartbeat chunk type that resets those timers without being persisted or fanned out would let the budgets tighten again, and fanning it out would keep the client's ten-minute transport window alive through a long think. Not done because xAI's docs suggest nothing arrives at all during reasoning, so the budget was the fix that had to land either way.

### History builder

- **`server/history` coalesces adjacent assistant turns, not user turns.** `coalesceAssistants` runs at the end of `Build`. Assistant-only is deliberate: `role=context` rewrites to wire user and always precedes a real user message, and a reconstructed tool-result turn is followed by whatever the user said next, so consecutive user turns are a normal shape compaction depends on. Neither case is an error anyway — Anthropic's docs say consecutive same-role turns "will be combined into a single turn" — so this is determinism rather than a fix: doing it ourselves keeps the bytes identical on every rebuild instead of depending on a join that is undocumented for two of the three drivers.

- **`server/history`** — cross-provider thinking is **omitted entirely** when destination ≠ producer. The architecture doc's "Thinking handling" section spec'd "render to plain text and inject into content" for this case. Deferred until tool use lands so we don't have to redo it. Code comment in `history.go` references this.

### Conversations / SendMessage

- **Stateful provider sends** — shipped. `SendMessage` branches on `StatefulProvider`, resolves the branch's handle by walking to the nearest ancestor carrying one (`NearestHarnessHandle`), opens a session when there is none, and sends one message via `history.Params.LatestOnly`. Handles land on `messages.harness_handle` at materialization, which is what makes forking work. Open follow-ups:
  - ~~No client affordances yet.~~ Shipped. `Conversation.harness` carries the binding on the detail reads; `ConversationViewModel` derives the affordances once for Mac and iOS, `harnessVM` does the same for web. Attach controls disappear, the model picker filters to the bound provider with a notice, and a card in conversation settings explains all three constraints together.
  - **Attachments to a harness.** Refused outright today, with the control hidden and the paste path guarded. Both CLIs can read a file given a path, so the shape would be: materialize the blob to a temp file and reference it in the message. Needs a lifetime story for the temp file and interacts with the read-only sandbox pin.
  - **Editing an assistant turn drifts.** "Save and resend" on an edited assistant forks from a handle naming the state that contains the *original* text. Psmith's history and the harness's disagree from that point. No fix short of a harness that accepts a transcript.
  - **A `pi` driver.** `pi --fork` is native and records `parentSession`, so it fits the same contract. Not started.

### Drivers not yet built

- **`claude-code-subprocess` driver** — shipped (`server/providers/claudecode`, engine in `claudesdk/`). One CLI invocation per turn, `--resume` + `--fork-session` on every send so handles are immutable per-turn snapshots (plain `--resume` appends to a shared linear transcript — verified against the CLI — so forking is what makes branching work). The StatefulProvider contract was finalized alongside: `SessionConfig` at StartSession, per-turn handles via `ChunkSessionHandle`. Still open: the CLI exposes no sampling knobs, so CallSettings passes through empty.
- **`codex-app-server` driver** — shipped (`server/providers/codex`, engine in `codexsdk/`). One long-lived `codex app-server` process speaking JSON-RPC over stdio. `SendInSession` always forks (`thread/fork` with `lastTurnId`) and never resumes, so handles stay immutable per-turn snapshots. Sandbox pinned read-only and approval policy pinned to never: the operator's own config is tuned for a file-editing agent, and a chat turn has nobody to answer an approval request, which hangs the turn until it times out. `pmenglund/codex-sdk-go` was evaluated and rejected as a dependency (pins 0.147.0 against the installed 0.144.1, with major/minor enforcement).

---

## Council mode (shipped — `plugins/council`)

Design in [design/council.md](design/council.md). Built: roster, deterministic
round-robin router, model-backed moderator behind the same interface, frozen
directions, per-hop token caps, continue, persona attribution and rails on both
clients, per-theme persona palettes.

Left deliberately:

- **Speculative moderation.** The moderator is a serial round-trip in front of every hop. Running it when the previous hop terminates would hide that behind the user's tap, at the cost of a call for every abandoned discussion. Only worth it if the serial version grates in practice.
- **Gemini consecutive same-role behaviour is unverified.** Anthropic documents combining; Gemini's docs are silent and we have not tested it. `history.coalesceAssistants` makes it moot for assistant turns.

## Strategic deferrals

Recorded here for grep-ability; the canonical discussion lives in the relevant design docs under [design/](README.md#design):

- **Resource sharing model** — v1 is per-user-only. Add `visibility = {private, shared}` on `user_model_providers` when a second user actually exists.
- **Encryption Tier B** — per-user keys derived from the password (envelope wrapping). Tier A (column at rest via `server/crypto`) is shipped on `user_model_providers.config_encrypted` and `user_langfuse_config.secret_key_encrypted`; Tier B is the next step if the threat model grows past "operator with logical DB access shouldn't see plaintext."
- **Dynamic plugins** — the reason `pluginapi` and `pluginapi/host` were split out of `plugins` and each plugin got its own package. The intended shape is activate-by-config with hot-swap into a running server, plus a core-versus-optional split (mcp and basic_grounding always on, the rest opt-in). `plugins/all` is a blank-import placeholder that preserves compile-time registration until then, and the registry is still a package global; making it an instance is probably right for per-user plugins but is the same conversation.

  **Parked, not blocked.** Surveyed 2026-07-28 and deliberately not started. Four findings, so nobody re-derives them:

  - **MCP is already the dynamic plugin system for tools.** Anyone wanting a dynamically loaded tool writes an MCP server today, and `plugins/mcp` already does subprocess supervision, pooling, idle reaping and per-call timeouts. So the marginal value of go-plugin is the *non-tool* capabilities only, which is a much smaller prize than it first looks.
  - **Put the process boundary at the `Pipeline` fan-out, not at the plugin method.** `TransformHistoryMessage` runs once per message in the prefix (`server/history/history.go:360`), and `TransformForDisplay` + `RenderContent` run once per message per fetch inside the `ListMessages` page loop (`server/conversations/service.go:1143`). Each `Pipeline` method iterates plugins internally, so proxying at the method level makes these messages × plugins round trips per send. Batching at the Pipeline level makes it one, and makes cost independent of conversation length. This is baked into the wire contract permanently, so it is the decision to get right first.
  - **`ChunkTransformer` is declared, capability-reported, and never wired.** There is no per-chunk plugin call anywhere in `server/stream/`. The one interface that would rule out out-of-process plugins does not exist yet, so it can be designed for the boundary (batched or streaming) rather than against it.
  - **`hashicorp/go-plugin` costs 13 modules**, of which grpc 1.61 and `genproto/googleapis/rpc` are new to a repo that is pure connectrpc. Its real advantage is not the transport but the bidirectional broker: `pluginapi/host`'s shims (`PluginStateStore`, `Searcher`, `DeviceToolBroker`, `ProviderResolver`) all have to be callable *from* the plugin, and hand-rolling that over the `plugins/mcp` stdio JSON-RPC pattern is the part that would actually cost time.

  If this restarts, the narrow first cut is the once-per-send capabilities plus `ExecuteTool`, leaving history and display transforms in-process until something pulls on them. Less wire surface to commit to forever.

---

## MCP server (v1 shipped — `server/mcpserver`)

Exposes a curated subset of the Connect RPCs as MCP tools at `/mcp`,
served over Streamable HTTP, JSON-only responses. Bearer-token auth
shared with the Connect surface. Tools: `list_profiles`,
`get_profile`, `create_profile`, `update_profile`,
`registered_plugins`, `get_profile_plugins`, `set_profile_plugins`,
`list_providers`, `list_models`, `list_provider_types`,
`list_provider_templates`, `discover_models`, `enable_models`,
`toggle_user_model_favorite`, `test_user_model_provider`,
`list_conversations`, `get_conversation`, `list_messages`. Plus the
`inproc` MCP transport on the client side so the seeded
`Psmith Manager` profile dispatches to the local server with no port
and no token.

Deferred:
- **Elicitation over HTTP transport** — inproc elicitation shipped
  (see below). HTTP-transport elicitation would need SSE response
  framing on the server-initiated request + a paired POST channel
  for client responses. Defer until a concrete remote-MCP case
  needs it; the secrets use case is inproc-only.
- **Conversation write tools** — `send_message`, `compact`,
  `delete_conversation` etc. all live on `ConversationsService` but
  aren't exposed yet. `send_message` in particular is a streaming
  RPC and needs a different mapping (probably accumulate the full
  response server-side and return when complete, since MCP tools
  are request/response).
- **Destructive write tools** — `disable_models`, `delete_profile`,
  `update_user_model` (settings clears) etc. all need elicitation
  gating before exposure. Defer until elicitation lands.

## Elicitation (inproc shipped — `server/elicit` + the broker)

MCP elicitation lets a server tool request additional input from the
user mid-call without that input ever entering LLM context. Psmith
ships the inproc-transport flavour today:

* `server/elicit` holds the protocol types (`Request`, `Response`,
  `Client` interface, ctx helpers). Lives in its own package so both
  `mcpserver` (publishes the `ctx.Elicit` hook to tool fns) and
  `server/conversations` (provides the broker implementation) can
  import without creating a cycle.
* `server/conversations.elicitBroker` routes responses: tools
  block on a channel; the user-facing endpoint writes into it. 5-minute
  timeout per request.
* `providers.ChunkElicit` is the new stream chunk type the tool loop
  emits before blocking; flows through the supervisor → client like
  any other chunk.
* `POST /conversations/{id}/elicitations/{eid}/respond` is the
  user-facing endpoint. Same Bearer-token auth as the Connect surface;
  ownership-checked against the conversation row.
* `ElicitSheet` (PsmithUI) renders a JSON-Schema-driven form. Handles
  string / boolean / integer fields; string + `format: password`
  renders as a SecureField (the secrets use case).
* `ElicitationsRepository` (PsmithKit) POSTs the response.
* Mac + iOS conversation views mount the sheet via `.sheet(item:)`
  bound to the first pending elicit on the active stream.

First tool using it: `create_user_model_provider` — Psmith Manager can
add a provider end-to-end without the API key ever entering chat
content, the model's context, or DB-persisted message rows. The
secret flows user → client UI → POST → tool's local stack frame →
provider config encryption → discarded.

Deferred:
- **Elicitation over HTTP transport** — needs SSE response framing
  on server-initiated requests + a paired POST channel for client
  responses. Inproc is sufficient for Psmith's own assistant
  (Psmith Manager via local `/mcp`); remote MCP clients calling
  Elicit get `elicit.ErrUnsupported` and can degrade gracefully.
- **Schema renderer coverage** — v1 handles flat objects with
  string/boolean/integer properties + the `password` format hint.
  Arrays, nested objects, enums, number ranges all fall through to
  text inputs. Expand the schema-renderer as new tools need it.

## Welcome message + onboarding (v1 shipped)

Profiles gain a `welcome_message` field. When non-null, a real
assistant message is inserted at conversation-create time (role=
assistant, is_welcome=true) — included in wire history sent to the
LLM so the model knows what greeting it opened with. Clients render
the message normally; first open in an app session plays a token-
chunked fake-stream reveal (`WelcomeReveal` in PsmithUI), subsequent
opens render statically.

Seed file format extended with YAML-style frontmatter so a single
`.md` template can carry both `welcome_message` and the system
message body. Tiny custom parser (`server/profiles/seed_format.go`,
~30 LOC) handles single-line scalars and `|` block scalars — enough
for the current use case without pulling in yaml.v3. New seed
templates inherit through the backfill path that already runs on
every startup; existing seeded profiles whose welcome_message is
NULL get the template's welcome applied without overwriting any
user customization.

Onboarding gate: when the signed-in user has zero providers or zero
enabled models, `OnboardingView` takes the full app surface and
walks them through pick-template → enter-key → discover → enable
inline. As soon as the state condition flips (live, observed via
@Environment), the gate lifts and the normal app shell renders.
Shared SwiftUI view in PsmithUI; both platforms render the same
flow.

Important fix folded in: the stream supervisor's detached run
context now carries the authenticated user through, so inproc MCP
tool calls (Psmith Manager's `mcp` plugin → local /mcp surface)
resolve identity correctly during background tool dispatch.

## System profiles + capability enforcement (v1 shipped)

Two seeded profiles materialize on first login (Personal Assistant +
Psmith Manager). Backed by `users.system_profiles_seeded`; idempotent;
the user can edit, rename, or delete them like any other profile —
deleted ones don't resurrect on next login. Templates live in
`server/profiles/seeds/*.md`.

Plugin model-capability requirements: `plugins.CapabilityRequirer`
declares what a plugin needs from the conversation's model
(`tool_use`, `vision`, `generates_images`, etc.). Auto-derives
`tool_use` from any plugin implementing `ToolProvider`. Exposed on the
proto as `Profile.required_model_capabilities` (union across the
effective pipeline) and `PluginType.required_model_capabilities`
(per-plugin). `SendMessage` validates the resolved model satisfies
the profile's union and returns `FailedPrecondition` with the
missing-cap names when it doesn't.

UI capability filter — Mac + iOS conversation model pickers now grey
out and disable models that don't satisfy the active profile's
`required_model_capabilities`, with a "needs: tool_use, vision"
caption on each disabled row. The active profile's caps load via a
parallel `GetProfile` inside `loadAvailableModels` so the filter is
ready by the time the picker first renders.

Deferred:
- **Profile form picker filter** — the three model-picker slots in
  the profile form (default / compression / title) don't filter yet.
  Tricky because the relevant requirements are derived from the
  profile-being-edited's plugin pipeline, which lives in local form
  state until save. Either compute caps from the local-state plugins
  (more code) or skip filtering during edit and rely on the
  conversation-level filter to catch mismatches at send time.
- **Profile-level explicit cap requirements** — today only plugin-
  derived requirements flow through. A profile that wants vision
  even with a plugin-free pipeline ("always pick a vision-capable
  model") would need an explicit field on Profile. Smaller backend
  + meaningful UI work; defer until a concrete use case shows up.

## Smaller items

- **Connect server-streaming via raw curl** doesn't pretty-print — Connect's wire format isn't plain newline-delimited JSON. For terminal smoke testing, write a small `clarkctl` helper or use `buf curl` to subscribe to streams.
- **`PSMITH_CATALOG_REFRESH_INTERVAL` smoke-tested only at "0" (disabled).** Periodic refresh path not exercised in tests.
- **`ListProviderTypes` `display_name`** — currently humanized via `humanizeName`. Could come from driver metadata if drivers exposed a `DisplayName()` method.
- **`ListProviderTypes` `config_schema`** — empty bytes for v1; UI hardcodes config forms. JSON Schema generation per-driver is a future ergonomic win.
- **Unit-tested `server/store` queries** — no direct tests of the sqlc-generated layer (covered transitively by every service test).
- **`messages.raw_content` is dormant** — in the schema since 00001, plumbed through the proto, never written. Superseded by the `message_headers`/`message_trailers` envelope design (00041): content stays the user's words, plugin contributions live beside it. Dropping the column needs a proto-field deprecation pass; not urgent.
- **Legacy grounding rows** — messages written before 00041 carry the `<grounding>` block inline in `content`; basic_grounding's DisplayTransformer strip stays wired for them (display is clean, but editing such a row still shows the block, and its TTS/embedding text includes it). A one-shot backfill migration (split block out of content into message_headers) would let the strip retire; skipped for now.
- **Web conversation settings: JSON-oneof call-settings editors not built** (`server/web/convsettings.go`). The Call settings tab covers the scalar/tri-state knobs (temperature, top_p, max output, top_k, stop sequences, thinking, explicit cache, include-thinking-in-history) plus per-provider scalar extras (Anthropic prompt-cache, OpenAI seed/penalties/parallel-tools, Google candidate count). Skipped: OpenAI `response_format` (text/json-object/json-schema oneof) and `logit_bias`, Anthropic `cache_ttl`, and Google `safety_settings`/`response_schema`. Add these as JSON/structured editors when a user needs them; iOS has them in `CallSettingsForm`.
- ~~**`CompressionSummaryCard` still uses `.contextMenu` on iOS**~~ **Done**: it bit. A fresh summary card didn't render until the conversation was re-entered. The card's `.contextMenu` is macOS-only now and the iOS transcript gives it the action menu.
- **Expanded thinking/tool-call disclosure text keeps `.textSelection(.enabled)`** (`ThinkingDisclosure`/`ToolCallDisclosure`). A long-press that starts inside that text opens the selection menu, not the message action menu — deliberate for now (selection is useful there and the menu is reachable from the message body); revisit if it reads as inconsistent.
- **Mac sidebar mode pill renders the ACTIVE segment white-on-white in snapshots** (`ConversationListView.modePillRow`). Visible in every committed `ConversationListViewSnapshots` baseline since Jul 21, so it predates the offline work and may be a harness-only artifact rather than a real rendering bug — check against a running app before chasing it.
- **`ProvidersViewModel.load()` is sequential per provider** — one `get(id:)` per provider, then `loadTemplates()`, all awaited in series. Now bounded (30s unary transport) but a many-provider account on a slow link still serializes; the Mac splash no longer waits on it (3s fallthrough) so it's latency, not a hang. Parallelize with a task group if it ever bites.
- **95 of 101 repository calls have no per-call timeout.** They're now bounded by the unary transport (30s request / 60s resource, `RPCTimeouts`), which is the systemic fix; the six bespoke `withRPCTimeout` wrappers stay because they're tighter on the launch-critical path. Adding more per-call wrappers is only worth it where 30s is too generous to show a user.
- **`server/stream` tests flake under concurrent load.** Passes reliably on its own (3/3), but running the full suite — or even just alongside `server/conversations` — fails a *different* test each time (`TestIdleTimeout_FinalizesAsErrored`, `TestCancel_InFlight_MaterializesPartial`, ...), with `closed pool` and `context canceled` errors in the log. These are wall-clock-sensitive stream tests racing pgtestdb pool teardown when many packages share the database concurrently. Pre-existing and unrelated to any one change; it makes `go test ./...` untrustworthy as a green/red signal, which is the real cost. Likely fixes: give the timing tests injectable clocks rather than real sleeps, or serialize the package with `-p 1`.
- **Game master — remaining durability.** Landed: compaction/manual-context state carry, optimistic concurrency via `expected_state_version`, a one-commit-per-send guard, and ephemeral turn-context injection. Still open: prepared-then-committed transitions with an idempotency key `(plugin_name, conversation_id, tool_call_id)` — needs the tool-call id threaded into dispatch (`server/conversations/tool_loop.go:221` has `c.ID` but does not pass it) — and a transitions ledger for replay/debugging. Today a tool that mutates state followed by a generation failure leaves the turn bound to no message; the next turn's ancestor walk absorbs it by replaying from the previous snapshot, which is safe but silently loses a turn.
- **Game master — remaining depth.** Landed: concurrent clocks and off-menu actions with priced confirmation. Still open: multi-stage situations that branch within themselves, delayed/conditional effects keyed to a state predicate rather than a countdown, policies and projects, factions and characters with loyalty separate from power, turn capacity forcing triage, and soft-failure endings. Presentation still reuses `key_value`/`choice_list`, so odds and clocks ride in label strings; bespoke `game_status`/`game_choices` components would give odds a two-column layout and clocks a progress treatment (one new `*Renderer.swift` plus a case in `FragmentView.bodyFor` — no proto change).
- **Capability gate ignores conversation-level plugins.** `ResolveRequiredModelCapabilities` takes a profile id, so a plugin attached only via `conversation_plugins` never has its required capabilities enforced. Closing it means threading the conversation through send-time validation (`server/conversations/service.go:1468`), which is wider than the profile-layering fix that landed with the game work.
- **Web model picker has no provider logos.** iOS shows a `ProviderLogo` per group header; the web picker uses the provider label text. Add logo assets if/when we vendor them.

- **Anthropic SDK upgrade for native `ttl` field.** The `AnthropicExtras.cache_ttl` follow-up shipped the 1-hour TTL via the SDK's `metadata.SetExtraFields` escape hatch (anthropic-sdk-go v1.4 doesn't expose `ttl` on the non-beta `CacheControlEphemeralParam` directly — the beta path does). The escape hatch produces the correct wire payload (`"cache_control":{"type":"ephemeral","ttl":"1h"}`), but it's brittle: if the SDK adds a typed `TTL` field in a later release, the marshalling could double-emit or conflict. Drop the `SetExtraFields` call in `server/providers/anthropic/send.go::applyAutoCacheControl` once the SDK exposes a typed `TTL` field, or alternatively switch the driver to the `betamessage` API (which already has `BetaCacheControlEphemeralTTL`).

- **Speech (TTS) — v1 shipped 2026-07-08; deferred pieces** ([design/speech.md](design/speech.md)):
  - **Web read-aloud UI** (Mac shipped 2026-07-10: settings pane, hover speaker, auto-speak). The web needs a cookie-authed `/tts` fetch + MediaSource playback.
  - **Live tee (`GET /tts?run_id`)** — speak-as-it-streams; v2 in the design doc.
  - **WS drivers** (Grok WS, ElevenLabs stream-input, Cartesia) behind the same `Synthesizer` interface.
  - **Voice resolution chain** (conversation > profile > user) + multi-voice conversations.
  - **Standalone-key cost attribution** — `cost_events.provider_id` is a FK to `user_model_providers`, so synthesis with a standalone key (no `provider_ref`) skips the ledger. Fine while credential-reuse is the recommended path; revisit if ElevenLabs (never a chat provider) lands.

- ~~Mac profile editor lacks welcome-message editing~~ — added in the 2026-07-10 parity sweep (Prompt section row + clear handling).

- ~~Mac SnapshotHarness broken on HEAD~~ — fixed in the 2026-07-10 Mac parity sweep (StreamHub.seedForPreview seam); baselines re-recorded, 83 snapshots green.

- **Perf follow-ups after the structure-only tree + token-count cache round.** Candidates not yet taken: `ListConversations` per-row aggregates at large conversation counts (the sidebar loads all rows in one page), server-side caching for `CountContextTokens` (client cache only helps repeat opens on one device), and paging `ListMessages` chain mode if conversations grow past ~1k messages (the scroll architecture already mounts a tail window; the fetch is the remaining full-history cost, ~3MB at 200×800w).

- **Inverted (bottom-anchored) transcript list — SHIPPED 2026-07-21 (iOS); stack went EAGER 2026-07-21.** The flipped list landed: newest message at content offset 0, entry/pill/deletes exact by construction, send pinned at the rest edge under a runway + stream clip, one exact id-solve at terminal. Both deterministic entry-park repros (fresh-install Scroll XL cold entry; pop-back from Contexts on a 5-message context) verified green, and a full send/stream/terminal cycle verified motionless at 236 messages. The LazyVStack was then replaced with an eager VStack after a device recording caught freshly realized rows rendering upside-down mid-fling for 400ms+ (the per-row un-flip is a CALayer transform on the context-menu portal container and lags async lazy realization; full mechanism + hierarchy-dump evidence in [clients/chat-scroll.md](clients/chat-scroll.md)). Eager rendering also retires the estimate-error class outright — every offset is now a laid-out fact. **Watch on device**: entry feel and memory for monster transcripts (sim: the 200×800w + 180KB-summary fixture paints inside the push animation; RSS ~470MB after — sim-inflated but worth a device check). Fallback if entry regresses on device: eager-head/lazy-tail hybrid, reopening the race only for deep history. Remaining polish, deliberately deferred: (a) the scroll-to-bottom pill sometimes shows during a parked stream at the rest edge (cosmetic — tapping it is exact and harmless); (b) a reader parked in OLD history when a new message lands shifts by the new row's height (growth at the origin side moves origin-measured offsets; chat-standard behavior, accepted for v1); (c) the iOS 26 scroll-edge-fade regression on inverted scroll views (FB20540755) is worked around with a hand-rolled gradient — revisit when Apple fixes the extent math; (d) **long-press LIFT flashes the row upside-down** (user-reported): the context-menu lift animation snapshots the row's backing view, which carries the flip transform — the explicit `preview:` closures fix the post-lift preview but SwiftUI exposes no hook for the lift's own targeted preview. The durable fix is hosting each row in a UIKit container whose INNER view renders upright (layer transform on the outer), so the interaction snapshots clean pixels — pairs naturally with any future UIKit-hosted-row work; not worth the surgery for a sub-second flash alone. (e) Top-of-context affordance settled 2026-07-22 after two device failures: the tappable fade band never received hardware taps (the nav bar owns that touch band) while silently blocking scroll/long-press over the transcript, and the edge-solve jumped the wrong way. Now: the toolbar TITLE button runs an exact id-solve to the oldest row; the fade gradient is hit-test-disabled visual chrome; `StatusBarTapBridge` remains a device-only bonus path.

- **Cross-client sync follow-ups.** Shipped through 2026-07-22: ConversationChanged from every conversation mutation path; ProviderChanged from every provider/model mutation (clients reload the provider list on receipt); debounced list refresh + staleness-checked open-conversation refresh; the viewed-conversation fast path (ConversationChanged + no local stream → scoped ListActiveRuns → adopt, so another client's just-started run streams within a beat); events-stream `kick()` on login and platform foregrounding plus healthy-connection backoff reset (a stream that died during a suspend no longer waits out up to 30s of accumulated backoff); connect/disconnect logging under the `Sync` os_log category. Still deferred: (a) non-provider settings surfaces (embedder, Langfuse, speech) push no events — screen re-entry covers them; (b) the web client has no event consumer (tracked as its own task); (c) the events bus remains in-memory/no-replay by design — clients reconcile on foreground, which is the accepted recovery story.

- **Server perf follow-ups from the 2026-07-21 audit — shipped.** `messages(parent_id)` index for the stitch-delete reparent; `GetContextLeafMessage` NOT IN → NOT EXISTS; `history.Build` walks O(chain) via `ListMessageChainForHistory` in BOTH modes (explicit leaf, and leafless via a capped `ListContextLeafIDs` probe that preserves the empty/ambiguous contract); `ListContextsByConversation` aggregates via laterals; stream terminals fetch ONE message instead of two full-chain transfers per turn; `resolveParent`'s fallback and the per-turn auto-title check use LIMIT-capped queries instead of listing the whole context (embeddings included) to take a tail element or count to two. `ListMessagesByContext` now serves only the `full_tree` ListMessages mode, which no production client uses (chain mode — the conversation-open path — was already column-pruned via the ancestor-chain CTE); if full_tree ever gets a real consumer, prune its embedding columns then.

- **Port the iOS chat-scroll architecture to Mac.** The Mac ConversationView (`clients/psmithd-mac/PsmithMac/ConversationView.swift`, `paneScrollBody`) still runs the pre-v7 design with all four failure classes the iOS side spent months eliminating: animated `scrollTo` per streaming chunk, `scrollTo(last, anchor: .top)` on message-count change (fires at terminal), `onScrollPhaseChange`-based user detection (misfires on system motion), and no width pin. The design to port is now the INVERTED list (2026-07-21, [clients/chat-scroll.md](clients/chat-scroll.md)) — dramatically less machinery than the windowed design this entry used to reference. Mac-specific unknowns to spike first: whether `scaleEffect(y: -1)` hit-testing and NSScrollView-backed scrolling behave, macOS scroll-wheel direction through the flip, and the macOS equivalents of the iOS 26 edge-effect/context-menu-preview workarounds. The StreamHub delta coalescing (shared PsmithKit) is already live for Mac, and the shared markdown theme (code/table horizontal scrollers) is in place. Port when Mac scroll work resumes.

- **Tiered-pricing editor UI.** The db + server + cost engine for context-size-tiered pricing shipped 2026-07-22 (`user_models.pricing_tiers`, `ModelPricing.tiers`, tier-aware `buildUsageParams`; the whole request prices at the highest tier whose threshold the prompt exceeds, nil subfields inherit base columns). The catalog (models.dev) carries no tiers, so rows are user-maintained — but no client FORM edits them yet: the proto round-trips through UpdateUserModel/AddManualModel, so the iOS/Mac model edit forms need a tier-list section when it itches. Until then tiers are settable via the API.

- **MCP registry follow-ups.** (1) Done 2026-07-22: the generic entry now reads "Custom MCP server (advanced)" in every picker. (2) Client/web edit forms only support keep-or-replace for env/headers (blank keeps); clearing a stored secret requires the RPC's present-but-empty contract, which no form exposes — delete/re-register covers it for now. (3) Registry changes don't publish a live-update event; other clients see new pseudo-plugins on their next ListPluginTypes call.

- **Special-role editability + pending-compression gating — shipped 2026-07-21.** The editability matrix is now uniform: every role's CONTENT is editable via the standard affordance (long-press context menu on iOS, right-click/hover on Mac), role flips stay user↔assistant only (pickers and Save-and-Resend hide for framing roles, which the server rejects flips on anyway). Mac gained system/context editing to match iOS; the compression card's special inline "Edit…" is gone in favor of its standard context menu (Edit / Copy / Delete). Pending-compression gating: while a clean summary awaits review, all three clients swap the composer for `CompressionReviewBar` (Delete / Confirm — actions moved OUT of the card), and the compact button disables (iOS gained the gate; Mac already had it; web's Compact page doubles as the review surface). Web also gained `POST /c/{id}/message/{mid}/delete`.

- **Compaction continuation residuals.** The truncated-summary badge shipped 2026-07-22 (card + review bar + web compact page read `finish_reason`; see [design/compression.md](design/compression.md)). Consciously skipped: a `stream_runs.finish_reason` column — derivable by joining `result_message_id` to the message row, so no schema duplication until a consumer needs it hot. Still open: if continuation legs ever hit the consume loop's 60s idle timeout on cold giant transcripts, consider a leg-boundary-aware idle allowance.

- **ContextListView snapshot harness renders a stale/partial frame.** Found while shipping the cache-savings chip (2026-07-22): the recorded `withCumulativeCosts` baseline neither reflects code edits to `ContextRow.metadataStrip` (even an unconditional text change failed to appear after an `rm -rf .build` full rebuild) nor renders the active row or the section label. Other suites in the same run (ConversationView, SettingsView) pick up edits normally. The billed·saved chip is therefore code-reviewed + server-tested but not pixel-pinned; debug the harness's pane wiring for this suite when next in there.

---

## Plugin hook ideas

Captured after surveying the `pluginapi` capability set. Two entries that lived here as designs have since shipped; both are documented in [design/plugins.md](design/plugins.md), and where the shipped shape diverged from the sketch it is worth knowing why.

**`PreSendContextInjector` shipped as `TurnContextInjector`.** The sketch returned `[]providers.WireMessage` spliced in before the user turn. The shipped shape returns one text block and takes a `TurnInfo` carrying conversation, context and leaf-message ids, which is what makes injection fork-aware. Two things the sketch had not worked out: the block must land at the head rather than the system slot, or it invalidates Anthropic's cached prefix every turn, and the injector needs the same host-capability decoration tool dispatch gets, or a stateful injector has no way to read anything.

**`ContentRenderer` shipped roughly as sketched**, including the `Message.ui_fragments` wire field and the initial component set. Two of the three open questions resolved differently than the sketch guessed. Rendering is read-time only (`server/conversations/convert.go`), not read-time plus materialization, so adding a renderer plugin retroactively improves old messages and nothing is frozen at write. And the components live in `PsmithUI` rather than the Mac target, so iOS and Mac share them. The third resolved as predicted: DisplayTransformer stays alongside ContentRenderer rather than being deprecated, because a regex strip should not have to learn the parts model.

- **Profile lookups beyond the loaded pages** (`PsmithKit` ConversationsModel/ProfilesViewModel) — clients page profiles at 100/page, and chain-name/grouping lookups only see loaded pages. Under 100 profiles (everyone today) behavior is identical to pre-paging; above that, conversation rows for profiles on unloaded pages fall back to their placeholder until the profiles list is scrolled. Revisit with a by-id profile hydration if it ever bites.


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

Companion to the [design docs](README.md#design): strategic threads are discussed in the relevant subsystem doc; tactical implementation TODOs live here.

## Test flakes

- **`server/stream` times out intermittently under package-level parallelism.** `TestStart_PersistsAcrossFlushBoundaries` and `TestIdleTimeout_FinalizesAsErrored` each fail roughly one run in four with `waitFor timeout`, and only when the whole package runs together. Confirmed pre-existing against a clean tree (2026-08-20), so it is fixture contention rather than a bug in what they cover. Both use a 5s `waitFor` against a pgtestdb instance shared with every other parallel test in the package.
