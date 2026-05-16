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

- **`internal/providers/anthropic`** — tool-use input is one-way: outbound `tool_result` blocks not yet translated from `WireMessage`. `signature_delta` and `citations_delta` events silently dropped (no normalized chunk slot). `MessageDeltaEvent` (usage / stop_reason) not surfaced — needs a chunk type when added.

- **`internal/providers/openai`** — tool use tracks one active call (parallel tool calls would need a map keyed by `output_index`). `TokenCounter` intentionally not implemented (no consistent endpoint across compat servers, no tiktoken helper in `openai-go`). Thinking round-trip only works when stored shape matches Responses-API `ResponseReasoningItem`; cross-shape thinking silently omitted.

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

## Smaller items

- **Connect server-streaming via raw curl** doesn't pretty-print — Connect's wire format isn't plain newline-delimited JSON. For terminal smoke testing, write a small `clarkctl` helper or use `buf curl` to subscribe to streams.
- **`REEVE_CATALOG_REFRESH_INTERVAL` smoke-tested only at "0" (disabled).** Periodic refresh path not exercised in tests.
- **`ListConversations` pagination** — `page_size` capped at 100, `page_token` ignored (returns all in one page). Real pagination deferred.
- **`ListProviderTypes` `display_name`** — currently humanized via `humanizeName`. Could come from driver metadata if drivers exposed a `DisplayName()` method.
- **`ListProviderTypes` `config_schema`** — empty bytes for v1; UI hardcodes config forms. JSON Schema generation per-driver is a future ergonomic win.
- **Unit-tested `internal/store` queries** — no direct tests of the sqlc-generated layer (covered transitively by every service test).

- **Apple Foundation Models on-device titler — open follow-ups.** Mac client is wired; (a) extend `LocalTitler` with iOS-side implementation when an iOS app exists; (b) consider falling back to the configured cloud title model when `AppleFoundationTitler.isAvailable` returns false (today the kind sentinel is "all-or-nothing"); (c) the trigger uses the local cached profile map for parent-chain resolution — if the profile cache is empty it skips silently, which is fine for the Mac startup flow but worth flagging.

- **Anthropic SDK upgrade for native `ttl` field.** The `AnthropicExtras.cache_ttl` follow-up shipped the 1-hour TTL via the SDK's `metadata.SetExtraFields` escape hatch (anthropic-sdk-go v1.4 doesn't expose `ttl` on the non-beta `CacheControlEphemeralParam` directly — the beta path does). The escape hatch produces the correct wire payload (`"cache_control":{"type":"ephemeral","ttl":"1h"}`), but it's brittle: if the SDK adds a typed `TTL` field in a later release, the marshalling could double-emit or conflict. Drop the `SetExtraFields` call in `internal/providers/anthropic/send.go::applyAutoCacheControl` once the SDK exposes a typed `TTL` field, or alternatively switch the driver to the `betamessage` API (which already has `BetaCacheControlEphemeralTTL`).

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
