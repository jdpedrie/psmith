# Reeve — deferred work

Master list of known-deferred items. Update as new deferrals are introduced and as items get done. Cross-references go to the relevant package or doc section.

The architecture doc's "Open threads" section captures the *strategic* deferrals (encryption, sharing model, transform pipeline, vision/files, tool use). This doc is the *tactical* version: in-flight TODOs left during implementation, plus a priority view of what's missing from the main system.

---

## Main system priorities — what's not done yet

Ordered by impact on getting Reeve to a "useful for sustained personal chat" state. Refer to the categorized sections below for implementation detail.

### Architecture-flagship features not yet built

- **Stateful harness drivers (Claude Code, Codex, pi.dev)** — entirely missing. Two parts: (a) per-harness Layer-1 implementations (subprocess management, NDJSON event parsing, session lifecycle), (b) Layer-2 abstraction + the stateful-send code path in `SendMessage` (currently only handles `StatelessProvider`). Architecture treats these as first-class; was a stated original motivator (mixing cloud APIs with local agentic CLIs). Detailed phasing + per-harness cheat sheet + data model + UX in [`harness-plan.md`](harness-plan.md).

### Nice-to-have

- `RefreshUserModelMetadata` RPC — explicit re-snapshot of a UserModel from current catalog. (`UpdateUserModel` partially shipped — handles `default_settings`; metadata-edit fields beyond that are still TODO.)
- `ListConversations` real pagination (`page_size` capped at 100, `page_token` ignored — returns all in one page).
- **Search conversations and messages.** `ListConversations.title_query` ships a server-side `ILIKE '%q%'` against `conversations.title`. Extend to: full-text search across message content (probably `tsvector` + GIN on `messages.content`), with hits surfacing the matching message snippet alongside the conversation in the sidebar's Search mode. Today the Search pill only matches titles; users with thousands of conversations will need content search too.
- Multi-device per user (per-device key-pair pairing).

---

## iOS streaming — Phase 4

**Real iOS backgrounding past the ~30s suspend** is still deferred. `beginBackgroundTask` would buy the grace window; APNs silent push is the only path past that and is a non-starter without a hosted APNs story. Current behaviour: backgrounding for >30s during generation triggers a brief resubscribe-and-replay on return.

---

## Deferred RPCs (proto contract exists, no implementation yet)

- **`ModelProvidersService.UpdateUserModel`** — partially shipped. The RPC exists and currently writes only `default_settings` (per-model layer of the CallSettings resolution chain). Letting users hand-edit other snapshotted metadata (context window, display name, etc.) is still TODO — extend `UpdateUserModelRequest` with the additional optional fields and route them through new sqlc queries.

- **`ModelProvidersService.RefreshUserModelMetadata`** — explicit re-snapshot of a UserModel from current catalog. Proto stub: not yet defined.

---

## Implementation gaps inside shipped code

### Drivers

- **`internal/providers/anthropic` `citations_delta`** — silently dropped because no normalized chunk type exists for it yet. Narrow (only fires when Anthropic citations are attached); add a chunk slot when a use case lands.

- **`internal/providers/openai` parallel tool calls** — the dispatch loop tracks one active call by `output_index`. Two parallel `function_call` items would step on each other; switch the per-output-index slot to a map when a model actually emits parallel calls in production.

- **`internal/providers/openai` cross-shape thinking round-trip** — the persisted thinking shape only round-trips cleanly when it matches the Responses-API `ResponseReasoningItem`. Cross-shape thinking (e.g. assistant turn produced by Anthropic, then sent through OpenAI) is silently omitted on the way back in.

### History builder

- **`internal/history`** — cross-provider thinking is **omitted entirely** when destination ≠ producer. The architecture doc's "Thinking handling" section spec'd "render to plain text and inject into content" for this case. Deferred until tool use lands so we don't have to redo it. Code comment in `history.go` references this.

### Conversations / SendMessage

- **Stateful provider sends not wired in `SendMessage`** — currently `SendMessage` requires the driver to satisfy `providers.StatelessProvider`; harness providers (when they exist) need a separate code path that calls `StartSession` / `SendInSession`.

