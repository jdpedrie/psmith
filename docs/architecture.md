# Reeve — architecture and design decisions

Reeve is a self-hosted AI chat orchestrator with a server + thin clients architecture, for John's personal use.

## Topology
- **Server** (source of truth): owns model/provider catalog, all API interactions, all conversation/message storage.
- **Clients** (thin): web, desktop, iOS — planned.

**Primary motivation for the server/client split: stream resilience for iOS.** When the iOS app backgrounds, the OS kills its network connections — losing the in-flight provider stream. Routing all provider traffic through the server means the server consumes the upstream stream to completion regardless of client state, and clients can disconnect/reconnect freely without losing tokens. See "Streaming subsystem" below.

## Stack
- **Server lang:** Go.
- **Storage:** Postgres.
- **Transport:** ConnectRPC (chosen for first-class Go/TS/Swift codegen, browser support without a gRPC-Web proxy, and clean server-streaming for token streams). Streaming responses are `stream` RPCs from day one — don't retrofit.
- **Durable execution / Temporal:** explicitly not adopted. Reconsidered specifically against the resumable-streams requirement; the rejection sharpens rather than weakens. Temporal's value is *execution durability* — workflows resume on a different worker after process death. But the upstream provider stream is held open by an HTTP socket (or harness subprocess pipe) bound to the live process; when the process dies, the socket dies, and no workflow framework can revive it. The hard problem we actually have — *token durability + client reconnection* — is solved by `INSERT INTO stream_chunks` and an in-process pub/sub broker. Adopting Temporal would add a Temporal cluster's worth of operational burden to do a job a goroutine and a table already do. Revisit only if Reeve grows multi-step agent orchestration with independently-resumable steps, multi-process work distribution, or complex cross-conversation scheduled jobs.

## Provider model
Three layers, intentionally separate so each can evolve independently.

- **Provider type / driver** = compile-time Go interface implementation (`openai-compatible`, `anthropic`, `claude-code-subprocess`, `codex-subprocess`, …). Adding a new type = write Go, recompile. Drivers are constructed with `providers.Deps{Catalog, Logger}` so they can enrich discovered models with catalog metadata.
- **`UserModelProvider`** = runtime config of a driver type owned by a single user (creds, endpoint, label). Many can coexist per user (e.g. several OpenAI-compatible endpoints, an Anthropic key, a Groq instance).
- **`UserModel`** = a model the user has explicitly enabled on one of their providers. Owns its own metadata snapshot (see "Model catalog" below).

## Model catalog & enabled models

