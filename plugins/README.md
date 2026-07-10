# `plugins/` — Psmith's chat-plugin system

Compiled-in extension points for Psmith's conversation pipeline. Plugins observe and shape the lifecycle of a turn — system prompts, outgoing user content, history rewrites, inbound chunks, persisted assistant text, displayed text, tool calls, and post-write events.

This README is the orientation guide. The canonical design lives in `docs/design/plugins.md`; deferred ideas in `docs/todo.md` ("Plugin hook ideas").

---

## Core idea

A plugin is a Go type implementing the small required `Plugin` interface plus zero or more **opt-in capability interfaces**. The runtime detects each capability via type assertion at the call sites that care; you implement only what you need.

Four concrete plugins live alongside this README:

| Plugin | What it does | Capabilities used |
|---|---|---|
| `lettered_choices` | Asks the model to wrap interactive choices in delimiters; strips them from older history; renders them clean for display | `Configurable`, `SystemPrompter`, `HistoryTransformer`, `DisplayTransformer` |
| `brave_search` | Exposes `web_search` as a model-callable tool backed by the Brave API | `Configurable`, `ToolProvider` |
| `basic_grounding` | Adds a grounding-facts header (current time, locale, platform, location) beside outgoing user messages | `Configurable`, `MessageEnvelope`, `DisplayTransformer` (legacy-row strip) |
| `mcp` | Bridges any [Model Context Protocol](https://modelcontextprotocol.io/) server's tools into Psmith. Two transports: **stdio** (spawn a local subprocess and exchange JSON-RPC over stdin/stdout) and **http** (POST JSON-RPC to a remote URL — Streamable HTTP transport, both `application/json` and `text/event-stream` responses; honours `Mcp-Session-Id`). Pool keeps connections alive across sends; idle entries reaped after 5 min. One plugin instance per server | `Configurable`, `ToolProvider` |

Read those for working examples before / while building a new one.

---

## The required interface

```go
type Plugin interface {
    Name() string         // stable machine identifier (e.g. "brave_search")
    DisplayName() string  // human-friendly label (e.g. "Brave Search")
    Description() string  // one-paragraph blurb shown in the UI
}
```

`Name` is the primary key in `profile_plugins.plugin_name` and `user_plugin_settings.plugin_name`. **Don't change it between releases** — existing rows would orphan. `DisplayName` and `Description` are free to evolve.

---

## Capability interfaces

Each capability is detected by type assertion. A plugin implements as many as it needs; runtime cost of an unused capability is one assertion per pipeline iteration (cheap).

### `Configurable`
```go
type Configurable interface {
    ConfigFields() []ConfigField
}
```
Declares the per-instance config shape. The framework's UI walks `ConfigFields()` and renders a form (text / number / textarea / boolean / select). `ConfigField` carries:

- `Name`, `Display`, `Description`, `Type`, `Default` (any), `Options []ConfigOption` (for `ConfigFieldSelect`)
- `Required bool` — UI hint that disables Save and shows inline validation when empty. Plugin's `Constructor` remains the authoritative validator.
- `Global bool` — the field lives at **user scope** rather than profile scope. Use for credentials and other shared values the user only wants to enter once. The framework merges the user's stored global blob into the per-profile config blob before calling the constructor; profile-level wins per-key.

The constructor signature is:
```go
type Constructor func(configBytes json.RawMessage) (Plugin, error)
```
`configBytes` may be `nil` — the constructor MUST accept that and return a usable instance with default values populated. `Describe` relies on this so management RPCs can introspect a plugin's config shape without a hand-crafted sample.

### `SystemPrompter`
```go
type SystemPrompter interface {
    PrependSystemMessage() string
    AppendSystemMessage() string
}
```
Contributes to the system slot at prefix-build time. Empty string = no contribution. Multiple plugins compose; framework joins with blank-line separators.

### `MessageEnvelope`
```go
type MessageEnvelope interface {
    OutgoingMessageEnvelope(facts map[string]string) (header, trailer string)
}
```
Contributes header/trailer blocks for the outgoing user message, rendered **at SEND time** and persisted in the dedicated `messages.message_headers` / `message_trailers` columns — `content` stays exactly what the user typed. The history builder composes headers + content + trailers into the wire text; edit, display, TTS, and embeddings all read bare `content`. Prefix-cache stable: the envelope is frozen at write time (never re-rendered), and edits to content leave it untouched. Use for grounding facts or any "freeze it on write" contribution.

### `HistoryTransformer`
```go
type HistoryPos struct {
    FromHead         int  // 0 = head, 1 = parent, ...
    FromHeadSameRole int  // 0 = most-recent same-role, ...
}
type HistoryTransformer interface {
    TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage
}
```
Mutates messages **at prefix-build time**, on every history fetch. NOT persisted. Use for "keep only last N assistant choice blocks" / "strip diffs after K turns" / "trim verbose markers from older turns" patterns. Position info lets policies be role-aware and fork-stable.

### `ChunkTransformer` / `InboundProcessor`
```go
type ChunkTransformer interface {
    NewInboundProcessor() InboundProcessor
}
type InboundProcessor interface {
    Process(providers.Chunk) []providers.Chunk
    Close() []providers.Chunk
}
```
Stream-level processor running inside the supervisor. `NewInboundProcessor` returns a fresh per-stream instance so internal state (buffering, sliding windows) is per-run. `Process` may emit zero or more output chunks per input. `Close` flushes any residue at stream end. No concrete plugin uses this yet — reserved for things like "rewrite tool-call payloads inflight" or "buffer until a closing marker arrives."

### `DisplayTransformer`
```go
type DisplayTransformer interface {
    TransformForDisplay(content string) string
}
```
Rewrites stored content for display **at fetch time**. NOT persisted. Position-independent: same input always yields the same output for a given config. Pairs naturally with `OutgoingUserTransformer` (one writes the framing, the other strips it for the UI).

### `ToolProvider`
```go
type ToolProvider interface {
    Tools() []ToolDef
    ExecuteTool(ctx context.Context, name string, input json.RawMessage) (json.RawMessage, error)
}
type ToolDef struct {
    Name        string
    Description string
    InputSchema json.RawMessage // raw JSON Schema
}
```
Declares callable tools. The runtime gathers `Tools()` from every active plugin and ships them on each request; when the model emits a `tool_use`, the conversations-side tool loop dispatches `ExecuteTool` on the owning plugin. Returns the JSON-encoded result the model sees on the next round. Errors surface as `tool_result.error` to the model.

### `AssistantContentTransformer`
```go
type AssistantContentTransformer interface {
    TransformAssistantContent(content string) string
}
```
Mirrors `OutgoingUserTransformer` for the assistant side. Rewrites the just-finalised assistant text **before the row is inserted**. Persisted output is what every future history build sees. Use for stripping ANSI / control chars from coding-tool output, watermarking turns with model metadata, or sanitizing tool-call cruft. NOT for rewrites that need to evolve over time — those go on `DisplayTransformer`.

### `MessageLifecycleHook`
```go
type MessageLifecycleHook interface {
    OnMessagePersisted(ctx context.Context, m PersistedMessage)
}
type PersistedMessage struct {
    ID, ContextID, Role, Content, ProviderID, ModelID string
}
```
Fires after a message row is persisted, in a **detached goroutine**. The supervisor / SendMessage handler does not await completion or observe errors — a slow or panicking hook can't stall a user-facing operation. Panics are recovered + logged; one bad plugin can't take down its siblings.

Fires on:
- user-message inserts (in `SendMessage` after the TX commits)
- assistant materialization (in `materializeAssistant`)
- compression summaries (in `materializeCompression`)

Skipped on errored runs (the row exists for UI surfacing, but downstream processing — embedding, auto-tag — would be working with garbage). Edits and deletes are deliberately NOT fired in v1 — those events warrant their own hook shape if a use case needs them.

Use for: embedding generation, webhook notifications, auto-tagging via a small classifier, external audit logs.

`PersistedMessage` is intentionally minimal — hooks needing more (usage, thinking, tool calls) fetch the full row by ID. Keeps the contract stable as the messages schema evolves.

---

## Configuration mechanics

### Field scope — profile vs global

Every `ConfigField` has a `Global bool` flag:

- `Global: false` (default) → the field's value lives in `profile_plugins.config` JSONB, scoped per (profile, plugin). Each profile can hold a different value.
- `Global: true` → the field's value lives in `user_plugin_settings.config` JSONB, scoped per (user, plugin). One value across every profile that attaches the plugin.

At pipeline-build time the framework reads both and **shallow-merges**: keys from the global blob are overlaid with keys from the profile blob (profile wins per-key). The merged result is what the constructor receives.

Why split: things like API keys are intrinsically per-user (you don't want to re-enter them per profile), while things like `default_count` or `system_instruction_override` are intrinsically per-profile. The split lets the UI render each in the right place without the user thinking about scope.

### Required fields

`Required: true` makes the framework's UI block Save and surface inline validation when the field is empty. The plugin's `Constructor` remains the authoritative validator at runtime — `Required` is purely a UX signal.

### Defaults

`ConfigField.Default any` is JSON-marshaled when shipped over the wire. Empty / nil means "no default." Defaults are populated into the form when a plugin is freshly attached, so users see sensible starting values rather than blank fields.

---

## Registration

Plugins self-register via `init()`:

```go
const MyPluginName = "my_plugin"

func init() {
    Register(MyPluginName, newMyPlugin)
}

func newMyPlugin(configBytes json.RawMessage) (Plugin, error) {
    cfg := myConfig{ /* defaults */ }
    if len(configBytes) > 0 {
        if err := json.Unmarshal(configBytes, &cfg); err != nil {
            return nil, fmt.Errorf("my_plugin: parse config: %w", err)
        }
    }
    return &myPlugin{cfg: cfg}, nil
}
```

`Register` panics on duplicate names, empty names, or nil constructors — surfacing programmer errors at boot rather than at first call.

To make the plugin discoverable by the registry, ensure `plugins` is imported transitively from `cmd/psmithd`. New files in `plugins/` are picked up automatically by the package init.

---

## The Pipeline

A `Pipeline` is the ordered list of plugin instances resolved for a given turn. Resolution is per-conversation: the framework walks the profile inheritance chain, finds the nearest profile with non-empty `profile_plugins` rows, and uses **that profile's pipeline entirely** (all-or-nothing inheritance — a child overrides its parent's pipeline as a whole, not per-plugin).

Pipeline methods (one per capability surface):
```go
func (p Pipeline) SystemPrompts() (prepend, appendStr string)
func (p Pipeline) TransformOutgoingUser(content string) string
func (p Pipeline) TransformHistoryMessage(msg providers.WireMessage, pos HistoryPos) providers.WireMessage
func (p Pipeline) TransformForDisplay(content string) string
func (p Pipeline) TransformAssistantContent(content string) string
func (p Pipeline) FireMessagePersisted(ctx context.Context, m PersistedMessage, logger *slog.Logger)
```
Each iterates the pipeline once, applying the relevant capability and skipping plugins that don't implement it. Composition order matches pipeline order; plugin authors can rely on it.

Tool-related composition (gathering tools, dispatching `tool_use` to the owning plugin) lives in `internal/conversations/tool_loop.go` rather than as Pipeline methods — the dispatch is keyed on tool name across plugins.

---

## Lifecycle / when each hook fires

For one turn of `SendMessage`:

1. **Pre-send** (in `internal/conversations/service.go::SendMessage`):
   - User message TX commits with raw content
   - `Pipeline.TransformOutgoingUser` rewrites the persisted content (yes, the post-transform value lands on `messages.content` — the order is: TX commits row, then the OutgoingUserTransformer wouldn't re-transform; the transform is applied IN the TX before the insert. See the actual code path in service.go for the precise ordering.)
   - `Pipeline.FireMessagePersisted` fires for the user row (detached goroutines)
2. **Build wire prefix** (in `internal/history/history.go::Build`):
   - `Pipeline.SystemPrompts` contributes prepend/append to the system slot
   - `Pipeline.TransformHistoryMessage` mutates each historical message
3. **In-stream** (in the supervisor, `internal/stream/consume.go`):
   - Driver streams chunks
   - `ChunkTransformer.Process` mutates each (when the supervisor wires this — currently scaffolded but not on the stream path)
   - Tool calls are dispatched via `internal/conversations/tool_loop.go`
4. **Post-stream materialization** (in `materializeAssistant`):
   - `Pipeline.TransformAssistantContent` rewrites the assistant text
   - Row inserted with the post-transform content
   - `Pipeline.FireMessagePersisted` fires for the assistant row (detached)
   - Auto-titler hook fires (separate path, internal to the supervisor)
5. **Display** (in `internal/conversations/convert.go::applyDisplay`, called from every message-fetching RPC):
   - `Pipeline.TransformForDisplay` populates `Message.display_content` for the UI

For compression turns the path is similar: `materializeCompression` writes the `compression_summary` row, then fires `FireMessagePersisted`. The compression prompt itself does NOT run plugin transforms (by design — it's a meta-conversation about the actual conversation).

---

## Testing tips

- **Pure-unit tests** are easy: construct the plugin directly, call the methods, assert output. See `basic_grounding_test.go` for the pattern (including a `now func() time.Time` seam for clock-dependent plugins).
- **Pipeline composition tests** live in `plugins/plugins_test.go` and `plugins/hooks_test.go`. Use the embedded `dummyPlugin` to build minimal stubs implementing just the interfaces you want.
- **End-to-end against a real DB** belongs in `internal/profiles/service_plugins_test.go` (registration / CRUD) or `internal/conversations/service_plugins_e2e_test.go` (full send flow with the plugin attached). Both use `pgtestdb` for fresh per-test databases.
- **Side-effecting hooks** (Tool, MessageLifecycleHook): always design with deterministic fakes — never let tests hit external services. brave_search's tests use a stub HTTP server inline.

---

## Adding a new capability interface

When the existing surface doesn't fit a use case (and the use case is real, not speculative — see `docs/todo.md` for the bar):

1. Define the interface in `plugins.go` with thorough doc comments, including:
   - When it fires (lifecycle position)
   - Whether the output is persisted, transient, or fire-and-forget
   - What ordering / composition guarantee the framework provides
   - Why this isn't subsumed by an existing interface
2. Add a `Pipeline.<Method>` that iterates and fans out.
3. Add a `Capabilities.<NewCapability> bool` and detect it in `Describe`.
4. Wire the call site (search the codebase for existing `Pipeline.Transform...` calls; the new one slots in nearby).
5. Ship a proto field on `PluginCapabilities` and bridge to Swift's `PsmithPluginCapabilities`.
6. Render a new mini-chip in the profile-form plugin card (`ProfilesView.swift::capabilityChips`).
7. Tests: pipeline composition (in `plugins/`), end-to-end wiring (in the relevant `internal/` package).

The same procedure applies in reverse for deprecating one — but consider whether plugins built against it would still work via a dummy implementation before removing.

---

## Architecture references

- `docs/design/plugins.md` — the design rationale for capability-interface composition, all-or-nothing inheritance, parent-chain resolution.
- `docs/todo.md` — "Plugin hook ideas" section: hooks designed but not yet shipped (`PreSendContextInjector`, `ContentRenderer`, etc.) plus deferred ones with rationale.
- `internal/conversations/service.go` — pipeline resolution + invocation in the SendMessage path.
- `internal/stream/consume.go` — supervisor-side invocation (AssistantContentTransformer, FireMessagePersisted).
- `internal/history/history.go` — history-build invocation (SystemPrompter, HistoryTransformer).
- `internal/conversations/tool_loop.go` — tool dispatch loop.
