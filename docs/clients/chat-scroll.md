# Chat scroll architecture

The conversation transcript is the hardest view in the app. This doc records how the iOS scroll machinery works, the failure taxonomy behind months of "scroll jumps during generation" reports, and the repro harness that finally made the transients observable. Read this before touching `ConversationView.swift` scroll code on either platform. The Mac ConversationView has NOT received this architecture yet (see "Mac status" below).

## The one governing principle

Every visible scroll bug in this view's history came from the same physics: **LazyVStack's content size is an estimate wherever rows aren't realized, and any scroll command solved against an estimate lands wrong when the estimate refines.** The refinement happens in a *different layout pass* than the command, so the viewport visibly moves once (wrong target), then again (correction). On a fast simulator both passes land inside one frame and nothing is visible. On a device they straddle visible frames: the user sees the jump, then the snap-back.

At ~400 heavy messages (1.3M points of content) this stops being a tuning problem and becomes a wall. Measured on 2026-07-18, all in one afternoon: a one-shot id-solve landed ~3,000pt short and its re-solves wandered instead of converging; a held edge position oscillated ±1,713pt per tick against the UIKit clamp at 60Hz; convergence re-seeking against live content closed into a feedback loop with the re-estimator (content estimate swung 1.29M→343k, main thread 100% in `AG::Graph`). The design rule that fell out: **during streaming, nothing scrolls, and the one position that matters is established by construction, not by solving.**

The corollaries:

1. The **system bottom anchor** (`defaultScrollAnchor(UnitPoint(x: 0, y: 1), for: .sizeChanges)`) solves *inside* the layout pass, in lockstep with realization. Offset and content height move together; nothing is visible. It is the only primitive allowed to hold the viewport through content mutation, and its verified use is prepends while settled at the bottom (entry backfill). It is NOT position-preserving from arbitrary offsets: a backfill run while the viewport sat at the top of a collapsed window dumped the viewport at the top of the full history.
2. Explicit `scrollTo` commands are allowed only transiently — entry seek over the realized 12-row tail, pill seek, past-bottom clamp — and the geometry handler drops any live position (replaces the binding with a fresh `ScrollPosition()`) the first time it observes settled-at-bottom at rest. A held position keeps re-solving on every content change, and the `Edge.bottom`/`.top` flavors re-solve center-x against estimated widths, parking the transcript 16pt left (the "margins shifted left" bug). Leading-x anchors (`UnitPoint(x: 0, y: 1)` / `(0, 0)`) everywhere a point anchor is needed.
3. **There is no auto-follow, and the send pin scrolls exactly once, from measured geometry.** History stays mounted (a window collapse was shipped briefly and read as data loss — every prior message vanished mid-stream — and its post-terminal remount could strand the viewport in estimate-space; user-reported, reverted). At send, the pending row reports its `.scrollView`-space minY and the pin is one absolute `scrollTo(y: offset + minY − 20)` — both quantities measured, no estimate participates. The full-viewport runway below the reply makes the target always reachable (an under-sized runway put the target past max-scroll, and the held past-end position resolved with a −788pt yank at the row swap), and the jump waits for a geometry tick whose contentHeight already includes the runway (clamping against a pre-runway max ate 490 of 568 points). After the jump the shrinking runway keeps content height constant, so the frozen offset is the pin: verified pixel-identical frames through mid-stream and terminal at 406 heavy messages.
4. Whatever cannot be prevented must be **observable**: the geometry handler logs offset discontinuities, past-end excursions, width breakouts, and horizontal drift at notice level (`subsystem dev.jdpedrie.psmith`, category `ChatScroll`), so a device repro is diagnosable from `log collect` after the fact. Mind the thresholds when reading the logs: `CONTENT-LURCH` fires only above 120pt, so a coalesced stream rendering ~2 words per flush is invisible to it — "no lurches" does not mean "nothing rendered" (this misread cost half a day chasing a stream-delivery failure that didn't exist).

## Mechanics (iOS, current)

State lives on `ConversationBody` (`clients/psmithd-ios/PsmithiOS/Chats/ConversationView.swift`):

- **Cold entry**: mount only the newest `coldEntryTail` (12) rows, seek `scrollTo(edge: .bottom)` in `onAppear`. Twelve rows realize fully in one pass, so the content size is exact and the seek lands true. Handing LazyVStack 200+ rows in one shot instead accumulates all its estimate error as phantom blank space *below* the last message (device-confirmed: ~5 screens of desert).
- **Entry curtain**: the transcript renders at opacity 0 (layout fully live) until the geometry handler first observes the viewport settled at the bottom with `contentOffset.x` clean **AND the content unit's measured minX clean** (the offset probe reads 0 while the content draws displaced — only the layer probe sees the entry seek's center-x shimmy), then fades in over 120ms. The timeout is a 2500ms failsafe, not the common path: at 700ms a 400-message load regularly outlasted it and revealed mid-shimmy — the "loads in middle, shifts left, middle, left" report.
- **Staged backfill**: the instant the geometry handler observes the viewport settled at the bottom (`needsBackfill && distance < 8`, not sending, not streaming, not user-positioned), `startHistoryBackfill()` walks `mountedFromIndex` down to 0 in 40-row batches, one 80ms beat apart, with the entry anchor attached (`entryAnchorActive`, a single stable Bool — a composite gate expression killed the anchor mid-walk when subterms crossed). Each prepend lands above the anchor-pinned viewport, invisible (log-verified lockstep: dOff == dContent on every batch at 420 messages). The settled-at-bottom gate is load-bearing: it is the one geometry in which the anchor's position-preservation is verified.
- **Sticky drop**: the entry seek's held position is dropped (binding replaced) on the first settled-at-bottom observation — same tick the backfill starts, NOT deferred to backfill completion. Deferring left the center-x edge position live through the walk and the batches re-poisoned the margins (v21: 34/60 burst frames collapsed; now one 1-tick transient per entry, covered by the curtain).
- **Send = measured one-shot jump + shrinking runway**: history stays mounted. The send arms `pinJumpPending`, lays a full-viewport runway (`streamRunwayBudget`), and the geometry handler fires ONE absolute `scrollTo(y: offset + reportedMinY − 20)` once the pending row's position report arrives AND the runway is present in the measured contentHeight (firing against pre-runway metrics clamps the jump short). The −20 covers the top content inset `.scrollView` space ignores. The runway's rendered spacer is budget − (measured streaming height) with its width pinned exactly like every message row, so question + reply + spacer is constant — the reply fills the visible gap in place with zero offset movement. **The jump's position is RELEASED one tick later** (`pinDropTarget`, binding replaced once the offset arrives): even an absolute position held through a stream re-solves x against every coalesced re-lay, shimmying the transcript ±16pt at flush cadence (probe-verified: 57 X-DRIFT events per stream held vs 1 released — the "jitters left and right" report), and held past terminal it parks the margin shift permanently. User grab cancels the armed jump; the pill ends the pin contract (reclaims the runway, seeks the true bottom).
- **Terminal**: nothing positional. The runway is reclaimed (below the fold, can't move the frame); the id-stable streaming→settled swap happens under a numerically frozen offset. A reply shorter than the runway leaves the viewport past the new end and the past-bottom clamp settles it — the clamp is an absolute `scrollTo(y: contentHeight − viewportHeight)` from measured values, never an id/edge solve.
- **Disengage**: user-driven motion is detected *only* via `scrollPosition.isPositionedByUser` in the geometry handler. Scroll phases misfire on system motion (clamp bounces report `.decelerating` with no touch); a simultaneous `DragGesture` blocks the pan entirely on iOS 26.
- **Past-bottom clamp**: idle, not user-positioned, runway reclaimed, **entry settled and not backfilling**, `distance < -1` → one non-animated absolute `scrollTo(y: contentHeight − viewportHeight)`. The absolute target is only as good as the metrics: fired mid-walk during an estimate collapse (content 750k→3k logged) it wrote a garbage offset that stranded entry mid-conversation once the estimate re-inflated — entry transients belong to the seek + anchor, the clamp only runs on honest post-settle metrics. One-shot per tick, never armed as a loop — arming it fed the convergence storm. The sticky-drop's settled check is a BAND (−8 < distance < 8) for the same reason: a one-sided `< 8` passes past-end transients and drops the entry seek exactly when it is needed.
- **Pill + bottom-seek convergence**: the pill (TOP-anchored overlay, explicit user preference, 8pt top padding) arms `seekingBottom` — a dedicated flag, NOT shared with any follow state (the shared-flag version raced the user-scroll disengage; "pill does nothing") — and seeks bottom non-animated. While armed, the geometry handler re-seeks whenever `distance > 64` and idle, until arrival (`distance < 8`) or user grab. Convergence is safe here because the target is static (no stream appends race it; streaming during a pill seek converges to the live edge and then goes inert at the next settle).
- **Width containment, three layers**: the padded stack keeps its `maxWidth` cap with `.leading` alignment (an *exact* width was tried and centers its content when a narrower proposal arrives — a 16pt left shift at rest); every ROW gets an exact `.frame(width: paneWidth - 32, alignment: .leading)` pin so a transition pass can't widen any row; and genuinely wide blocks (fenced code, tables) live inside their own horizontal scrollers in the markdown theme.

## Stream rendering cost (PsmithKit)

`StreamHub` coalesces prose deltas before they touch the observable stream state (`clients/PsmithSwift/Sources/PsmithKit/StreamSubscriber/StreamHub.swift`): text/thinking deltas buffer per conversation and flush at most every 100ms; structural chunks (tool use, elicitation, thinking transitions), terminal handling, and subscription teardown flush first so ordering is preserved; `clear()`/`reset()` discard. Every `streams[...]` write invalidates every observer — the streaming row re-parses its whole markdown, the transcript re-lays — so at wire rates of 20–50 deltas/s the app paid a full render pipeline per delta, quadratic in reply length for the parse alone. Coalescing cut render passes to ≤10Hz. The suspension path flushes rather than discards (resume-from-`lastSequence` correctness: unflushed chunks would replay-duplicate).

## Failure taxonomy

Reproduced 2026-07-16 (original taxonomy) and 2026-07-18 (heavy-scale additions):

| Symptom | Mechanism | Countermeasure |
|---|---|---|
| Viewport lands/strands far past the content end | bottom-seek or edge re-solve against inflated estimates | tail-window entry; staged backfill; past-bottom clamp |
| Margins collapse during generation | wide-block row re-laid at ideal width during send relayout | exact width pin; per-block horizontal scrollers |
| Margins collapse when keyboard opens, until next touch | keyboard transition re-lays stack wider; static content never invalidates | exact width pin |
| Margins collapse through entry/backfill | sticky edge position held through the walk re-solves center-x per batch | drop the sticky at first settle, same tick backfill starts |
| Send pin lands mid-viewport or not at all | id-solve of the question against 1.3M pt of estimates | one absolute scroll from the row's MEASURED position |
| History "deleted" during/after a send | window-collapse design unmounted it; post-terminal remount stranded the viewport | history stays mounted; runway + measured jump instead |
| Pin jump lands short | clamped against a contentHeight that predates the runway's layout | fire only when offset+minY ≤ measured max |
| Viewport yanked at the pending→real row swap | held absolute position past max-scroll (under-sized runway) | full-viewport runway; never write past measured max |
| Transcript shimmies ±16pt at flush cadence while streaming | ANY held position — even absolute — re-solves x per coalesced re-lay | release the jump's position one tick after it lands |
| Left margin parked 16pt after a long reply | position held past terminal (settled-drop gate never fires at question-top) | same release; nothing is held after the jump tick |
| Question walks off the top during stream | any bottom-tracking mechanism (anchor, convergence) follows appends | positionless motionless viewport; no follow |
| Main thread 100%, UI frozen during stream | convergence loop ↔ LazyVStack re-estimator feedback | convergence only against static targets; clamp one-shot |
| Pill "does nothing" from deep scroll | seek lands short (estimates) + disengage race killed the retry | dedicated `seekingBottom` flag + convergence loop |
| Whole-viewport rewind mid-stream | replacing the ScrollPosition binding while streaming | binding replacement only at rest / on user grab |
| "Stream never arrived" (false alarm) | coalesced flushes under the 120pt lurch-log threshold; observation stopped before the terminal | know the log thresholds; check `stream_runs` server-side first |

## Repro harness

Everything lives on the scratch server + fake LLM; no provider spend.

```
docker exec clark-postgres psql -U clark -d clark -c "CREATE DATABASE scrollverify"
GOOSE_DBSTRING="postgres://clark:clark@localhost:5433/scrollverify?sslmode=disable" make migrate-up
PSMITH_DSN="postgres://clark:clark@localhost:5433/scrollverify?sslmode=disable" \
  PSMITH_ADDR=127.0.0.1:18080 \
  PSMITH_BOOTSTRAP_ADMIN_USERNAME=admin PSMITH_BOOTSTRAP_ADMIN_PASSWORD=admin-password-not-secret \
  go run ./cmd/psmithd &
go run ./cmd/demo-seed -addr http://127.0.0.1:18080 -u admin -p admin-password-not-secret \
  -chunk-delay 50ms -xl 110 -heavy 200 -keep
```

`demo-seed`'s fake LLM answers by prompt keyword: `count` streams numbered words (`w000 …`, one word per chunk — viewport position readable off any frame), `wide` streams the margin stressors (unbreakable token, wide code fence, wide table), `bullet` streams list-item shapes, `essay` streams a long multi-section response, `heavy`/`filler` stream 800-word bulk. `-xl N` seeds a long conversation with N turns; `-heavy N` seeds N × 800-word turns (the jank-at-scale reference conversation).

Capture during generation — screenshots after the fact cannot see these bugs:

- **Video**: `xcrun simctl io booted recordVideo --codec h264 /tmp/run.mov` (SIGINT to stop), frames extracted at 3fps via `AVAssetImageGenerator` (no ffmpeg needed; script pattern in the session notes).
- **Margin scanner**: sample the left strip of the transcript band per frame; dark pixels = collapsed margin (`min_edge.swift`: healthy ≈ 16–17pt, broken ≈ 0–1pt).
- **Breadcrumbs**: `xcrun simctl spawn booted log stream --predicate 'subsystem == "dev.jdpedrie.psmith"' --style compact`. The geometry handler logs `JUMP` (offset discontinuity with full state), `CONTENT-LURCH` (>120pt only), `PAST-END`, `WIDTH-BREAKOUT`, `X-DRIFT`, plus send/backfill/seek transitions. `log stream` drops lines under layout-storm load — absence of a breadcrumb is weak evidence; the server's `stream_runs` table is the authority on whether a run happened.
- **Software keyboard ON** (Cmd+Shift+K in Simulator): hardware-keyboard mode never resizes the viewport and hides the entire keyboard-transition bug class.
- **`sample <pid> 2`** when the UI freezes: 100% in `AG::Graph::UpdateStack::update` = a state-write ↔ relayout feedback loop, almost always a scroll command issued per geometry tick.

Known probe limitation: the keyboard-show margin collapse does *not* move `contentSize` or `contentOffset.x` — the stack overflows its reported frame. Pixels (the scanner) are the authority on margin health; the log probes cover everything else.

## Mac status

`clients/psmithd-mac/PsmithMac/ConversationView.swift` still runs the pre-v7 design and has all four original failure classes: animated `scrollTo` per streaming chunk (100ms throttle), `scrollTo(last, anchor: .top)` on message-count change (fires at terminal), phase-based user detection, and no width pin. Port this architecture when Mac scroll work resumes — the window-collapse send pin and the StreamHub coalescing (shared PsmithKit, already live for Mac too) transfer directly; the shared markdown theme (code/table scrollers) is already in place. Tracked in [docs/todo.md](../todo.md).
