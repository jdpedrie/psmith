# Reeve — agentic harness plan

Design plan for plugging local agentic CLIs (Claude Code, Codex, pi.dev, …) into Reeve as first-class providers, alongside the existing stateless API drivers (Anthropic / Google / OpenAI).

Reads as a sibling to `architecture.md`, `multimodal-plan.md`, and `todo.md`. The "Stateful harness drivers" entry in todo.md gets retired into this doc as it lands.

---

## Goals

- A user can attach Claude Code (or Codex, or pi.dev) the same way they attach a cloud provider, pick it as a model in the conversation composer, and chat against it.
- Conversations against a harness behave like normal Reeve conversations: streaming text, branching (where the harness allows), per-message cost, history rendered the same way, all UI affordances we already ship.
- Harness session continuity survives: closing and reopening a conversation hours later resumes the same harness session with intact tool history.
- Adding a new harness is **one new package** in `internal/harnesses/<name>/` plus one provider type registration. The supervisor and conversations layer don't need to know which harness is on the other end.

## Non-goals (v1)

- **Persistent harness daemons.** v1 spawns one subprocess per turn (`-p` mode). Persistent sockets / RPC daemons can come later if turn-startup latency becomes a real problem; for now the simplicity wins.
- **Cross-harness session migration.** Resuming a Claude Code session inside Codex isn't a thing the underlying tools support.
- **Multi-modal attachments through the harness layer.** Lands when `multimodal-plan.md` Phase 1 lands; the harness layer's wire shape will get attachments at the same time.
- **Reeve-side features that depend on owning the conversation transcript** — see "Features unavailable inside a harness conversation" below for the full list. Each is hidden / disabled in the UI rather than presented and silently broken.

---

## Architectural overview

Two layers, in this order on the way to the wire:

```
                 ┌────────────────────────────────────┐
                 │  conversations.Service.SendMessage │
                 └────────────────────────────────────┘
                                │
                                ▼ build StatefulSendRequest
                                  (session id from DB; latest user prompt only)
                                │
                 ┌──────────────────────────┐
                 │   Layer 2 — harness      │
                 │   abstraction (provider) │   ← implements providers.StatefulProvider
                 └──────────────────────────┘
                                │
                                ▼  delegate to active impl
                                │
   ┌──────────────────┬──────────────────┬──────────────────┐
   │ claude (Layer 1) │ codex  (Layer 1) │ pi.dev (Layer 1) │
   └──────────────────┴──────────────────┴──────────────────┘
                                │
                                ▼  spawn subprocess in -p mode with --resume
                                │
                       ┌────────────────────┐
                       │  external CLI tool │
                       └────────────────────┘
```

**Layer 1 — harness-specific** (`internal/harnesses/<name>/`):
- Knows ONE harness's CLI flags, stdout event format, and session-id surfacing rules.
- Translates the native event stream into the normalised `providers.Chunk` vocabulary.
- Doesn't know about `providers.Provider`, the supervisor, or the DB.

**Layer 2 — abstraction** (`internal/providers/harness/`):
- Implements the existing `providers.Provider` interface plus a new `providers.StatefulProvider` interface.
- Wraps a Layer-1 `Harness` and exposes the same send-shape every other Reeve driver does.
- Owns session-id round-tripping with the conversations layer.

The supervisor doesn't change. SendFunc closures already let the conversations layer assemble per-turn behaviour without supervisor surgery.

---

## Layer 1 — the `Harness` interface