The catalog (refreshed periodically from [models.dev](https://models.dev)) is the canonical source for model metadata: context window, max output, pricing, capabilities, modalities, knowledge cutoff. It also surfaces *provider templates* (preconfigured driver-type + base URL pairs) to accelerate "add provider" UX for compatible endpoints (Groq, Together, Fireworks, OpenRouter, Ollama, etc.).

**Tables (read-only reference data):**
- `catalog_model_providers` — one row per known provider id from models.dev
- `catalog_models` — one row per (provider, model) with full metadata + raw blob

**Refresh:**
- On startup: synchronous fetch if catalog is empty (server isn't useful otherwise); skipped if already populated.
- Periodic: `time.Ticker` goroutine. `REEVE_CATALOG_REFRESH_INTERVAL` env var (default 24h, set 0 to disable).
- Manual: admin-only `RefreshModelCatalog` RPC.
- Idempotent upsert; partial failure leaves stale-but-valid data in place.

**Snapshot semantics for user-enabled models** — `user_models` is **not** FK'd to `catalog_models`. When a user enables a model, the server snapshots the metadata at that moment (from catalog if known; from driver discovery if not; or `manual` for hand-authored entries). The snapshot lives in `user_models` and is editable. Catalog refreshes do not silently mutate enabled models — users can re-snapshot via an explicit `RefreshUserModelMetadata` action.

This guarantees: (a) catalog rows can come and go without breaking user setups; (b) pricing changes don't surprise users; (c) hand-edits stick; (d) "manual" models work on the same code path.

**Provider templates** are surfaced via `ListProviderTemplates`. Each template maps a catalog provider to a Reeve driver type (e.g., `groq` → `openai-compatible` with `api_base` prefilled). The UI uses these to skip the "what's the base URL?" friction.

## Stateless vs stateful providers — first-class divergence
- **Stateless providers** (HTTP APIs): server owns canonical history, sends full relevant prefix every turn. Supports forking, per-message model switching, full plugin pipeline.
- **Stateful harness providers** (Claude Code, Codex, etc.): chat is bound to a harness `session_id`; harness owns canonical context. Server only sends the latest message to the harness. Server's stored history is **informational only** (for display), and is allowed to drift from the harness's session.
  - **Forking and per-message model switching are explicitly disallowed** for harness-backed chats. Trade accepted to keep the harness session coherent.
  - Plugin history transforms in this mode can only operate on the single outgoing message, not on history (the harness owns history, not Reeve).

## Data model: Conversation / Context / Message

```
Conversation
  ├─ Profile (with single-parent inheritance chain)
  ├─ Context (many; the one with the latest context_activation_time is "active")
  │    └─ Message (tree via parent_id, scoped to its Context)
```

- **Conversation** — top-level chat resource.
- **Context** — represents a coherent history horizon (the slice of conversation built up since the last compression). Contains messages.
- **Message** — unit of content; belongs to a Context; tree-shaped via `parent_id` within that Context.
- **Active context** = the Context with the latest `context_activation_time`. No `is_active` boolean — single ordering source. Only one Context is conceptually active at a time. Reactivating an older Context = update its activation_time. Forking from an older Context implicitly reactivates it; user accepts the resulting message-tree messiness as their problem to manage.
- **History-builder always builds from the active Context only.** Older Contexts are archived; their content is captured by the chain of compression summaries (if APPEND) or by the latest summary alone (if REPLACE).

### Message fields
- `content` — visible text.
- `thinking` — `jsonb`, nullable. Opaque per-provider shape (preserves Anthropic encrypted signatures, OpenAI Responses reasoning items, Gemini variants — no lossy normalization).
- `thinking_provider_type` — which provider type produced the thinking (drives cross-provider filtering rule).
- `role` — see roles below.
- `edited_at` — `timestamptz`, nullable. Set by `EditMessage`; UI surfaces "edited <relative time>" only when non-null. Audit trail; doesn't affect history-builder output.
- `parent_id`, `context_id`, etc.

### Editing & deleting messages
- **`EditMessage(id, content, role?)`** mutates a message in place. `content` always editable for any role. `role` is optionally overridable but only between `user` and `assistant` — `system`, `context`, and `compression_summary` cannot be transmuted into or out of (they're structural framing rows, not turns). Sets `edited_at = NOW()`. `raw_content`, `thinking`, `usage`, and `cost` are preserved (audit trail). Cache observability detects the change naturally on the next `SendMessage` (the trailing-edge depth metric reports honestly).
- **`DeleteMessage(id, cascade=false)`** removes a message. Default `cascade=false` "stitches" — direct children are reparented to the deleted row's parent (filling the gap), then the row is deleted (TX). `cascade=true` removes the descendant subtree via the FK's `ON DELETE CASCADE`. Strong client confirmation expected on both, especially cascade=true.
- **Schema:** `messages.parent_id` has `ON DELETE CASCADE`; `stream_runs.parent_message_id` and `stream_runs.result_message_id` have `ON DELETE SET NULL` so historical run rows survive a referenced-message delete (with the dangling link nulled).
- **Conversation lock:** every mutating RPC (`SendMessage`, `EditMessage`, `DeleteMessage`, `Compact`, `PromoteCompactionToNewContext`, `ActivateContext`, `SetCurrentLeaf`, `UpdateConversation`, `DeleteConversation`) checks for any `stream_run` with `status='running'` on the conversation and rejects with `FailedPrecondition` if found. Server-side enforcement of the UI's "all conversation actions disabled while a stream is in flight" rule.

### Message roles
- **`role=system`** — Profile's system message, *snapshotted into the Context at creation*. The first message in any Context. Sent via the provider's system slot (or top-of-list per driver). Plugin `SystemPrompter`s contribute prepend/append text here at prefix-build; plugin `HistoryTransformer`s do not run on this row.
- **`role=context`** — Synthetic framing messages. Two sources: (1) Profile's default user message, snapshotted into the Context at creation; (2) compression summaries. Always wire-mapped to `role=user` at send time. Plugin transforms skip.
- **`role=user`** / **`role=assistant`** — Regular conversation turns. Plugin transforms apply.
- (Future: `role=tool` for tool use.)

### Message tree & branch navigation

Messages within a Context form a tree via `parent_id`. Linear conversations are degenerate trees (each parent has one child); forking (sending a new message with `parent_message_id` pointing at a non-leaf) creates branches.

**Per-context current leaf.** Each Context has a `current_leaf_message_id` (nullable UUID, FK to messages, `ON DELETE SET NULL`). Semantically: "the tip the user is currently viewing in this context." It's the parent for the next `SendMessage` if the client doesn't specify one explicitly. Stored server-side so multi-device clients converge on the same current view (matches the "server is source of truth" principle).

**`SendMessage` parent resolution chain:**
1. `request.parent_message_id` if set (explicit fork or continue).
2. Else `current_leaf_message_id` of the active context (if non-null).
3. Else latest message by `created_at` in the active context (fallback for fresh contexts).

**`SendMessage` always updates `current_leaf_message_id`** to the just-inserted user message — the cursor advances naturally on each turn.

**Branch switching flow:**
1. Client renders the path (root → current_leaf), with fork indicators on messages whose `sibling_count > 0` (computed in the same recursive CTE that returns the path).
2. User clicks a fork indicator and picks an alternate child.
3. Client picks where in that branch to land (default: deepest descendant of the alternate child's subtree — most chat UIs feel right when "go to branch" lands at the latest activity there).
4. Client calls `SetCurrentLeaf(context_id, target_message_id)`.
5. Server validates the message belongs to the context, updates `current_leaf_message_id`.
6. Client re-renders by calling `ListMessages(context_id, leaf_message_id=target)` — the recursive CTE returns the new path.

**Reactivating an old context** preserves its `current_leaf_message_id` — the user lands back where they left off.

**Compression creates a new context with `current_leaf_message_id = null`** — first `SendMessage` falls through to the latest-by-created_at fallback (which is the seeded `role=context` message), then the cursor advances normally from there.

**A message referenced by `current_leaf_message_id` getting deleted** → `ON DELETE SET NULL` clears the column; the fallback chain catches it on the next `SendMessage`.

### Thinking handling
*(Applies to stateless-provider chats only. Stateful harness chats — Claude Code, Codex — let the harness own reasoning state; Reeve never round-trips thinking for those.)*

- `include_thinking_in_history` is a **per-conversation setting**, not per-turn (toggling busts cache for the prefix from that point forward). **Default: off** — matches the typical use case where deep thinking lives on harness backends anyway.
- Each message stores `thinking` (`jsonb`, raw per-provider shape including Anthropic signatures), `thinking_provider_type`, and `thinking_rendered_text` (plain-text rendering, generated once on inbound by the producing driver via `RenderThinkingToText`, deterministic and cache-stable).
- History-builder rule when setting is on:
  - **Destination provider type == producing provider type** → include thinking in **native format** (signed Anthropic blocks, OpenAI reasoning items, etc.). Preserves integrity guarantees (Anthropic signature validation, OpenAI reasoning-item semantics) and lets the model treat its prior reasoning as authoritative.
  - **Destination ≠ producer** → inject `thinking_rendered_text` into the assistant turn's `content`, prepended with a delimiter, e.g.:
    ```
    [prior reasoning by claude-opus-4-7]
    {rendered text}
    [/prior reasoning]

    {original content}
    ```
    Receiving model treats it as informational context, not as its own reasoning. No fabricated signed thinking is ever sent to a provider that didn't produce it.
- History-builder rule when setting is off: thinking and rendered text are both omitted.

### Thinking × tool use coupling (deferred)
Anthropic requires thinking blocks to be preserved adjacent to their `tool_use` blocks across turns. This means in a tool-using conversation, `thinking` and `tool_use` are structurally one unit and `include_thinking_in_history=false` could break tool-use sequences. Schema must let thinking and tool_use attach to the same assistant turn and be sent or omitted together. Full handling deferred until tool use is added as a feature.

### Plugin transforms × thinking
Plugin transforms operate on message `content` only. **`thinking` is immutable post-storage** — mutating it would break Anthropic's signature irreversibly and has no defensible cross-provider semantics. (Display-time mutations of thinking, if needed, happen via the same client-side rendering that handles content; plugin display transforms run on `content` only.)

## Profiles
- A Profile bundles configuration applied to a Conversation. Fields:
  - **System message** — placed into the Context as a `role=system` row at Context creation.
  - **Default user message** — placed into the Context as a `role=context` row at Context creation. Rides forward through APPEND-mode compressions.
  - **Compression guide** — the prompt/template that drives the compression model.
  - **Compression model override** — which model performs compression; falls back to a sensible default (e.g., the current chat model) if unset.
  - **Compression mode** — REPLACE or APPEND.
  - **Default chat settings** — default model, `include_thinking_in_history`, etc.
- **Single-parent inheritance.** Profile B inherits from Profile A; child overrides parent per field. Resolution: walk the parent chain, first non-null wins per field.

## Compression
- **First-class structural operation, not a transform.** Eventually creates a new Context (parented to the source) and activates it.
- **Two-stage flow.** `ConversationsService.Compact` runs the compression LLM call and writes a `role=compression_summary` message into the source Context — and stops. The summary is editable (`EditMessage`) and deletable (`DeleteMessage`) so the user can tidy or bail. While the source Context contains a `compression_summary`, `SendMessage` and `Compact` on it are rejected with `FailedPrecondition` — the user has exactly two ways forward: delete the summary (resume the source) or call `PromoteCompactionToNewContext(message_id)` (commit to the split).
- **`PromoteCompactionToNewContext`** creates the new Context (parent = source, activation_time = NOW, current_leaf = NULL) and seeds it with a single `role=context` message whose content is computed from the (possibly user-edited) summary using the profile's `compression_mode`. Idempotency is intentionally not enforced — calling twice produces two parallel new contexts seeded from the same summary ("compact and try two directions").
- **Manually triggered by the user.** No automatic compaction. UI must surface total token count for the active Context and the destination model's context window so the user can decide when to compact.
- **One summary per compression event** (per-Context, not per-destination-model). Accepts the over-compression cost when the next model has a bigger window than the one compression was sized for.
- **REPLACE mode**: the new Context's `role=context` framing is the compression summary alone.
- **APPEND mode**: the new Context's `role=context` framing is the source Context's `role=context` content + `"\n\n"` + the summary. Framing chains forward across compressions.
- Compression mode and compression-model override resolve through the Profile inheritance chain.
- The `compression_summary` row in the source Context is **always** retained as audit/cost record (it carries the run's usage + cost). History-builder skips it. If the user later reactivates the source Context, the summary still gates `SendMessage` until they explicitly delete it.

## Auto-titles

Conversations and contexts can be automatically titled by a small, cheap LLM call after the first assistant turn. The feature is **opt-in** via three nullable, parent-chain-inheritable profile fields: `title_provider_id`, `title_model_id`, `title_guide`. When any of the three resolves to NULL post-inheritance the feature is silently skipped — explicit configuration is required to enable it.

**Trigger:** the supervisor's `materializeAssistant` fires an `OnAssistantMaterialized` callback in a detached goroutine after every assistant message lands. The conversations service registers a callback that:

1. Loads the conversation and the active context.
2. Decides whether each needs a title:
   - Conversation needs one when `conversation.title` is NULL.
   - Context needs one when `context.title` is NULL **and** the just-materialized assistant is the only assistant in that context (i.e., this was the first turn for the context). The "first-only" guard is what handles post-compaction contexts: each new context gets one title call when its first assistant turn lands, and never again.
3. Resolves the profile chain to find the title configuration. Skips silently if not configured.
4. Builds a tiny transcript (the just-materialized assistant message + its parent user message) and calls the configured small model with `system=title_guide` + that transcript.
5. Sanitizes the model's output (trim, strip wrapping quotes, collapse whitespace, cap at ~80 chars at a word boundary) and persists via `UpdateConversationTitle` and/or `UpdateContextTitle`.

A single LLM call covers both targets: when the conversation and the initial context both need a title, the same generated string is used for both. After compaction → promotion, only the new context's title is generated (conversation title persists across compactions; it labels the long-running thread).

**Cost shape:** typically 50-200 tokens per call against a Haiku/4o-mini-class model. For 1,000 conversations a year that's pocket change. Failure (model error, missing model, etc.) logs and leaves the title NULL — the next-turn UI just falls back to "Untitled" or a first-message snippet.

**User overrides:** titles are editable at any time via `UpdateConversation(title=...)` and `UpdateContext(title=...)`. Auto-generation never overwrites a non-NULL existing title.

## Streaming subsystem

The server is the producer that consumes the upstream provider/harness stream into durable Postgres state. Clients are subscribers that can disconnect/reconnect arbitrarily without losing tokens. This is the load-bearing mechanism for iOS-app-backgrounding resilience.

```
┌──────────────┐    ┌────────────────────────┐    ┌──────────────┐
│  Provider    │───▶│  Stream supervisor     │───▶│  Postgres    │
│  (Anthropic, │    │  (goroutine per run)   │    │  stream_runs │
│   OpenAI,    │    │                        │    │  + chunks    │
│   harness…)  │    │  + in-process pub/sub  │    └──────────────┘
└──────────────┘    └─────────┬──────────────┘            │
                              │                            │
                              ▼                            │
                       ┌──────────────┐                   │
                       │  Subscribers │◀──────────────────┘
                       │  (clients)   │   (replay from
                       └──────────────┘    sequence N)
```

### Invariants
- **Server reads the upstream to completion regardless of client state.** Client disconnect does not interrupt the upstream consumer.
- **Each in-flight stream has a `stream_run_id`.** Clients subscribe via this ID and a `from_sequence` cursor.
- **Chunks persist in order with monotonic sequence numbers.** Subscribers replay missed chunks from Postgres, then live-tail via in-process pub/sub.
- **Final state lives in `messages`.** When the stream terminates (any status), accumulated content/thinking is materialized into the assistant message row. `stream_chunks` are transient — pruned after finalization plus a small safety window for very-late reconnects.
- **Applies uniformly to stateless providers and stateful harnesses.** Both stream their output through this pipeline.

### Schema
```sql
stream_runs (
  id, conversation_id, context_id, parent_message_id,
  provider_instance_id, model_id,
  status,          -- running | completed | errored | cancelled | interrupted
  started_at, ended_at,
  error_payload jsonb,
  result_message_id  -- FK to materialized assistant message
)

stream_chunks (
  stream_run_id, sequence, chunk_type, payload jsonb,
  PRIMARY KEY (stream_run_id, sequence)
)
```

### Chunk normalization
Drivers translate provider-specific stream events (Anthropic `content_block_delta`, OpenAI Responses `response.output_text.delta`, harness NDJSON lines, etc.) into a small normalized chunk vocabulary: `text_delta`, `thinking_delta`, `tool_use_*`, `error`, `done`. Clients see a uniform shape regardless of provider.

### Lifecycle
- **Initiating a turn** is two steps that always happen in this order:
  1. Handler inserts the user-message row in the DB (transactional). Once this commits the user's typed text is durable — never lost to upstream issues.
  2. Handler builds a `SendFunc` closure (captures driver + wireMessages + settings) and calls `supervisor.Start`. Start synchronously creates the `stream_runs` row and spawns the supervisor goroutine, then returns the `stream_run_id`. The handler returns immediately.

  The supervisor goroutine drives the upstream call asynchronously. iOS apps can fire-and-forget the send, background, and return later to subscribe.
- **Pre-first-token retry**: the supervisor calls `SendFunc` up to `MaxSendAttempts` (3) with exponential backoff (1s, 2s). Each attempt has a `PerAttemptTimeout` (60s) budget covering BOTH the call returning AND the first chunk arriving on the channel. A first chunk that's `ChunkError` counts as failure (some SDKs surface HTTP errors that way). Errors aren't classified — a permanent error like 401 burns through 3 attempts in a few seconds; transient errors get up to two recoveries.
- **Pre-first-token exhaustion**: after retries are out, the supervisor's `syntheticErrorStream` emits a `ChunkError + ChunkDone` so the normal aggregator materializes an errored assistant message inline (`messages.error_payload` populated). Reload becomes the user-visible retry surface.
- **Mid-stream errors** → no automatic retry (most providers cannot resume a partial generation). Status set to `errored`; user decides whether to retry from scratch via Reload.
- **Cancellation** → client sends cancel; supervisor stops consuming (cancellation propagates into the retry-helper's `select` on `<-parent.Done()` so it works mid-backoff too), status set to `cancelled`, partial content materialized into a message row.
- **Server restart** → on startup, all `running` rows are flipped to `interrupted` (the upstream socket died with the process; nothing can be done but retry). User sees the partial assistant message + a retry affordance.

The retry policy lives in `internal/stream/send_retry.go`. Constants are package-level vars (not consts) so tests can shrink them to milliseconds — `shrinkRetryConfigForTest` is the test-local fake clock.

### Subscriber transport
ConnectRPC server-streaming RPC: `SubscribeStream(stream_run_id, from_sequence) → stream<Chunk>`. On subscribe, the server first replays from Postgres up to the live cursor, then switches to the in-memory broker for live tailing. Single-process deployment — no need for Postgres LISTEN/NOTIFY.

### Write granularity
Buffer chunks in the supervisor and flush to Postgres on a 50ms window or 16-chunk batch (whichever first). Final flush on stream end regardless. Acceptable to lose <50ms of chunks on a hard crash because the same scenario already produces an `interrupted` status that requires retry.

## Chat plugins

A **chat plugin** is the unit of customization for how Reeve shapes a conversation: it can contribute to the system prompt, transform outgoing user messages before send, mutate stored history at prefix-build time, process inbound chunk streams, transform stored content for display, and provide tools the model can call. Bundling these capabilities under one plugin (instead of treating each as a separate primitive) is deliberate — features like "interactive lettered choices" need a system-prompt instruction, an outbound history-strip, and a display rewrite to all stay coherent. Putting them in one config row is the only way they don't drift.

### Required surface and opt-in capabilities

The required `Plugin` interface is intentionally tiny — name + description. Every behavior is a separate opt-in interface, detected by type assertion at the call sites that care:

```go
// Required for every plugin.
type Plugin interface {
    Name() string
    Description() string
}

// Opt-in: per-instance configuration. Plugins without parameters skip this.
type Configurable interface {
    ConfigSchema() []byte                  // JSON Schema for the UI form
    LoadConfig(json.RawMessage) error
}

// Opt-in: contribute to the system message at prefix-build time.
type SystemPrompter interface {
    PrependSystemMessage() string
    AppendSystemMessage() string
}

// Opt-in: rewrite the outgoing user message before send.
// Use case: user types "A", plugin expands to "I choose option A".
type OutgoingUserTransformer interface {
    TransformOutgoingUserMessage(content string) string
}

// Opt-in: rewrite a history message at prefix-build time.
//
// HistoryPos carries both raw position and same-role rank. FromHead counts
// ALL messages back from the head (the message about to elicit a response);
// FromHeadSameRole counts only messages with the same wire role. The
// same-role rank is the right metric for role-aware policies like "keep
// choices on the last N assistant turns" — it's stable under forks or
// future tool-message interleaving where alternation can't be assumed.
type HistoryPos struct {
    FromHead         int
    FromHeadSameRole int
}
type HistoryTransformer interface {
    TransformHistoryMessage(msg WireMessage, pos HistoryPos) WireMessage
}

// Opt-in: chunk-in, chunk-out stream processor. NewInboundProcessor returns
// a fresh per-stream instance so internal state is isolated.
type ChunkTransformer interface {
    NewInboundProcessor() InboundProcessor
}
type InboundProcessor interface {
    Process(Chunk) []Chunk // 0..N chunks out per chunk in (buffering OK)
    Close() []Chunk        // emit any buffered residue at stream end
}

// Opt-in: rewrite stored content for display, run at message-fetch time.
// Position-independent — the same input always produces the same output for
// a given plugin config.
type DisplayTransformer interface {
    TransformForDisplay(content string) string
}

// Opt-in: declare callable tools and execute them. The supervisor collects
// Tools() across active plugins to build the wire `tools` array; when the
// model emits tool_use it dispatches to the plugin owning that tool name.
type ToolProvider interface {
    Tools() []ToolDef
    ExecuteTool(ctx context.Context, name string, input json.RawMessage) (json.RawMessage, error)
}
type ToolDef struct {
    Name        string
    Description string
    InputSchema []byte // JSON Schema; goes verbatim into the provider's `tools` field
}
```

A plugin implements as many of these as it needs. The runtime never asks a plugin to do something it didn't sign up for.

### Where each capability runs

- **`SystemPrompter`** runs in `history.Build`, contributing to the system slot before driver-specific shaping.
- **`OutgoingUserTransformer`** runs in `SendMessage`, after the user's content lands in the request and before it's persisted as a `messages` row. Stored content is the transformed form (so future renders show the expanded version).
- **`HistoryTransformer`** runs in `history.Build`, per-message, with position relative to the head (both absolute `FromHead` and same-wire-role `FromHeadSameRole`). Same-role rank is what makes "keep choices on the last N assistant turns" robust under forks or any future role mix.
- **`ChunkTransformer`** runs inside the stream supervisor, between upstream chunk read and persist/fan-out. Stateful patterns (strip-between-tags, accumulate-then-emit) buffer chunks internally; the persisted `content` reflects the transformed output.
- **`DisplayTransformer`** runs in the message-fetch path (`ListMessages`, `GetMessage`), producing a `display_content` field alongside stored `content`. Server-side so display logic isn't smeared across clients.
- **`ToolProvider`** is collected by the supervisor at request build (Tools()) and dispatched-to during chunk processing (ExecuteTool when a `tool_use` block lands). End-to-end execution requires the deferred outbound tool-result wire translation; the interface is settled now so tool plugins can be written before that lift completes.

### What gets stored

The split between raw and transformed remains:

- **`raw_content` / `raw_thinking`** on `messages`: the upstream provider's output, reconstructed from chunks at stream finalization. Pre-`ChunkTransformer`. Audit/debug trail.
- **`content` / `thinking`** on `messages`: post-`ChunkTransformer` (i.e., what the inbound chunk pipeline emitted). For the user-message side, content is the post-`OutgoingUserTransformer` form. This is what feeds future history-builds and display.
- `thinking` is **never** mutated by a plugin (would break Anthropic signatures; see "Plugin transforms × thinking").

### Position-dependent transforms compute on demand

`HistoryTransformer` is position-aware, which means **its output cannot be precomputed and stored**. A "keep-choices-on-the-last-N" transform produces different bytes for the same message depending on whether the message is currently the head, the head's parent, the head's grandparent, etc. There is no canonical "transformed" version to store; there's a different one per (message, distance-from-head, plugin-set) tuple, and the head moves every turn.

So:
- **Inbound chunk transforms must be persisted** — the chunk stream is gone after consumption, no recomputation possible.
- **Outbound history transforms must run on demand** — position-dependent, can't be precomputed meaningfully.
- **Display transforms run on demand** — position-independent and could be cached per-(message, plugin-set) if profiling ever shows it as a hot spot, but for typical conversation lengths the per-message string ops are microseconds and not worth a cache yet.

### Pairing happens inside one plugin

The architecture's earlier framing of "pair an outbound user-side transform with an inbound assistant-side transform" was right but two-piece. With plugins, a paired feature is one plugin implementing both the outbound side (e.g., `OutgoingUserTransformer` or `SystemPrompter`) and the inbound side (`ChunkTransformer`). Single config row, single source of truth for the format contract.

### Configuration and scope

Plugins attach to **profiles** — same scope as compression settings, with the same parent-chain inheritance semantics. A `profile_plugins` table holds the ordered pipeline:

```sql
CREATE TABLE profile_plugins (
    profile_id  UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    ordinal     INTEGER NOT NULL,    -- pipeline position within the profile
    plugin_name TEXT NOT NULL,       -- registered name, e.g. "strip_old_choices"
    config      JSONB,               -- plugin-specific blob; null = config-free plugin
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (profile_id, ordinal)
);
CREATE INDEX profile_plugins_name ON profile_plugins (plugin_name);
```

Inheritance is **all-or-nothing**: if a profile has any rows in `profile_plugins`, that's its full plugin pipeline; otherwise it inherits the parent profile's pipeline (recursively). Mirrors how `NULL` on compression columns means "inherit." A child profile that wants to *modify* the parent's list copies the parent's rows and edits — explicit beats implicit-merge for ordering correctness.

Ordering across phases: the profile's pipeline order is the iteration order for every phase. If `[A, B, C]` is the list, `SystemPrompter`s execute A → B → C, `HistoryTransformer`s execute A → B → C per message, etc. Plugins not implementing a phase are skipped for it. This keeps reasoning simple — one number to think about per profile.

Profile-only scope is the v1 cut. Provider-level, conversation-level, and per-message-tag scopes are not specified; if needed later, additional tables can attach plugins at those scopes and the resolver merges them with profile-level (resolution order TBD when there's a real driver for needing it).

### Cache observability (no self-declaration)

Anthropic-style prompt caching matches byte-stable prefixes. Plugins that change a settled message's bytes between turns invalidate cache from that position onward — but "is this plugin cache-stable?" is a graded question, not a binary one, and asking plugin authors to self-declare leads to wrong answers (subtle position dependence is easy to miss). Reeve detects cache impact empirically.

**Mechanism:**

- At each `SendMessage`, after outbound plugins run, hash the rendered wire-prefix per-message and store the hashes alongside the `stream_run` (or on the conversation as "current prefix state").
- On the next `SendMessage` for the same conversation, recompute the hashes for the same per-message slice and compare to last turn's.
- The largest M such that hashes match for positions `0..M-1` is the **stable prefix length** — that's the cache hit zone. The gap between M and the previous turn count is the **trailing-edge depth** caused by the plugin pipeline.

**Reporting:**

- Fully stable plugin set: trailing depth = 1 (just the new turn's bytes are fresh). Same as no plugins.
- A `HistoryTransformer` with "keep last N": trailing depth = N+1 (the new turn plus N positions in flux as messages age out of the keep window).
- Truly non-stable plugin (timestamp injection, randomness, external lookups): trailing depth grows unboundedly — no stable zone forms. This is the case to flag.

The metric communicates the truth: "this plugin set keeps the trailing 2 turns out of cache" is honest and actionable. "This plugin isn't cache-safe" is binary nonsense for a transform that's perfectly cacheable in the long run, just shifted.

**Attribution:** the supervisor knows which plugin transformed which message position. When a hash diverges between turns, the diverging position's plugin pipeline is the suspect set. Single-plugin-per-position is unambiguous; multi-plugin can be localized by re-running each in isolation under a synthetic re-render.

**Surfacing:** server records cache health (stable prefix length, trailing depth, plugins implicated) per turn for diagnostics. UI surfacing (e.g., "your active plugins keep 2 turns out of cache; consider X if you want maximum cache hits") is a follow-up. The mechanism gives the data; how loud to be about it is a UX choice.

## Why these choices
John wants to mix cloud APIs with local agentic CLIs, reshape history before sending, branch exploration freely, and pick a model per-turn. Off-the-shelf chat UIs don't expose these knobs. Self-hosted personal-use means we optimize for operational simplicity (single Postgres, no Temporal) over runtime extensibility (compile-time provider types are fine — adding a driver = recompile).

## How to apply
- Backend integrations, chat plugins, and (eventually) other extension points are Go interfaces. Don't reach for subprocess/WASM plugin systems unless John asks — runtime-loadable plugins are not a stated requirement (the term "plugin" here means "compiled-in implementation of the Plugin interface set," not "loadable at runtime").
- Model the stateless/stateful provider split as a first-class type distinction in the schema and API, not an edge case bolted on.
- Treat ConnectRPC streaming as the default for any LLM-output-bearing endpoint.
- Conversation forking and per-turn model choice are core requirements for stateless-provider chats; design the message tree, history-builder, and transport with these in mind from the start.

## Library / SDK decisions (April 2026)
- **No multi-provider framework.** Evaluated LangChainGo, Eino (Cloudwego), Genkit-Go: all either flatten provider-specific features (Anthropic cache_control/thinking, OpenAI Responses API specifics) or impose a conversation-memory model that would fight Reeve's message tree. The "common interface over providers" is Reeve's own Go interface, not a framework's.
- **Per-provider official SDKs:**
  - Anthropic: `github.com/anthropics/anthropic-sdk-go` (exposes cache_control, extended thinking, batch).
  - OpenAI: `github.com/openai/openai-go` (Responses API first-class). Reuse the same SDK with a custom `BaseURL` for any OpenAI-compatible endpoint (Ollama, OpenRouter, Together, Groq, vLLM, llama.cpp, LM Studio).
  - Google Gemini: `github.com/googleapis/go-genai` (supersedes deprecated `generative-ai-go`).
  - Note: `sashabaranov/go-openai` is no longer the default — official `openai-go` is fresher and feature-complete.
- **OpenRouter is an *additional* provider instance, not a replacement for direct access.** OpenRouter has a cost markup, so configured direct providers (Anthropic, OpenAI, Google) should be preferred for any model available directly. OpenRouter's role is access to models John doesn't have direct keys for, and quick experimentation across many models. Configure via `openai-go` + custom base URL.
- **Subprocess providers (Claude Code, Codex):** no official Go SDK exists for either. Community references worth reading but not depending on at runtime: `severity1/claude-agent-sdk-go`, `hishamkaram/codex-agent-sdk-go`. Plan to vendor/fork or write ~300 lines of stdio-NDJSON / JSON-RPC ourselves; the CLI surface is unstable upstream.
- **Postgres access:** `pgx` directly, with `sqlc` for query codegen. No ORM.
- **Model catalog source:** [models.dev](https://models.dev) — community-maintained dataset of model metadata (context window, pricing, capabilities, modalities, knowledge cutoff). Fetched from `https://models.dev/api.json`, parsed, upserted into `catalog_*` tables. See `internal/modelmeta`.

## Authentication & users

Auth is built in from day one to leave room for multi-user later, even though John is the only user planned for the foreseeable future.

### Posture
- **Always require auth** — no single-user-bypass code path. Long-lived sessions (default 30 days, refreshed on use) make the friction negligible.
- **Bootstrap admin from env vars on first run.** If no users exist and `REEVE_BOOTSTRAP_ADMIN_USERNAME` + `REEVE_BOOTSTRAP_ADMIN_PASSWORD` are set, the server creates the admin user. If no users and no bootstrap env vars, the server refuses to start.
- **Per-user resource ownership.** `provider_instances`, `profiles`, `conversations` each belong to exactly one user. No sharing/visibility in v1 — every user procures their own provider credentials, etc. Sharing model is a deliberate future concern (see Open threads).

### Transport
- Clients carry credentials via `Authorization: Bearer <token>` HTTP header.
- A server-side Connect interceptor validates the token, resolves the user, and attaches `User` to the request `context.Context`.
- The interceptor maintains an unauth allowlist (just `AuthService.Login` for v1).
- **No `user_id` field appears in any RPC request message** — it's implicit in the auth context. Domain response messages carry `owner_user_id` for client clarity and forward compat.

### Tokens
- **Opaque session tokens, hashed in DB.** Simpler revocation than JWTs; per-request DB lookup is a non-issue at personal scale. Raw token returned exactly once at login; only `sha256(token)` is stored.
- **Long default TTL** (30 days), refreshed on use. Sessions carry `client_label` (e.g. "iOS app") so users can audit/revoke per-device.
- **API tokens** for programmatic access deferred — the same `sessions` mechanism could be reused with `expires_at = NULL` and a `kind` discriminator if needed.

### AuthService surface
`Login`, `Logout`, `WhoAmI`, `ChangePassword` for everyone. Admin-only (enforced server-side via `user.is_admin`): `CreateUser`, `ListUsers`, `GetUser`, `UpdateUser`, `DeleteUser`, `AdminResetPassword`. See [proto/reeve/v1/auth.proto](../proto/reeve/v1/auth.proto).

## Encryption

**Current posture: provider/plugin credentials encrypted at rest; message bodies still plaintext.** The "spendable secrets" subset of Tier A shipped under migration `00023_encrypted_secret_columns.sql` plus `internal/crypto`. Message content remains plaintext per the rationale in "Why true E2E is incompatible" below — encrypting it breaks the server-side intelligence (compression, history-builder, plugin pipelines) that's the whole point.

### What's encrypted today

| Column | Holds | Cipher |
|---|---|---|
| `user_model_providers.config_encrypted` | provider api_key + base_url + provider-specific config | AES-256-GCM |
| `user_plugin_settings.config_encrypted` | per-user plugin globals (e.g. `brave_search.api_key`) | AES-256-GCM |
| `profile_plugins.config_encrypted` | per-profile plugin overrides | AES-256-GCM |

Master key from env `REEVE_MASTER_KEY` (base64 32 bytes). `reeve genkey` mints one. Without it set the server boots with a loud warning and writes config blobs in plaintext via `crypto.Nop{}` — the dual-column rollover means existing rows keep working.

In-memory protection: `crypto.Secret` type wraps sensitive byte slices and redacts in every `fmt`/JSON path. Drivers receive plaintext config via `resolveProviderConfig` only at the moment they need to construct an SDK client; the official SDKs hold the key as a string regardless, so deeper in-memory sealing buys nothing.

### Still deferred

Host-level disk encryption (FileVault / dm-crypt / equivalent) still covers the broader-scope threat at self-hosted personal scale — the stolen-disk case. The remaining Tier A scope (encrypting `messages.content`, `messages.thinking`, `profiles.system_message`, etc.) is deferred until the threat model actually changes.

### Why true E2E is incompatible with the architecture
Reeve's value is server-side intelligence on plaintext: the stream supervisor assembling chunks while iOS is backgrounded, plugin pipelines running before/after the wire, compression invoking another LLM call, history-builder composing prefixes. All require plaintext at the server. Strict client-side E2E (server stores ciphertext only) breaks every one of those. If genuine "no provider sees this" privacy is needed, the answer is to run a local model via the `openai-compatible` driver — Reeve's processing then stays on the user's machine.

### Threat tiers and which we'd address

| Tier | Threat | What defends it | Status |
|---|---|---|---|
| T1 | Disk / DB backup leaks history | Host-level disk encryption | Covered by OS, no Reeve work |
| T1+ | Someone with logical DB access reads provider api_keys | AES-256-GCM on `*.config_encrypted` columns | **Shipped** (migration 00023, internal/crypto) |
| T1++ | Someone with logical DB access reads message bodies | Column-level encryption on messages.* | Deferred (per-tier sketch below) |
| T3 | Operator (Reeve admin) shouldn't read other users' data | Per-user keys derived from password (Tier B below) | Deferred until multi-user |
| T4 | Provider (Anthropic, OpenAI) shouldn't see content | Impossible — they process it | Out of scope; use local model |
| T5 | Server itself never has plaintext | True E2E | Architecturally incompatible; not pursued |

### Triggers to revisit

Revisit Tier A if any of:
- Reeve is exposed beyond `localhost` (reverse-proxy for travel access, deployed to VPS, etc.)
- Database hosted somewhere host-disk encryption can't be assumed
- Backups stored on devices without filesystem encryption

Revisit Tier B when:
- A second user is added (T3 becomes a real concern)
- Compliance / shared infrastructure requires the operator to be unable to read user data

### Tier A — Encryption at rest (sketch for when we build it)

- Master key from env var `REEVE_MASTER_KEY` (32 bytes, base64) or KMS reference.
- Sensitive columns become `BYTEA`, encrypted with AES-256-GCM (nonce prepended): `messages.content`, `messages.thinking`, `messages.raw_content`, `messages.thinking_rendered_text`, `profiles.system_message`, `profiles.default_user_message`, `profiles.compression_guide`, `user_model_providers.config` (especially — contains API keys), `harness_sessions.state`.
- New `internal/crypto` package: `Encrypt(plaintext []byte) ([]byte, error)`, `Decrypt(ciphertext []byte) ([]byte, error)` — driven by the master key.
- Store-layer wrappers around the affected sqlc methods, or convert at the service-layer boundary.
- One-shot migration: read all rows, encrypt in place, write back. Personal-use data volumes make this seconds.
- Estimated effort: ~3 days fresh; ~5 days plus migration if added later.

### Tier B — Per-user keys (sketch for when we build it)

- Each user gets a random 32-byte `data_encryption_key` (DEK) at creation.
- DEK is wrapped (envelope-encrypted) by a `key_encryption_key` (KEK) derived from the user's password via Argon2id. Stored as `users.encrypted_dek BYTEA`, `users.kek_salt BYTEA`.
- `Login` derives KEK, unwraps DEK, caches it in server memory keyed by session token.
- Auth interceptor pulls DEK from session cache and attaches to request `context.Context`.
- Service/store layers use the per-request DEK for encrypt/decrypt.
- `ChangePassword` re-derives KEK with new salt, re-wraps the DEK — no data re-encryption needed.
- Operator can't read user data without the user's password (T3 ✓), modulo memory-dump while user is logged in.
- **Background work decision** is the real fork:
  - **Defer** background work (compression, etc.) to "while user is online" — preserves T3 strictly.
  - **Server-held DEK escrow** (operator can decrypt) — enables background work, weakens T3. For single-user / household, this is fine.
- Multi-device per user: standard envelope — wrap DEK with each device's public key, store one wrapped copy per device, pairing flow approves new devices. Skip until needed.
- Migration when adding to existing data: per-user-mediated. On user's next login, server has KEK and migrates that user's rows from server-master-key encryption to per-user DEK.
- Estimated effort: ~7 days fresh; ~10 days plus migration if added later.

### Provider credentials (always more sensitive)

`user_model_providers.config` carries API keys — these are spendable. Even at Tier A, this column should get extra ceremony: separate column-level key, or KMS reference if the deployment has KMS available. Worth nodding to in any encryption work.

## Schema sketch (SQL)

Directional, not final. UUIDs (likely v7 for sortability) for all IDs. `TEXT + CHECK` over Postgres `ENUM` to keep schema-evolution painless.

**Schema is in [`db/migrations/00001_initial.sql`](../db/migrations/00001_initial.sql)** — sketch below shows the shape, see the migration file for exact column definitions and constraints.

```sql
-- Users & sessions
users (id, username, display_name, password_hash, is_admin, created_at, updated_at)
sessions (token_hash PK, user_id FK→users, client_label, created_at, last_used_at, expires_at)

-- Model catalog (refreshed from models.dev)
catalog_model_providers (id PK, name, api_base, env_key, doc_url, npm, raw, fetched_at)
catalog_models (provider_id FK→catalog_model_providers, model_id, display_name,
                context_window, max_output_tokens, input/output/cache pricing,
                knowledge_cutoff, modalities text[], capabilities jsonb, raw, fetched_at;
                PK (provider_id, model_id))

-- User-configured providers
user_model_providers (id PK, user_id FK→users, type, label, config, created_at, updated_at;
                      UNIQUE (user_id, type, label))

-- User-enabled models — snapshot owned by the user, NOT FK'd to catalog
user_models (user_model_provider_id FK→user_model_providers, model_id,
             display_name, context_window, max_output_tokens, pricing fields,
             knowledge_cutoff, modalities, capabilities, default_settings,
             metadata_source CHECK IN ('catalog','driver','manual'),
             metadata_snapshot_at, enabled_at;
             PK (user_model_provider_id, model_id))

-- Profiles ----------------------------------------------------------------

CREATE TABLE profiles (
    id                       UUID PRIMARY KEY,
    user_id                  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    parent_profile_id        UUID REFERENCES profiles(id),
    name                     TEXT NOT NULL,
    system_message           TEXT,
    default_user_message     TEXT,
    compression_guide        TEXT,
    compression_mode         TEXT CHECK (compression_mode IN ('REPLACE', 'APPEND')),
    compression_provider_id  UUID REFERENCES user_model_providers(id),
    compression_model_id     TEXT,
    default_settings         JSONB,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX profiles_user ON profiles (user_id);

-- Conversations / Contexts / Messages -------------------------------------

CREATE TABLE conversations (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    profile_id  UUID NOT NULL REFERENCES profiles(id),
    title       TEXT,
    settings    JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX conversations_user ON conversations (user_id);

CREATE TABLE contexts (
    id                       UUID PRIMARY KEY,
    conversation_id          UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    parent_context_id        UUID REFERENCES contexts(id),  -- null for first context; otherwise the context this was compressed from
    context_activation_time  TIMESTAMPTZ NOT NULL,           -- newest wins for "active context"
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX contexts_active ON contexts (conversation_id, context_activation_time DESC);

CREATE TABLE messages (
    id                      UUID PRIMARY KEY,
    context_id              UUID NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
    parent_id               UUID REFERENCES messages(id),    -- message tree
    role                    TEXT NOT NULL CHECK (role IN ('system','context','user','assistant')),
    content                 TEXT NOT NULL,                    -- post-plugin (= raw when no chunk/outgoing-user transform applied)
    raw_content             TEXT,                             -- non-null only when a plugin chunk transform changed assistant content (or an outgoing-user transform changed user content)
    thinking                JSONB,                            -- raw provider-shape (signed Anthropic blocks, OpenAI reasoning items)
    thinking_provider_type  TEXT,                             -- which provider type produced the thinking
    thinking_rendered_text  TEXT,                             -- deterministic plain-text rendering for cross-provider injection
    provider_instance_id    UUID REFERENCES provider_instances(id),  -- assistant turns only
    model_id                TEXT,                             -- assistant turns only
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX messages_context_parent ON messages (context_id, parent_id);

-- Streaming ---------------------------------------------------------------

CREATE TABLE stream_runs (
    id                    UUID PRIMARY KEY,
    conversation_id       UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    context_id            UUID NOT NULL REFERENCES contexts(id),
    parent_message_id     UUID REFERENCES messages(id),
    provider_instance_id  UUID NOT NULL REFERENCES provider_instances(id),
    model_id              TEXT NOT NULL,
    status                TEXT NOT NULL CHECK (status IN ('running','completed','errored','cancelled','interrupted')),
    started_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at              TIMESTAMPTZ,
    error_payload         JSONB,
    result_message_id     UUID REFERENCES messages(id)
);

CREATE INDEX stream_runs_active ON stream_runs (status) WHERE status = 'running';

CREATE TABLE stream_chunks (
    stream_run_id  UUID NOT NULL REFERENCES stream_runs(id) ON DELETE CASCADE,
    sequence       BIGINT NOT NULL,
    chunk_type     TEXT NOT NULL,
    payload        JSONB NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (stream_run_id, sequence)
);

-- Harness sessions (stateful providers) -----------------------------------

CREATE TABLE harness_sessions (
    id                    UUID PRIMARY KEY,
    conversation_id       UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    provider_instance_id  UUID NOT NULL REFERENCES provider_instances(id),
    external_session_id   TEXT NOT NULL,    -- the harness's own session id
    state                 JSONB,            -- harness-specific (working dir, etc.)
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at          TIMESTAMPTZ
);
```

**Notes:**
- Model metadata (context window, capabilities, default settings) lives in driver code, not in a DB table — each driver's `Models()` method returns its catalog. Provider instances may filter via `config`.
- Plugin pipelines attach at profile scope via `profile_plugins (profile_id, ordinal, plugin_name, config)` — see "Chat plugins → Configuration and scope." Other scopes (provider, conversation, per-message-tag) are not yet specified; deferred until something needs them.
- `raw_thinking` intentionally absent from `messages`: per the rule that plugin chunk transformers cannot mutate thinking, `thinking` is always identical to what the provider produced.

## Go interfaces (sketch)

The driver-side abstraction. Each provider type lives in its own package and registers itself in `init()`.

```go
package providers

import (
    "context"
    "encoding/json"
)

// Provider is the registered driver for a backend kind.
type Provider interface {
    Type() string                                      // e.g., "anthropic"
    Stateful() bool                                    // true for harness providers
    // DiscoverModels returns the catalog of models the provider currently
    // offers, enriched with metadata via deps.Catalog. May be a static list
    // (Anthropic — but the Anthropic Models API is also live) or a live API
    // call (openai-compatible /v1/models).
    DiscoverModels(ctx context.Context) ([]Model, error)
    RenderThinkingToText(thinking json.RawMessage) string
}

// StatelessProvider — full prefix every turn. Server owns history.
type StatelessProvider interface {
    Provider
    Send(ctx context.Context, req SendRequest) (<-chan Chunk, error)
}

// StatefulProvider — long-lived session, latest message only. Harness owns history.
type StatefulProvider interface {
    Provider
    StartSession(ctx context.Context, modelID string, settings CallSettings) (sessionID string, err error)
    SendInSession(ctx context.Context, sessionID string, msg WireMessage, settings CallSettings) (<-chan Chunk, error)
    TerminateSession(ctx context.Context, sessionID string) error
}

// TokenCounter — exposed by drivers that can report token counts.
// Used by the UI to inform compression decisions.
type TokenCounter interface {
    CountTokens(ctx context.Context, modelID string, messages []WireMessage) (int, error)
}

// SendRequest — input to a stateless turn. Messages are already wire-shaped:
// role rewriting (context→user) and cross-provider thinking injection have happened upstream.
type SendRequest struct {
    ModelID  string
    Messages []WireMessage
    Settings CallSettings
}

// WireMessage — the shape providers actually see, post history-builder.
type WireMessage struct {
    Role     string           // "system" | "user" | "assistant" (no "context" — already rewritten)
    Content  string
    Thinking json.RawMessage  // native shape; non-nil only on same-provider sends with thinking enabled
}

type CallSettings struct {
    Temperature          *float64
    MaxOutputTokens      *int
    ThinkingEnabled      *bool
    ThinkingBudgetTokens *int
    Extras               json.RawMessage  // provider-specific knobs not in the common set
}

// Chunk — normalized streaming output. Drivers translate provider-native events into this vocabulary.
type Chunk struct {
    Type    ChunkType
    Payload json.RawMessage  // type-specific
}

type ChunkType string

const (
    ChunkText         ChunkType = "text_delta"
    ChunkThinking     ChunkType = "thinking_delta"
    ChunkToolUseStart ChunkType = "tool_use_start"
    ChunkToolUseDelta ChunkType = "tool_use_delta"
    ChunkToolUseEnd   ChunkType = "tool_use_end"
    ChunkError        ChunkType = "error"
    ChunkDone         ChunkType = "done"
)

type Model struct {
    ID              string  // canonical, e.g., "claude-opus-4-7"
    DisplayName     string
    ContextWindow   int
    Capabilities    ModelCapabilities
    DefaultSettings CallSettings
}

type ModelCapabilities struct {
    Streaming     bool
    Thinking      bool
    ToolUse       bool
    Vision        bool
    PromptCaching bool
}

// Deps are injected at instance build time. New deps can be added without
// breaking existing driver constructors — they read fields they need.
type Deps struct {
    Catalog modelmeta.Catalog
    Logger  *slog.Logger
}

// Compile-time provider-type registration.
type Constructor func(deps Deps, config json.RawMessage) (Provider, error)

var registry = map[string]Constructor{}

func Register(typeName string, c Constructor) { registry[typeName] = c }

func Build(typeName string, config json.RawMessage) (Provider, error) {
    c, ok := registry[typeName]
    if !ok {
        return nil, fmt.Errorf("unknown provider type: %s", typeName)
    }
    return c(config)
}
```

**Notes:**
- The interface omits chat plugins entirely — they're a layer above the provider, applied by the history-builder (`SystemPrompter`, `OutgoingUserTransformer`, `HistoryTransformer`), the stream supervisor (`ChunkTransformer`, `ToolProvider`), and the message-fetch path (`DisplayTransformer`) before/after calling the provider.
- `Stateful() bool` is on the base interface so callers can dispatch without type-asserting. Implementations still must satisfy the corresponding `StatelessProvider` or `StatefulProvider` sub-interface.
- `WireMessage` deliberately excludes a `Tool*` block for now — placeholder for when tool use lands.
- Each provider package looks like:
  ```go
  package anthropic
  func init() { providers.Register("anthropic", New) }
  func New(config json.RawMessage) (providers.Provider, error) { /* … */ }
  ```

## Open threads
- Tool use end-to-end execution (and its structural coupling with thinking on Anthropic). The `ToolProvider` plugin interface is settled; the deferred work is the outbound wire translation of stored `tool_use` + `tool_result` blocks back into provider-native shape on follow-up turns, and the storage shape for `tool_result` rows in `messages`.
- Vision / file attachments in `WireMessage`.
- Plugin scopes beyond profile (provider, conversation, per-message-tag). Add when there's a real driver for needing them; the `profile_plugins` table is the v1 cut.
- **Resource sharing model.** v1 is per-user-only — no shared `provider_instances`, profiles, or conversations. The natural multi-user use case (a household sharing the admin's API keys) will want a `visibility = {private, shared}` enum on `provider_instances` plus a sharing/ACL story for profiles. Add when a second user actually exists.
- **Encryption.** Tier A (column-level at rest) and Tier B (per-user keys) sketched in their own section above. Deferred until threat model shifts (network exposure, multi-user, hosted infra).
