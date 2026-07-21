# Chat scroll architecture

The conversation transcript is the hardest view in the app. This doc records how the iOS scroll machinery works — **since 2026-07-21, an inverted (bottom-anchored) list** — the failure taxonomy behind months of "scroll jumps during generation" reports, and the repro harness that made the transients observable. Read this before touching `ConversationView.swift` scroll code on either platform. The Mac ConversationView has NOT received this architecture yet (see "Mac status" below).

## The one governing principle

Every visible scroll bug in this view's history came from the same physics: **LazyVStack's content size is an estimate wherever rows aren't realized, and any scroll command solved against an estimate lands wrong when the estimate refines.** At ~400 heavy messages (1.3M points of content) that stopped being a tuning problem: id-solves landed thousands of points short, held positions oscillated against the re-estimator at 60Hz, convergence loops pinned the CPU. A year of machinery (tail windows, curtains, staged backfills, governors, measured jumps) existed to keep scroll targets away from estimated coordinates.

The inverted list ends the arms race by moving the one coordinate that matters to the exact end. The scroll view renders through `scaleEffect(y: -1)` with each row flipped back and the message array iterated newest-first, so **the newest message sits at content offset 0**. Zero is not an estimate. Estimate error still exists, but it lives entirely in the old-history direction, where nothing ever solves against it and a wrong guess only miscalibrates the scrollbar.

The refined principle, learned the hard way twice (see the send-pin section): **the only position that stays exact through a structural re-estimate is the rest edge (offset ~0).** A held NONZERO offset — even one established from exact coordinates — is garbage the moment LazyVStack re-maps its estimates (a head-insert at send re-shuffled ±40k pt under a frozen offset of 106 and parked the viewport mid-history for a whole stream). Programmatic positions are therefore one-shots with scheduled releases, never holds, and the steady states of the view are all rest-edge states.

## Mechanics (iOS, v13 inverted)

State lives on `ConversationBody` (`clients/psmithd-ios/PsmithiOS/Chats/ConversationView.swift`):