- **`internal/conversations` `var _ = time.Now`** in service.go is a leftover safety-net for an import that's now genuinely used. Cleanup nit; harmless.

### Drivers not yet built

- **`claude-code-subprocess` driver** — package doesn't exist. Stateful provider; would manage a `claude` CLI process per session, talk to it via NDJSON over stdio, expose the `--list-models` (or hardcoded) catalog. Community reference: `severity1/claude-agent-sdk-go`.
- **`codex-subprocess` driver** — package doesn't exist. Same shape as above; talks to Codex CLI via JSON-RPC over stdio. Community reference: `hishamkaram/codex-agent-sdk-go`.

---

## Strategic deferrals (also in architecture.md "Open threads")

Recorded here for grep-ability; the canonical discussion is in [architecture.md](architecture.md):

- **Resource sharing model** — v1 is per-user-only. Add `visibility = {private, shared}` on `user_model_providers` when a second user actually exists.
- **Encryption Tier B** — per-user keys derived from the password (envelope wrapping). Tier A (column at rest via `internal/crypto`) is shipped on `user_model_providers.config_encrypted` and `user_langfuse_config.secret_key_encrypted`; Tier B is the next step if the threat model grows past "operator with logical DB access shouldn't see plaintext."

---

## MCP server (v1 shipped — `internal/mcpserver`)

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
`Reeve Manager` profile dispatches to the local server with no port
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

## Elicitation (inproc shipped — `internal/elicit` + the broker)

MCP elicitation lets a server tool request additional input from the
user mid-call without that input ever entering LLM context. Reeve
ships the inproc-transport flavour today:

* `internal/elicit` holds the protocol types (`Request`, `Response`,
  `Client` interface, ctx helpers). Lives in its own package so both
  `mcpserver` (publishes the `ctx.Elicit` hook to tool fns) and
  `internal/conversations` (provides the broker implementation) can
  import without creating a cycle.
* `internal/conversations.elicitBroker` routes responses: tools
  block on a channel; the user-facing endpoint writes into it. 5-minute
  timeout per request.
* `providers.ChunkElicit` is the new stream chunk type the tool loop
  emits before blocking; flows through the supervisor → client like
  any other chunk.
* `POST /conversations/{id}/elicitations/{eid}/respond` is the
  user-facing endpoint. Same Bearer-token auth as the Connect surface;
  ownership-checked against the conversation row.
* `ElicitSheet` (ReeveUI) renders a JSON-Schema-driven form. Handles
  string / boolean / integer fields; string + `format: password`
  renders as a SecureField (the secrets use case).
* `ElicitationsRepository` (ReeveKit) POSTs the response.
* Mac + iOS conversation views mount the sheet via `.sheet(item:)`
  bound to the first pending elicit on the active stream.

First tool using it: `create_user_model_provider` — Reeve Manager can
add a provider end-to-end without the API key ever entering chat
content, the model's context, or DB-persisted message rows. The
secret flows user → client UI → POST → tool's local stack frame →
provider config encryption → discarded.

Deferred:
- **Elicitation over HTTP transport** — needs SSE response framing
  on server-initiated requests + a paired POST channel for client
  responses. Inproc is sufficient for Reeve's own assistant
  (Reeve Manager via local `/mcp`); remote MCP clients calling
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
chunked fake-stream reveal (`WelcomeReveal` in ReeveUI), subsequent
opens render statically.

