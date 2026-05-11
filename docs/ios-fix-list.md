# iOS fix list (May 2026)

Working doc that survives compaction. Each item starts as a one-line
gripe from the user; questions get asked one at a time and answers
get folded back in here. Once an item is well-defined enough to act
on it goes in the **Ready to fix** section at the bottom. Items in
progress should also live in the TaskCreate task list.

## Ready to fix (proposed priority order)

The user-pain-vs-effort ranking I'd suggest. Numbers in
parentheses link back to the original list (preserved below for
the full discussion that produced each decision). Items marked
✻ are explicit duplicates folded into another item.

1. **Revert first-user collapsed strip** (#9) — undoes a recent
   ship; trivial.
2. **Edit modal open/close loop** (#10) — force-quit-required
   bug. Hoist sheet to single host on ConversationView via
   `.sheet(item:)`.
3. **Stream-end scroll jerkiness** (#3, ✻ #8 deletion case) —
   user has a precise behavioral spec. Drop count-driven
   scrollTo; honor `autoFollow` strictly.
4. **Stream idle-timeout policy** (#4, ✻ #7 long-turn deadline
   errors) — replace fixed wall-clock deadline with first-chunk
   + idle-timeout. Fixes both compression timeouts and the
   "deadline exceeded" failures.
5. **Layout overhaul: assistant drops bubble + fork-switcher
   pill, fork shows at stream start** (#11) — visual change
   plus the late-appearing-fork bug.
6. **Manual context creation** (#6) — new flow with Replace /
   Append picker.
7. **Cascade-delete-with-replies** (#12) — separate context-menu
   item; cascade flag already exists server-side.
8. **Compression card from first chunk** (#5) — variant of
   `CompressionSummaryCard` for the streaming phase.
9. **Bullet text truncation in markdown** (#2) — likely
   `MarkdownText`/swift-markdown-ui width race. Lower priority
   because cosmetic-but-not-blocking.
10. **Finish reason on bubble footer when unexpected** (#1) —
    needs server-side schema + proto + driver capture.
11. **Cost ledger + Settings → Cost screen** (#13) —
    enhancement. New `cost_events` table, RPC, settings page.

_(See the **Detail** section below for the full per-item
context, including likely culprits, decisions, and touches.)_

## Detail (in original numbering)

### 1. Finish reason
**Decision so far:** show the assistant turn's finish reason on the
bubble footer, **only when unexpected** (anything other than `stop`
/ `end_turn`). Render position: the line **directly underneath the
cost / cache line**.

**Open**:
- Server doesn't currently persist a finish-reason column on
  `messages` — driver code sees it (Anthropic `stop_reason`,
  OpenAI `finish_reason`, Google `finishReason`) but throws it
  away. Need migration + proto field + driver capture before iOS
  can render anything.
- Per-driver normalisation: map all three providers' vocabulary
  into one enum the UI can switch on (`length`, `tool_use`,
  `content_filter`, `cancelled`, `other(raw)`).

### 2. Bullet points truncated (iOS)
**Symptom:** markdown bullet text gets truncated with `…`.
- Not every bullet. Inconsistent. Affects longer bullet items.
- Nested-vs-flat: not confirmed yet.
- During streaming, the bullet flashes between truncated and full
  several times, then usually settles on **truncated**.
- Reads like a SwiftUI sizing race: the bullet's Text view is
  receiving a too-small frame on one of the measurement passes
  and an internal `lineLimit` is kicking in. Suspect inside
  `MarkdownText` (swift-markdown-ui) — table/list rendering does
  its own width math.
- Reproduces only on iOS so far; Mac unaffected (worth a check
  during fix to confirm).

**Likely investigation start:**
- `clients/ReeveSwift/Sources/ReeveUI/Composite/MarkdownText.swift`
  and how it inherits `chatPaneWidth`.
- Check whether the bubble's `.frame(maxWidth: cap, alignment:)`
  is propagating to the markdown renderer correctly during the
  streaming → settled handoff.

### 3. Finish message jerkiness
**Symptom:** at stream end the viewport jumps unpredictably —
sometimes back 2–5 messages, sometimes down to a blank screen
that requires several swipes to scroll back up. No tool calls
involved in the repro the user described.

**Desired behavior (the user spec, verbatim, in my words):**
1. While streaming and auto-follow is on, follow the stream
   smoothly so the bubble grows downward at the bottom of the
   viewport.
2. When the streaming bubble's **top edge** reaches the top of
   the viewport, pin it there — let text continue to grow below
   off-screen. Do **not** keep scrolling.
3. If the user manually scrolls at any point, turn off auto-
   follow and **never** reposition the viewport for them again.
4. On stream end (`.terminal`), the viewport must not move.
   Specifically: replacing the StreamingRow with the real
   settled MessageRow must not trigger any scroll.

**Likely culprits, to investigate later:**
- `ConversationView.swift` →
  - `.onChange(of: model.messages.count)` does
    `proxy.scrollTo(messages.last?.id, anchor: .top)` — that's
    the "back 2–5 messages" effect (lands the new row's TOP at
    viewport top, exposing earlier rows above).
  - The streaming `onChange` uses anchor `.bottom`; once
    `__streaming__` disappears at terminal the proxy may resolve
    to nothing and snap, producing the "blank screen" case.
- `autoFollow` isn't currently honored on `messages.count`
  change.

**Implementation sketch (for later):**
- Drop the `scrollTo` on `messages.count`. Replace with a one-
  shot scroll-to-last-on-conversation-load only.
- During streaming, when `streamingText` changes, compare the
  current scroll-y against a saved offset; once we've reached
  "top of __streaming__ at viewport top", stop emitting
  scrollTo calls.
- On `.terminal`, don't emit any scrollTo at all. The settled
  MessageRow takes the same vertical space as the StreamingRow
  it replaces (modulo the footer, which is small).
- Verify `autoFollow=false` short-circuits every scrollTo path.

### 4. Compression timeout *(generalised: stream idle-timeout)*
**The real problem:** the timeout policy on LLM-stream calls is
too blunt. A fixed wall-clock deadline kills long-but-healthy
streams (slow reasoning models, long responses); a too-short one
also kills compression. Compression timing out is a symptom of
the same bug, not a one-off.

**Desired policy:**
- **Pre-first-token timeout** (call it `firstChunkTimeout`): how
  long we wait for the *first* stream chunk. If nothing arrives
  in N seconds (default TBD — probably 30s), fail with a clear
  "model didn't respond" error.
- **Idle timeout** (call it `idleTimeout`): once we've seen at
  least one chunk, the deadline becomes a rolling 60s reset on
  every received chunk. Stream is healthy as long as chunks
  keep arriving; idle for 60s in a row = dead.
- No overall wall-clock deadline.

**Touches:**
- Server-side, in the per-provider drivers (or in the supervisor
  if the cancellation gate lives there). Need to replace any
  `context.WithTimeout` over the whole call with a
  `context.WithCancel` that's reset/extended on each chunk.
- Compression path uses the same primitive (one assistant turn
  with a different system prompt) so it picks up the fix for
  free.
- Anthropic SDK, OpenAI SDK, Google SDK all expose chunk-by-
  chunk iteration — the reset hook lives in the loop that reads
  chunks from each.

**Surface:**
- On failure, the assistant message row records `error_text` and
  the existing "FAILED" rendering kicks in. Probably no new UI.
- Worth surfacing the *kind* of timeout (pre-first vs. idle) in
  the error message so the user can tell whether the model
  never started vs. stalled mid-stream.

### 5. Compression message formatting
**Symptom:** while a compression call is streaming, the in-flight
bubble renders as a regular assistant message (StreamingRow
chrome). At terminal, it snaps into the special
`CompressionSummaryCard` styling. The snap is jarring.

**Desired:** the compression turn looks like a compression card
**from the first chunk** through completion. No visible role/
style swap on terminal.

**Touches:**
- `clients/ReeveSwift/Sources/ReeveUI/Composite/StreamingRow.swift`
  is currently role-agnostic — receives just text, thinking, tool
  calls. Needs a hint that the active stream is a compression
  call so it can render with `CompressionSummaryCard` chrome
  (or a parallel `CompressionStreamingCard` view).
- `ConversationViewModel.isCompacting` is already a published
  flag — the conversation view can branch on it when picking
  which streaming view to render.
- `CompressionSummaryCard.swift` may need a sibling that takes
  live-streaming text instead of a settled `ReeveMessage`.

### 6. Need manual way to create context
**The gap:** today new contexts only come into being via Compact
(the LLM generates a summary then promotes the result to a new
context). The user wants to start a new context directly,
without going through compression — useful when the user already
knows what they want the context message to say, or wants no
prior-context message at all.

**UX:** "New context" affordance somewhere reachable from the
Contexts list (likely a `+` in the toolbar). Opens a sheet with:
- A blank text input for the **initial user message** of the
  new context.
- A picker between **Replace** and **Append** — same semantics
  as `ReeveCompressionMode`. Replace = the new context has no
  prior-context message; Append = the new context inherits /
  chains off the prior context's existing context message.

**Touches:**
- New RPC `Conversations.CreateContextManual(conversation_id,
  initial_user_message, mode)` — or extend the existing
  Compact RPC with a `manual: true` flag that skips the
  summarisation step.
- Server-side: same promotion path as compression; just skip
  the LLM call and seed the new context directly.
- iOS `ContextListView`: toolbar `+` → presents the sheet.
- Mac: same affordance.

### 7. Deadline exceeded errors
**Symptom:** "deadline exceeded" surfaces inside the assistant
message bubble's FAILED state. Happens on long turns (long
reasoning, long output).

**Diagnosis:** same root cause as #4. The fixed wall-clock
deadline kills healthy-but-slow streams. Implementing the idle-
timeout policy from #4 should make this go away. **No separate
fix needed — close as duplicate once #4 lands.**

### 8. Scroll too far down on end sometimes
**Same root cause as #3** — `onChange(of: model.messages.count)`
fires `scrollTo(messages.last?.id, anchor: .top)` on any messages-
array length change. That covers stream end (count grows by one
when the assistant row materialises) **and** message deletion
(count shrinks). The deletion case manifests intermittently for
the same reason: depending on where the user is and which row
ended up "last", the scroll-to-last either no-ops (already at
the bottom) or yanks the viewport.

**Fix:** the implementation sketch under #3 — drop the
`messages.count`-driven scrollTo and gate everything on the
`autoFollow` flag — handles this too. **Close as duplicate of
#3 once that fix lands.** Worth a deletion-specific check during
verification.

### 10. Edit modal open/close loop
**Symptom:** opening the Edit sheet sometimes traps the app in a
loop — sheet animates up, then closes, then re-presents,
repeatedly. Visible animation each cycle. Affects both user and
assistant edits. Only escape so far is force-quitting the app.

**Prime suspect:** the sheet is hosted on **every** MessageRow,
keyed by a computed binding:
```swift
.sheet(isPresented: Binding(
    get: { isEditing },                              // model.editingMessage?.id == message.id
    set: { if !$0 { model.editingMessage = nil } }
))
```
SwiftUI re-evaluates the binding's get on every parent render,
and `model.editingMessage` is on an `@Observable` view-model so
ANY field change on that VM nudges the get. Combined with the
sheet's own dismiss-on-state-change behavior, this can race:
animate-up → some VM mutation in onAppear → get re-eval flips
briefly → set(false) → `editingMessage = nil` → another path
re-derives → loop.

Also possible: every row in the chain hosts its own sheet
modifier. Only one row's `isEditing` is ever true, but every
row's binding observes the same `editingMessage` field. If
SwiftUI gets confused about which row's sheet "owns" the
presentation during a load() that swaps message identities,
the wrong row's binding might fight the right one.

**Fix candidates (later):**
- Hoist the sheet to a single host (ConversationView body),
  driven by `.sheet(item: $model.editingMessage)`. Identifiable-
  item presentation has the right semantics: present when
  non-nil, dismiss + clear on dismiss. Eliminates the per-row
  binding race entirely.
- If keeping per-row hosting: replace the computed binding with
  a per-row `@State presenting: Bool` that's synced via
  `onChange(of: isEditing)`. The sheet observes `presenting`
  only, breaking the re-eval loop.

Hoisting is the cleaner option — also simplifies state plumbing
because `EditMessageSheet`'s @Binding inputs collapse into the
sheet's own @State.

### 11. Layout: assistant messages drop the bubble; fork switcher relocates
**Decisions:**

(a) **Assistant messages** stop using a bubble entirely. No fill,
no rounded rectangle, no role-aligned width cap — the markdown
content reads as page content, full screen width. Header row
(role label + model chip) and footer (cost / cache dot /
timestamp) still render, just without the bubble chrome around
them. User messages **keep** the existing bubble (right-aligned,
accent fill).

(b) **Fork switcher placement:**
- **User messages** — bump-out pill anchored to the **top-right**
  corner of the user bubble (overlapping the bubble border
  slightly). Chevron-left, "1/2", chevron-right inline.
- **Assistant messages** — same pill, floating in the top-right
  of the assistant message region (since there's no bubble to
  bump out of, it just sits in the corner).
- Always visible when sibling count > 1; hidden otherwise.

(c) **Fork switcher must appear at stream start**, not only after
the stream finishes. Today it pops in late, which is
disorienting — the user can't tell whether a fork was created.
Likely cause: `model.branchInfo(for: id)` reads from
`treeMessages`, which is loaded by `loadTree()` after `.terminal`
fires. Need to either (i) reload the tree at stream start so
sibling info is available before the first chunk, or (ii) fold
sibling-count into the stream-create response so the
`StreamingRow` can render the switcher from the first paint.

**Assistant-pill placement:** option (b) — right edge of the
message region, floating slightly **above** the role-label row
so it reads as a true bump-out, with a small gap between the
pill and the role label / assistant text below. Same chip shape
on user and assistant; only the anchor differs (user = on the
bubble's top-right border; assistant = above the role-label
row).

**Touches:**
- `MessageRow.swift` — split bubble rendering by role; the
  `roleAlignedContainer` and `bubbleBackground` paths only
  apply to user, default, etc.
- New "fork switcher pill" view (replaces the inline chevrons in
  `branchSwitcher`), positioned via `.overlay(alignment: .topTrailing)`.
- `ConversationViewModel`: kick `loadTree()` at stream start, or
  surface sibling info on the SendMessage response.

### 12. Delete message: cascade-delete-with-replies option
**Decisions:**
- The context menu gets a **separate** new item — "Delete all
  replies…" — alongside the existing Delete. The existing Delete
  keeps its current single-message-with-reparent semantics.
- The new item shows a single confirmation alert ("Are you sure?
  This deletes the message and N replies underneath it.") with
  a destructive Yes / Cancel. No typed-confirm friction. The
  "double" comes from picking the destructive menu item + then
  confirming.

**Touches:**
- Server: the Conversations.DeleteMessage RPC already supports a
  `cascade` flag (per `internal/conversations/edit_delete.go`)
  — the iOS path currently always passes the non-cascade
  variant. Need to thread a cascade boolean through the
  ViewModel's `deleteMessage(id:)` method.
- `MessageRow.swift` context menu: add the new item; show only
  when the message has children (otherwise cascade = the same
  as a normal delete).
- Compute "N replies" client-side from `model.treeMessages` so
  the alert can show an accurate count.

### 13. Cost ledger: per-provider running tally
**Decisions:**
- Storage: a new table outside `messages` and `conversations`,
  append-only, survives source deletion. Per-row payload is just
  `{ user_id, provider_id (= user_model_providers.id), model_id,
  amount_usd, reason, created_at }` — no token-component
  breakdown (the existing per-message detail is good enough at
  the message level; this ledger is reporting only).
- Granularity: per **configured provider row** (so two
  Anthropic configurations track separately).
- Capture every spend: chat turns, compression, auto-titling,
  any failed/cancelled turn that incurred upstream cost.
- No backfill — feature is zero-state on the day it ships.
- Reporting buckets: per-day, per-week, per-month, all-time.
- New top-level **Settings → Cost** screen (separate from
  Providers). Defers the per-provider drill-down location and
  deleted-provider handling — tackle when implementing.

**Touches (sketch):**
- Migration: `cost_events` table.
- Server: write a row at the same point we set
  `messages.*_cost_usd`. Probably an `internal/cost` package
  with one entry point `Record(...)`. Wire it from the supervisor
  + compression + title paths.
- Server: a `CostService` RPC with `GetCostReport(range, group)`
  returning aggregated buckets.
- iOS: new `CostDetailView` reachable from `SettingsRoot`.
- Mac: same view, mirrored.

### 9. First user message shouldn’t be formatted like system message
**Decision:** revert the change shipped in commit `189c724f`
that made the initial user message a collapsed-header strip.
Revert just the parts of `MessageRow.swift` that:
- added `.user` to `isCollapsibleHeaderRole` via the
  `isInitialUserMessage` check
- introduced the `isInitialUserMessage` computed property

The collapse-on-expand affordance (chevron-up on the role label)
should stay for `.system` and `.context` — that part of the
commit was correct and unrelated. The Edit-as-modal sheet also
stays — also correct.

**Touches:** `clients/reeved-ios/ReeveiOS/Chats/MessageRow.swift`
only. Trivial.