```go
// internal/harnesses/harness.go
package harnesses

import (
    "context"

    "github.com/jdpedrie/reeve/internal/providers"
)

// Harness is one external agentic CLI's adapter. Each implementation
// (claude, codex, pi) lives in its own package and registers itself
// at init().
type Harness interface {
    // Name is the stable machine identifier (e.g. "claude", "codex",
    // "pi"). Used as the harness's part of the user_model_providers
    // type name (e.g. "harness-claude").
    Name() string

    // DefaultBinary is the CLI executable the user gets pre-filled in
    // the provider config form (e.g. "claude", "codex"). User can
    // override per-instance.
    DefaultBinary() string

    // Models returns the list of models this harness supports
    // delegating to. Used to populate the conversation model picker.
    // Static for v1 (each Layer-1 impl knows its harness's catalog);
    // dynamic discovery via the harness's own --list-models is a
    // future enhancement.
    Models() []HarnessModel

    // Spawn launches the subprocess for ONE turn. Caller drains
    // run.Chunks; once it closes, run.Result() blocks for the final
    // session id + usage + exit error.
    Spawn(ctx context.Context, opts SpawnOpts) (*Run, error)
}

type HarnessModel struct {
    ID          string  // e.g. "claude-sonnet-4-6"
    DisplayName string
    // Whether this model supports the harness's "thinking" mode (each
    // harness exposes thinking somewhat differently).
    Thinking bool
}

type SpawnOpts struct {
    Binary     string  // resolved executable; empty = DefaultBinary()
    SessionID  string  // empty = new session
    Prompt     string  // the latest user message
    WorkingDir string  // required — harness's cwd for this turn
    Model      string  // optional — passed to the harness's --model flag
    Env        []string // KEY=VALUE; subprocess inherits NOTHING from reeved beyond what's listed
}

type Run struct {
    Chunks <-chan providers.Chunk
    // Result blocks until the subprocess has fully exited. Caller
    // invokes it AFTER Chunks has closed.
    Result func() RunResult
}

type RunResult struct {
    // SessionID is what subsequent turns should pass back as
    // SpawnOpts.SessionID. Always populated on a successful run —
    // for a brand-new session, this is the harness's freshly-minted id.
    SessionID string
    Usage     *providers.Usage
    // Cost reported by the harness (if it surfaces one). Most
    // agentic CLIs do because they integrate with provider billing.
    TotalCostUSD *float64
    // Exit error from the subprocess. nil on clean exit.
    ExitErr error
}
```

Key properties:

- **Layer 1 owns subprocess lifecycle.** `Spawn` returns when the subprocess has been started and stdout is being read; the read goroutine pumps `Chunks` until the harness's terminal event arrives, then closes. `Result()` blocks on the subprocess's `Wait()`.
- **Layer 1 emits normalised chunks.** Every harness's native event format gets translated into Reeve's existing chunk vocabulary (`text_delta`, `thinking_delta`, `tool_use_*`, `tool_result`, `usage`, `done`, `error`). The supervisor and UI don't need a per-harness branch.
- **`Result()` is a func, not a channel.** Blocking call; lets the caller decide when to wait. Returning a struct over a channel makes it awkward to compose with the chunks channel's lifetime.
- **Cancellation = context cancel.** The Layer-1 impl wires `ctx.Done()` to subprocess kill + drain. After cancel, `Chunks` closes promptly and `Result()` returns the partial state (no SessionID if the subprocess died before initialise).

---

## Layer 1 — per-harness implementations

Each harness gets its own package. Below is what's known about each today; details may shift once we read each tool's actual stdout format closely.

### `internal/harnesses/claude/` — Claude Code

- **Invocation:** `claude -p --output-format stream-json --resume <session_id> --model <model> --cwd <dir>`. Without `--resume`, starts a new session.
- **Stdin:** the prompt, then EOF.
- **Stdout:** newline-delimited JSON events. Schema (rough):
  ```json
  {"type": "system", "subtype": "init", "session_id": "abc", "model": "claude-sonnet-4-6", ...}
  {"type": "assistant", "message": {"content": [{"type": "text", "text": "..."}, {"type": "tool_use", "id": "...", "name": "Read", "input": {...}}]}}
  {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "...", "content": "..."}]}}
  {"type": "result", "subtype": "success", "session_id": "abc", "total_cost_usd": 0.42, "usage": {...}, "duration_ms": 12345}
  ```