Seed file format extended with YAML-style frontmatter so a single
`.md` template can carry both `welcome_message` and the system
message body. Tiny custom parser (`internal/profiles/seed_format.go`,
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
Shared SwiftUI view in ReeveUI; both platforms render the same
flow.

Important fix folded in: the stream supervisor's detached run
context now carries the authenticated user through, so inproc MCP
tool calls (Reeve Manager's `mcp` plugin → local /mcp surface)
resolve identity correctly during background tool dispatch.

## System profiles + capability enforcement (v1 shipped)

Two seeded profiles materialize on first login (Personal Assistant +
Reeve Manager). Backed by `users.system_profiles_seeded`; idempotent;
the user can edit, rename, or delete them like any other profile —
deleted ones don't resurrect on next login. Templates live in
`internal/profiles/seeds/*.md`.

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
- **`REEVE_CATALOG_REFRESH_INTERVAL` smoke-tested only at "0" (disabled).** Periodic refresh path not exercised in tests.
- **`ListConversations` pagination** — `page_size` capped at 100, `page_token` ignored (returns all in one page). Real pagination deferred.
- **`ListProviderTypes` `display_name`** — currently humanized via `humanizeName`. Could come from driver metadata if drivers exposed a `DisplayName()` method.
- **`ListProviderTypes` `config_schema`** — empty bytes for v1; UI hardcodes config forms. JSON Schema generation per-driver is a future ergonomic win.
- **Unit-tested `internal/store` queries** — no direct tests of the sqlc-generated layer (covered transitively by every service test).

- **Apple Foundation Models on-device titler — open follow-ups.** Mac client is wired; (a) extend `LocalTitler` with iOS-side implementation when an iOS app exists; (b) consider falling back to the configured cloud title model when `AppleFoundationTitler.isAvailable` returns false (today the kind sentinel is "all-or-nothing"); (c) the trigger uses the local cached profile map for parent-chain resolution — if the profile cache is empty it skips silently, which is fine for the Mac startup flow but worth flagging.

- **Anthropic SDK upgrade for native `ttl` field.** The `AnthropicExtras.cache_ttl` follow-up shipped the 1-hour TTL via the SDK's `metadata.SetExtraFields` escape hatch (anthropic-sdk-go v1.4 doesn't expose `ttl` on the non-beta `CacheControlEphemeralParam` directly — the beta path does). The escape hatch produces the correct wire payload (`"cache_control":{"type":"ephemeral","ttl":"1h"}`), but it's brittle: if the SDK adds a typed `TTL` field in a later release, the marshalling could double-emit or conflict. Drop the `SetExtraFields` call in `internal/providers/anthropic/send.go::applyAutoCacheControl` once the SDK exposes a typed `TTL` field, or alternatively switch the driver to the `betamessage` API (which already has `BetaCacheControlEphemeralTTL`).

- **Mac chat surface may share the iOS cold-entry phantom-scroll bug.** iOS fix (tail-window + staged backfill + `defaultScrollAnchor` + `isPositionedByUser`, `clients/reeved-ios/.../ConversationView.swift`, commits fe92a7d + follow-up) addresses LazyVStack handing the bottom anchor an estimated content size with phantom blank space below the last message. The Mac ConversationView uses its own scroll plumbing — audit it for the same realize-from-top + estimate-inflation class and port the tail-window approach if long chats land past the content end. iOS-first per current priorities.

- **Per-context cache-savings cost split (`ContextListView.swift`).** The contexts page metadata strip currently shows total `cumulativeCostUsd`. The Model Settings work added cache observability to per-message popovers (computed client-side as `cache_read_tokens × input_price × discount` where the discount is 90% on Anthropic and 50% on OpenAI/Google). Doing the same per-context aggregate client-side would require summing across all messages in the context — fine but expensive on large contexts. Cleaner fix: extend the per-context aggregate the server stamps on `ReeveContext` (alongside `cumulativeCostUsd` and `lastMessageTotalTokens`) to also surface `cache_savings_usd` (or a `would_have_cost_usd`). Then the chip on each row shows "billed $X · saved $Y" cleanly. Frontend has a TODO comment in the metadata strip already.

---

## Plugin hook ideas

Captured after surveying the existing `plugins.Plugin` surface (`Configurable`, `SystemPrompter`, `OutgoingUserTransformer`, `HistoryTransformer`, `ChunkTransformer`, `DisplayTransformer`, `AssistantContentTransformer`, `ToolProvider`, `MessageLifecycleHook`).

### Worth designing now

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

`ContentRenderer` is the bigger piece (proto change, Swift component scaffolding, action-dispatch wiring) — worth deferring until at least one plugin's needs (`lettered_choices`'s choice cards is the clearest candidate) drives the schema. `PreSendContextInjector` once a concrete RAG/memory plugin pulls on it.

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