- **The flip**: `ScrollView { LazyVStack { spacer?, StreamingArea, PendingUserArea, ChatHistoryArea } }` — children newest-first, each row un-flipping itself via `chatRowFlip()` (`scaleEffect(x: 1, y: -1)`), the ScrollView flipped once at the end. Hit-testing passes through the transform; scrolling feels native. Indicators are hidden (they'd render mirrored). A `frame(minHeight: viewportHeight, alignment: .bottom)` on the stack keeps SHORT conversations reading from the visual top.
- **Cold entry**: nothing. A scroll view starts at offset 0, which is the newest edge. No seek, no anchor, no curtain, no failsafe, no mount window — LazyVStack realizes outward from the origin and older rows realize on scroll, so laziness finally points the same direction as the design. The deterministic entry parks (Scroll XL fresh-install, pop-back-from-Contexts) are impossible by construction — both re-verified green on this build.
- **Scroll-to-bottom pill**: ONE exact command, `scrollTo(x: 0, y: 0)`, via `oneShotScroll` (which schedules its own binding release at rest). The convergence loop, attempt caps, finisher, and the "parks blank from far away" limitation are gone. `isFarFromBottom` is simply `offset − spacerHeight > 200`.
- **Streaming = follow-then-park** (sixth design, user-specified UX). No scroll command at send and none during the stream. Follow: the viewport sits at the rest edge, where the inverted list's native physics glue it to the newest content — the question lands above the composer, the reply pours in below it, and the transcript slides up with zero machinery. Park: `streamClipBudget` (≈ one viewport, armed at STREAM START so the keyboard has dropped and the measurement is honest) caps the streaming row's rendered height (`frame(maxHeight:, alignment: .bottom).clipped()` — content-space bottom = the reply's first lines through the flips); the instant the reply fills the viewport, content stops growing and the rest-edge frame freezes with the reply's top at the viewport top, the tail accumulating behind the clip ("below the fold"). Detach: inherent — no anchors, no held positions, so any user scroll owns the viewport immediately and nothing re-asserts. If the user had scrolled away before sending, one exact catch-up `scrollTo(y: 0)` shows them their own message. The FIFTH design (instant question-at-top over a viewport-sized runway spacer) is gone: the spacer's head-insert was the largest structural churn in the system and the jump-to-blank read worse than the follow. The FOURTH (held id-anchor) died in one live test: the head-insert's estimate re-map moved the world under the frozen offset and the held id never re-solved.
- **Terminal**: release the clip (the settled row renders in full), then ONE exact id-solve — `scrollTo(id: <newest message>, anchor: UnitPoint(x: 0, y: 1))` after a 150ms layout beat — restores the parked frame: the reply's top at the viewport top, reading starts where the reply does. Short replies clamp to the rest edge, the same frame they streamed in. Skipped when the user owns the viewport; the position releases at rest 300ms later. The single-message terminal append (`GetMessage` + in-place append) is unchanged from the perf round. Mid-stream, the pill returns to the PARKED frame (the clip stays until terminal).
- **Top of context**: tapping the fade band at the visual top (and, where the platform delivers it, the status-bar tap via `StatusBarTapBridge` — a hidden 1pt scroll view that claims `scrollsToTop`, parks at offset 1 because a scroll view resting at its top never consults its delegate, and disables the gesture on every other scroll view while the conversation is up) jumps to the OLDEST message: `scrollTo(edge: .bottom)` in content space, an estimated far-coordinate solve that lands approximately and refines as rows realize — fine for a jump affordance, released after 400ms. The system gesture couldn't serve this anyway: its native semantics target offset 0, which inverted is the NEWEST edge.
- **Disengage**: unchanged — `scrollPosition.isPositionedByUser` only. Any live one-shot position is released the moment the user takes over (held positions are sticky and re-apply against drags).
- **Deletes**: in-place removal (unchanged); no shrink-settle needed — a delete near the newest edge shrinks content at the origin side and UIKit's native offset clamp covers it. There is no far-end estimate to strand the viewport against, so the past-bottom clamp is gone too.
- **Steady-state memoization**: `ChatHistoryArea`/`PendingUserArea` keep their `@MainActor Equatable` gates (ForEach re-diff cost at 447 rows is real regardless of flip direction) — now unconditional, since there is no entry machinery to exempt.
- **Safe areas and chrome**: automatic vertical insets apply in content space and would render swapped, so the scroll ignores them (`.ignoresSafeArea(.container, edges: .vertical)` + `.ignoresSafeArea(.keyboard)` — the composer owns keyboard avoidance by layout) and re-applies mirrored margins: `contentMargins(.bottom, safeTop + 8)` clears the nav bar at the content END (the oldest message, when fully scrolled back) and `contentMargins(.top, 8)` is the newest-to-composer gap. The iOS 26 scroll-edge fade computes its extent in TRANSFORMED coordinates (FB20540755, known regression with inverted scroll views) and washed the entire pane — it's hidden (`scrollEdgeEffectHidden`) and replaced by a hand-rolled screen-space gradient overlay at the visual top (`navClearance + 28` tall), which no transform can misplace. iOS 26 glass bars ignore `toolbarBackground`, so the overlay is the only thing keeping the title legible over passing content.
- **Context menus on flipped rows**: the system's automatic preview snapshot degenerates to a collapsed sliver on transformed rows. Every transcript context menu supplies an explicit `preview:` (rendered outside the transform, upright), using a raw `MarkdownBudget.head(…, limit: 600)` cut — NOT `BoundedMarkdownText`, whose "Show full text" affordance would render as a dead button inside the snapshot.
- **No pull-to-refresh on the transcript**: unchanged rationale — streams and events keep an open conversation live; refresh belongs to the chats list.
- **Width containment, three layers**: unchanged and still required (horizontal containment is orthogonal to the flip): the padded stack keeps its `maxWidth` cap with `.leading` alignment; every ROW gets an exact `.frame(width: paneWidth - 32, alignment: .leading)` pin; wide blocks (fenced code, tables) live inside their own horizontal scrollers in the markdown theme.
- **Observability**: the geometry handler still logs JUMP / CONTENT-LURCH / PAST-ORIGIN / WIDTH-BREAKOUT / X-DRIFT at notice level (category `ChatScroll`). CONTENT-LURCHes of ±40k are now EXPECTED and harmless during structural changes at heavy scale — the design's claim is that they can't move a rest-edge viewport, not that they don't happen.

What the inversion deleted outright: the cold-entry tail window and staged backfill, the entry curtain and its failsafes, the sizeChanges anchor, the sticky-drop band machinery, the auto-scroll governor and both its clients (pill convergence, past-bottom clamp), the measured send-pin jump and its position-report plumbing, and the shrink settle loop. What survives are the width pins, the memoization gates, the runway idea (now spelled spacer + clip), the one-shot-with-release discipline, and the telemetry.

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
| App locks at 100% CPU until killed (pill tap, delete) | per-tick scroll command ↔ estimate flap feedback, forever; each tick also re-diffed the full ForEach (closure params defeat SwiftUI memoization) | the governor (cooldown + attempt caps + finisher); Equatable subviews |
| Blank pane, zero rows in the AX tree, 0% CPU | viewport parked in a LazyVStack realization desert after a solve against a collapsed estimate; no ticks fire once stable, so nothing recovers | never leap across unrealized spans: capped window, on-demand mounts, settle loop off the metrics box |
| Estimate collapses geometrically under a mount walk | eager prepends with the viewport near the window TOP; short realized rows deflate the per-row average, which realizes more short rows | on-demand window; mounts only near-top DURING reading, one batch per trigger |
| Seek/sticky latched forever, acts on garbage later | arrival band (<8) narrower than the trigger band (>64) leaves 8..64 as a dead zone | one band constant for arm/disarm everywhere |
| Delete at bottom yanks or lurches the transcript | full `load()` replaced the whole messages array; ForEach re-diff + content shrink under a pinned offset | in-place removal for stitch deletes; count-shrink settle; cascade still reloads |
| Edit stalls the main thread on save | markdown cache keyed by server `editedAt` — the post-edit render always missed and parsed synchronously | content-hash cache keys + pre-warm from the edit sheet while the RPC is in flight |
| App hard-locks on ENTRY, chrome + bottom bar render but the transcript never does (reproduced 2026-07-21, 180KB pending summary) | one row hands MarkdownUI an unbounded document; the single layout pass builds the whole view tree and SwiftUI's `Update.enqueueAction` array copy goes quadratic — main thread never returns, so even the entry-curtain failsafe task can't run. Not a scroll-machinery bug: the governor can't help because no tick ever completes | `MarkdownBudget` (BoundedMarkdown.swift): head-preview + chunked LazyVStack viewer for settled rows, tail clamp for the live stream row. A single row must never be unbounded |
| One giant row makes the content estimate flap by thousands of points at tick rate | the tallest row in the cold-entry window dominates LazyVStack's per-row average; realize/unrealize swings the total estimate ±its height | keep transcript rows height-bounded (the summary card's preview budget is deliberately small: 1,500 chars) |
| (Inverted) viewport parks mid-history for a whole stream after send; held offset frozen while CONTENT-LURCH swings ±40k | inserting rows at the head makes LazyVStack re-map its estimates; a held nonzero offset — even id-anchored, even established from exact coordinates — points at different content afterward, and the held id never re-solved | the rest-edge send pin: never scroll at send; the runway + stream clip make offset ~0 the pinned frame for the entire stream |
| (Inverted) whole pane washed out / blurred on entry | iOS 26 scroll-edge fade computes its extent in transformed coordinates (FB20540755) — the nav fade paints upward from the visual bottom over everything | hide the scroll edge effect on the flipped scroll; hand-rolled screen-space gradient overlay supplies the under-bar fade |
| (Inverted) long-press context menu shows a collapsed sliver instead of the row | automatic preview snapshot degenerates on transformed rows | explicit `preview:` on every transcript context menu, rendered outside the transform |

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

Two harness traps that corrupted a day of A/B conclusions (2026-07-21):

- **Simulator scroll-wheel events bypass `isPositionedByUser`** (they log `user=false`), so wheel-driven repros exercise the SYSTEM-motion code paths, not the user-motion ones. Drags (`left_click_drag`) are the only faithful input for anything gated on user positioning.
- **The simulator's rendering degrades across many install/relaunch cycles**: after ~15 reinstalls, entry rendered blank on EVERY build including previously-verified-good code, and a plain `simctl shutdown`/`boot` restored it. Reboot the simulator before trusting any regression conclusion.

## Mac status

`clients/psmithd-mac/PsmithMac/ConversationView.swift` still runs the pre-v7 design and has all four original failure classes: animated `scrollTo` per streaming chunk (100ms throttle), `scrollTo(last, anchor: .top)` on message-count change (fires at terminal), phase-based user detection, and no width pin. Port this architecture when Mac scroll work resumes — the window-collapse send pin and the StreamHub coalescing (shared PsmithKit, already live for Mac too) transfer directly; the shared markdown theme (code/table scrollers) is already in place. Tracked in [docs/todo.md](../todo.md).