- **Translation:**
  - `system.init` → capture session_id (final value also in `result`).
  - `assistant.message.content[].text` → emit ChunkText deltas.
  - `assistant.message.content[].tool_use` → emit ChunkToolUseStart/Delta/End (informational — Reeve doesn't dispatch).
  - `user.message.content[].tool_result` → emit ChunkToolResult (informational).
  - `result` → ChunkUsage + close.
- **Models:** Claude's catalogued model IDs the user has authenticated for via `claude /login`.

### `internal/harnesses/codex/` — Codex CLI

- **Invocation:** `codex exec --json --session <session_id> "<prompt>"`. New session if `--session` omitted; Codex prints the assigned id in the first event.
- **Output:** newline-delimited JSON. Different schema than Claude — `thread.started`, `turn.started`, `item.completed` (with item types `agent_message`, `command_execution`, `read_file`, etc.). `turn.completed` marks end of turn with usage + cost.
- **Translation:** same target chunk vocabulary, different per-event mapping. Tool calls in Codex come through as `command_execution` / `read_file` / `apply_patch` items — emit ChunkToolUse{Start,End} + ChunkToolResult informationally.

### `internal/harnesses/pi/` — pi.dev

- **Invocation:** TBD; whatever the pi.dev CLI's print-mode + resume flags are.
- **Output:** parse what the tool emits; translate to the same chunk vocabulary.
- Treat pi.dev as the third example proving the abstraction holds for an arbitrary agentic CLI. If a future tool surfaces something the abstraction can't represent (e.g., interactive approval prompts), that triggers a Layer-1/Layer-2 contract change.

---

## Layer 2 — abstraction

Two new types in `internal/providers/`:

```go
// providers.go — addition
type StatefulProvider interface {
    Provider  // for Type() + RenderThinkingToText() + Capabilities()
    // SendStateful runs one turn against a session-keyed harness.
    // Returns:
    //   - chunks: the live event stream; closes at terminal
    //   - result: blocks AFTER chunks close; carries the (possibly
    //     new) session id, usage, and total cost
    //   - err: spawn / connect-time errors only; runtime errors land
    //     on chunks as ChunkError
    SendStateful(ctx context.Context, req StatefulSendRequest) (
        chunks <-chan Chunk,
        result func() StatefulResult,
        err error,
    )
}

type StatefulSendRequest struct {
    SessionID  string  // "" = new session
    Prompt     string  // the latest user message AS-IS — no history
    WorkingDir string
    Model      string
}

type StatefulResult struct {
    SessionID    string
    Usage        *Usage
    TotalCostUSD *float64
}
```

And a single driver type in `internal/providers/harness/`:

```go
// internal/providers/harness/harness.go
type Driver struct {
    h harnesses.Harness
}

func New(deps providers.Deps, config json.RawMessage) (providers.Provider, error) {
    var cfg Config
    json.Unmarshal(config, &cfg)
    h, ok := harnesses.Lookup(cfg.HarnessName)
    if !ok {
        return nil, fmt.Errorf("unknown harness %q", cfg.HarnessName)
    }
    return &Driver{h: h, cfg: cfg}, nil
}

type Config struct {
    HarnessName string   `json:"harness_name"`  // "claude" | "codex" | "pi"
    Binary      string   `json:"binary"`        // path to CLI; default = harness.DefaultBinary()
    Env         []string `json:"env"`           // KEY=VALUE; passed to every spawn
}
```

Three driver types are registered at init():
- `harness-claude` → `harness.Driver` configured for the claude harness
- `harness-codex` → `harness.Driver` configured for the codex harness
- `harness-pi` → `harness.Driver` configured for the pi harness

Each shows up in the model-providers picker as a separate provider preset.

---

## Conversations service changes

Today the SendMessage flow:

1. Resolve provider/model
2. Insert user message in TX
3. Build wire prefix via history.Build
4. Construct SendRequest with full message history
5. Closure SendFunc → driver.Send(req) → chunks
6. Hand SendFunc to supervisor.Start

For stateful providers, the flow forks at step 3:

1. Resolve provider/model — same
2. Insert user message in TX — same
3. **If StatefulProvider:**
   a. Look up session id from `conversation_harness_sessions`
   b. Resolve working_dir from the profile chain (`profiles.Resolve(...).DefaultSettings.HarnessWorkingDir`). Reject with `FailedPrecondition` if empty / missing-on-disk / not-a-directory.
   c. Construct StatefulSendRequest{SessionID, Prompt: userMsgRow.Content, WorkingDir, Model}
   d. SendFunc closes over both:
       ```go
       sendFunc := func(ctx context.Context) (<-chan providers.Chunk, error) {
           chunks, result, err := stateful.SendStateful(ctx, req)
           if err != nil { return nil, err }
           // Wrap chunks so we can fire a callback at terminal —
           // persist the (possibly new) session id back to the join
           // table.
           wrapped := make(chan providers.Chunk, 32)
           go func() {
               defer close(wrapped)
               for c := range chunks { wrapped <- c }
               r := result()
               if r.SessionID != "" {
                   _ = upsertHarnessSession(conv.ID, providerID, r.SessionID, workingDir)
               }
           }()
           return wrapped, nil
       }
       ```
4. **Else (StatelessProvider):** existing path
5. Hand SendFunc to supervisor.Start — same; supervisor doesn't care which path produced the chunks

The supervisor doesn't change. The session-id persist runs in the goroutine that drains the chunks; by the time the supervisor materialises the assistant message, the join-table row is updated.

---

## Data model

### `profiles.default_settings.harness_working_dir` — new

The working directory lives on the **profile**, not the conversation. Reeve already treats profiles as "this is configured to do X for a project" (system message + default model + plugins + compression knobs); a project's working dir is a natural sibling of those settings, and it inherits through the profile parent chain via the existing resolver.

Stored inside the existing `profiles.default_settings` JSONB blob (no new SQL column) under the new `ProfileDefaults.harness_working_dir` proto field. `profiles.Resolve` walks the parent chain to surface a non-empty value the same way it already does for `default_provider_id` / `default_model_id`.

Implications:
- One profile per project the user wants to harness against.
- Editing a profile's working dir affects every conversation under it (and child profiles that inherit). The harness MAY handle a mid-session cwd switch gracefully, but in practice most users will create a new profile when starting work in a new repo.
- A profile with `harness_working_dir` set is still usable with non-harness models — the field is silently ignored when the active provider isn't a `StatefulProvider`.
- A profile without `harness_working_dir` (and no parent providing one) cannot be used with a harness provider — the conversations service rejects with `FailedPrecondition` and the message "set the working directory on the profile to use a harness model".

### `conversation_harness_sessions` — new

```sql
CREATE TABLE conversation_harness_sessions (
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    provider_id     UUID NOT NULL REFERENCES user_model_providers(id) ON DELETE CASCADE,
    session_id      TEXT NOT NULL,
    last_used_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (conversation_id, provider_id)
);
```

One session per (conversation, harness-provider) pair. A conversation can have multiple rows if the user toggles between harness providers mid-conversation (uncommon but valid — e.g. starting with Claude Code, switching to Codex). Each turn's send uses the row matching the active provider.

Working dir does NOT live here — it's resolved fresh from the profile chain on every send. If a user moves their project after starting a conversation, editing the profile is enough; no per-conversation row to update.

### `user_model_providers.config` — shape for harness types

```jsonc
{
  "harness_name": "claude",  // resolves to the Layer-1 Harness impl
  "binary":       "/usr/local/bin/claude",  // empty = harness.DefaultBinary()
  "env":          ["PATH=/usr/local/bin:/usr/bin", "HOME=/Users/jdp"]
}
```

Same env-vars-explicit pattern as the MCP plugin — subprocess inherits NOTHING from reeved's environment beyond what's listed.

---

## Working directory handling

A profile carries the working directory; every conversation under that profile uses it. UX:

- **Profile form** (`ProfilesView.swift::ProfileForm`): when the resolved default model is a harness provider (or any harness provider is enabled for the user), the form surfaces a "Working directory" field — directory picker (`NSOpenPanel` with `.canChooseDirectories=true, .canChooseFiles=false`). Stored in `default_settings.harness_working_dir`. Inherits from the parent profile when blank.
- **No conversation-level UI.** A conversation has whatever wd its profile resolves to.
- **Validation** at send time: the conversations service rejects with `FailedPrecondition` when (a) the active provider is a harness AND (b) the resolved profile chain produces no `harness_working_dir`, or the dir doesn't exist on disk, or it isn't a directory.
- **Conversation-list rows** under a harness profile show the dir as a small caption ("Coding · ~/projects/foo") so the user can see at a glance which conversations write to which directory.

Switching the conversation's per-turn model to a non-harness provider is allowed — the working dir just stops being consulted. Switching back uses the same dir + the same persisted session row.

Editing the profile's wd while conversations are active under it: future sends use the new value. Most harnesses tolerate a mid-session cwd switch (`--resume` reads from the new dir); if a user wants strict isolation they make a new profile. Profile-as-the-unit-of-project-binding aligns with how Reeve already groups configuration.

---

## Features unavailable inside a harness conversation

The harness owns its session — Reeve doesn't see the transcript, doesn't dispatch tools, doesn't control history. Several Reeve features depend on owning the conversation transcript and have to be hidden / disabled when the active provider is a `StatefulProvider`. Listed here so the UI work has a single reference.

### Compaction (Compact button)

Compaction takes the Reeve-side wire history, asks an LLM to summarise it, and inserts the summary as the new context root. For harness sends Reeve doesn't send wire history at all — each turn just ships the latest user prompt to a session-resumed harness — so there's nothing meaningful to summarise on Reeve's side. The harness's own session storage manages long-conversation pressure internally (Claude Code, Codex both compact behind the scenes).

**UI effect:** Compact button hidden in `ConversationView`'s toolbar when the active provider is a harness; Contexts page hides the "promote pending compaction" affordance. The button's keyboard shortcut also no-ops.

### Edit user message ("Edit" / "Save and resend")

Editing a user message in a native conversation re-anchors the wire history at that point — the old bytes get replaced and the next send rebuilds the prefix. For harness sends the prior turn already reached the harness's session storage; an edit on Reeve's side doesn't propagate. Worse, "Save and resend" would push the EDITED text as a brand new turn into the session, leaving the harness with both the old and the new in its internal history — silently confusing.

**UI effect:** edit affordance hidden on user messages in harness conversations. `MessageRow.contextMenuItems` checks the conversation's active provider and elides the Edit item.

### Reload from message ("Reload from here")

Same root cause. The native flow forks a new assistant turn from the chosen ancestor by rebuilding wire history from that point. The harness session is monolithic — there's no protocol message for "redo from turn N." Replaying every prior turn through the harness is also wrong (it would compose the harness's old responses with Reeve's idea of history, drifting badly).

**UI effect:** Reload affordance hidden on every message in harness conversations. Where users want a do-over: cancel the in-flight stream and ask again.

### Forking (branching from a non-leaf message)

Same monolithic-session reason. A fork would need the harness to support session-clone (Claude Code does have a session-fork on disk; Codex doesn't). Even where supported, plumbing a per-fork session-id through Reeve's branch machinery is its own sub-feature. Defer until at least one harness exposes it cleanly.

**UI effect:** sibling-count indicators don't appear on harness-conversation messages; the right-click "Reload from here" path that would create a sibling assistant turn is hidden as above.

### Plugin pipeline (mixed)

Plugins compose with harness sends, but only the capabilities that don't depend on owning history apply.

| Capability | Behaviour on harness sends |
|---|---|
| `Configurable` | N/A — applies to plugin config UI, unrelated |
| `SystemPrompter` | **No-op.** The harness owns its system prompt. Contributions silently dropped. |
| `OutgoingUserTransformer` | **Applies.** The latest user message runs through the pipeline before being passed to the harness. (`basic_grounding`'s timestamp prepend works correctly.) |
| `HistoryTransformer` | **No-op.** Harness owns its history; Reeve doesn't render a wire prefix to transform. |
| `ChunkTransformer` | **Applies.** Harness output chunks flow through the pipeline the same way native-driver chunks do. |
| `DisplayTransformer` | **Applies.** Final assistant content gets display-transformed the same way. |
| `ToolProvider` | **No-op.** The harness has its own tools; tool_use chunks coming back from the harness are informational only. Reeve doesn't dispatch. |
| `AssistantContentTransformer` | **Applies.** Same as native drivers. |
| `MessageLifecycleHook` | **Applies.** Fires for every message persist regardless of provider type. |

**UI effect:** the profile-form plugin cards grey the no-op capability chips when the profile's resolved default model is a harness — surfaces the "this part of the plugin won't run here" signal in the editor where attachments are decided. The pipeline runs as today; no-op capabilities just have nothing to do.

### Per-turn model switch (allowed but warns on the way OUT)

Per-turn provider/model overrides still work in harness conversations:
- Harness → another harness: creates a new `conversation_harness_sessions` row for the second harness; both sessions stay independent.
- Harness → native API: the next turn ships only the LATEST user message to the API (Reeve's wire history for the harness conversation is mostly empty — every turn looks like one user + one assistant, with all the harness's internal context invisible to Reeve). Switching to a native API mid-conversation effectively starts a fresh chat with no context. **UI effect:** show an inline warning when the user picks a native model for a turn under a harness profile: "this model won't see the harness's prior context — only your latest message".

### Message-level branching cursor (current_leaf)

Still used — every send still advances the cursor to the just-materialised assistant message. The cursor mostly does nothing interesting in a harness conversation since the tree is linear (no forks), but the bookkeeping costs nothing and keeps the data shape uniform.

### What still works

- Streaming text + thinking deltas
- Tool-call rendering (informational, via the existing tool-call UI we built)
- Cancellation mid-stream
- Cost + token reporting on each assistant message (sourced from the harness's `result.total_cost_usd` / equivalent)
- `MessageLifecycleHook` plugins (embedding generation, audit logs, etc.)
- DisplayTransformer + AssistantContentTransformer plugins
- Conversation delete (cascades through `conversation_harness_sessions` — the harness's own session storage is orphaned, which is fine; users can `claude /resume` or equivalent to recover if needed)

---

## Per-harness CLI specifics (cheat sheet)

Recorded here so the Layer-1 implementations have a single reference.

### Claude Code

| Concern | Flag / behaviour |
|---|---|
| Print mode | `-p` |
| New session | omit `--resume` (writes a fresh session id; surfaced in the `system.init` event) |
| Resume session | `--resume <session_id>` |
| Output format | `--output-format stream-json` (NDJSON of typed events) |
| Working directory | `--cwd <dir>` (or `cwd` set on subprocess) |
| Model | `--model <id>` |
| Cancellation | SIGINT first, SIGKILL after 5s grace |
| Session-id source | `system.init.session_id` and final `result.session_id` |
| Usage / cost | `result.usage` (tokens) + `result.total_cost_usd` |

### Codex CLI

| Concern | Flag / behaviour |
|---|---|
| Print mode | `exec` subcommand |
| Output format | `--json` (NDJSON of typed events) |
| Resume session | `-c "experimental_resume=<session_id>"` (config override; the supported flag for v1) |
| Working directory | `--cwd <dir>` |
| Model | `--model <id>` |
| Session-id source | `thread.started.thread_id` and `turn.completed.thread_id` |
| Usage | `turn.completed.usage` |
| Cancellation | SIGINT (Codex catches and tears down cleanly); SIGKILL after grace |

### pi.dev

To-be-confirmed when we wire it. Filling in the same row of the cheat sheet is the deliverable.

---

## Cancellation

The supervisor's existing Cancel path triggers context cancellation on the SendFunc's context. Layer-1 implementations honour this by:

1. Sending SIGINT to the subprocess
2. Waiting 5 seconds for clean exit
3. SIGKILL on timeout
4. Closing `Chunks` after the subprocess has reaped

`Result()` returns the partial state (whatever session id we got mid-stream, partial usage if reported). The conversations service still upserts a session id when present — a half-finished turn might still have produced a usable session.

---

## Phasing

| Phase | Scope | Estimate |
|---|---|---|
| **0 — Infrastructure** | `internal/harnesses/harness.go` (interface + registry), `internal/providers/StatefulProvider`, `internal/providers/harness/Driver`, conversations.Service.SendMessage stateful branch, `conversation_harness_sessions` table + queries, `conversations.harness_working_dir` column. No actual harness yet — all wiring with a fake harness used in tests. | ~1 week |
| **1 — Claude Code** | `internal/harnesses/claude/` — fully working against the real `claude` CLI. Stream parser, model catalog, session-id capture, cancellation. | ~1 week |
| **2 — Mac UI** | Profile form: working-directory picker on `default_settings.harness_working_dir` (only required-feeling when the resolved default model is a harness). Provider-config form: harness-specific binary + env fields. Conversation header / settings: surface resolved working dir + session id (read-only). Hide the disabled affordances per the "Features unavailable" matrix (Compact, Edit, Reload, Fork). Inline warning on per-turn switch from harness → native API. Conversation list rows under harness profiles caption the working dir. | ~1 week |
| **3 — Codex CLI** | `internal/harnesses/codex/` — second harness. The fact that this is a clean addition (one new package + one provider type registration) is the test of the abstraction. | ~3-5 days |
| **4 — pi.dev** | `internal/harnesses/pi/` — third harness, finalises the cheat sheet, finalises the abstraction. | ~3-5 days |
| **5 — Polish** | Capability chip greying for harness sends, working-dir validation hardening, missing-binary diagnostics, surface harness stderr in a "diagnostics" popover. | ~1 week |

Phase 0 + 1 ship the first usable end-to-end. 3 / 4 are independent and parallelisable once 0/1 land.

---

## Open threads (revisit when their phase lands)

- **Harness daemon / persistent process.** Subprocess-per-turn is simplest but a Claude Code spawn from cold start measures ~1.5–3 seconds. If that becomes a real complaint, persistent-daemon harness wraps (with IPC over a Unix socket) is worth designing — at the cost of significantly more state to manage. The Layer-1 `Harness` interface is shaped to hide whether subprocess-per-turn or daemon-RPC is used underneath, so the conversion is local.
- **Forking inside a harness conversation.** When a harness grows programmatic session-fork support, expose it via the existing branch-from-message UI. Until then: harness conversations don't render the fork affordances.
- **Compaction.** Hidden today for harness conversations. If a harness exposes its own compaction trigger, wire it under the existing Compact button (per-provider behaviour selector).
- **Multi-modal attachments via harness.** `multimodal-plan.md` Phase 1 lands the WireMessage attachment shape; the harness layer can take attachments by writing them to temp files in the working dir and pasting paths into the prompt, OR by piping bytes through whatever attachment-passing convention each harness adopts. Re-decide per harness.
- **Sandboxing.** Harnesses run arbitrary code on the user's machine. Reeve already trusts the user (it's self-hosted). When the multi-tenant story lands, harness sends will need to grow a "sandbox profile" — at minimum, a chrooted working dir with no network. Out of scope here.
- **Provider Files API caching for harness output.** Mostly N/A — harnesses output text + tool events directly, not files. Re-evaluate if any harness grows server-side file caching.
- **Cost attribution accuracy.** Different harnesses report cost in different ways and units. Trust the harness's `total_cost_usd` for v1; surface it on the message-cost popover with a "as reported by the harness" disclaimer.
- **Per-conversation working-dir override.** Profile-level is the right default — a user with one project per profile is the common shape. If real users start wanting "same profile, different dir per conversation" (e.g. several worktrees of one repo), add an optional `conversations.harness_working_dir_override` that, when set, supersedes the profile's value at send time. Defer until requested.

---

## How to use this doc

Track phase progress here as bullets crossed off / moved into `todo.md`'s shipped record. Decisions that turn out wrong get amended inline; per-harness CLI quirks discovered during implementation get folded into the cheat sheet.
