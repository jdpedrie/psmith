# Chat scroll architecture

The conversation transcript is the hardest view in the app. This doc records how the iOS scroll machinery works, the failure taxonomy behind months of "scroll jumps during generation" reports, and the repro harness that finally made the transients observable. Read this before touching `ConversationView.swift` scroll code on either platform. The Mac ConversationView has NOT received this architecture yet (see "Mac status" below).

## The one governing principle

Every visible scroll bug in this view's history came from the same physics: **LazyVStack's content size is an estimate wherever rows aren't realized, and any scroll command solved against an estimate lands wrong when the estimate refines.** The refinement happens in a *different layout pass* than the command, so the viewport visibly moves once (wrong target), then again (correction). On a fast simulator both passes land inside one frame and nothing is visible. On a device they straddle visible frames: the user sees the jump, then the snap-back.

The corollaries:

1. The **system bottom anchor** (`defaultScrollAnchor(UnitPoint(x: 0, y: 1), for: .sizeChanges)`) solves *inside* the layout pass, in lockstep with realization. Offset and content height move together; nothing is visible. It is the only primitive allowed to track the stream.
2. Explicit `scrollTo` commands are allowed only where the surrounding content is realized (cold-entry seek over the 12-row tail, park pin on an on-screen row) or as an idempotent clamp.
3. **The solver owns x too, and any held position drifts the transcript.** `Edge.bottom` and `.top` are center-x anchors (`UnitPoint(x: 0.5, …)`); every sticky-position re-pin re-solves BOTH axes against the solver's own (estimated, transiently oversized) content width, parking the content 16pt left — the "margins shifted left" bug, persisting on static content because nothing re-solves it back. UIKit-level probing proved the backing UIScrollView never sees it (offset 0, insets 0, container clean): it is SwiftUI-internal placement, so no UIKit clamp can fix it. The cure is that **no position stays held while following**: the geometry handler drops any live explicit position (replaces the binding with a fresh `ScrollPosition()`) the first time it observes settled-at-bottom-while-following. Positions exist only transiently — entry seek, past-bottom clamp, pill seek — plus park pins, which are exempt (follow is off while parked) and carry leading-x anchors (`UnitPoint(x: 0, y: 0)`). The at-settle binding replacement does NOT trigger the one-viewport rewind seen when replacing mid-stream (verified at rest after a pill seek).
4. Whatever cannot be prevented must be **observable**: the geometry handler logs offset discontinuities, past-end excursions, width breakouts, and horizontal drift at notice level (`subsystem dev.jdpedrie.psmith`, category `ChatScroll`), so a device repro is diagnosable from `log collect` after the fact.

## Mechanics (iOS, current)

State lives on `ConversationBody` (`clients/psmithd-ios/PsmithiOS/Chats/ConversationView.swift`):

- **Cold entry**: mount only the newest `coldEntryTail` (12) rows, seek `scrollTo(edge: .bottom)` in `onAppear`. Twelve rows realize fully in one pass, so the content size is exact and the seek lands true. Handing LazyVStack 200+ rows in one shot instead accumulates all its estimate error as phantom blank space *below* the last message (device-confirmed: ~5 screens of desert).
- **Entry curtain**: the transcript renders at opacity 0 (layout fully live) until the geometry handler first observes the viewport settled at the bottom **with `contentOffset.x` clean**, then fades in over 120ms; a 700ms timeout reveals regardless. Even the 12-row tail runs an estimate oscillation while realizing (logged 2196→42365→16228pt on a tall tail) that the entry seek chases across a few passes — sub-frame on a simulator, a visible settle-flash on device — and the entry seek's center-x re-solves can drift the content 16pt left before settle. Gating the reveal on both axes means entry cuts straight to a frame that is correct vertically AND horizontally (39/39 entry frames clean in the harness; revealing on y alone showed drifted margins for ~1s until the position machinery caught up, user-reported on device).
- **Staged backfill**: the instant the geometry handler observes the viewport settled at the bottom (`needsBackfill && autoFollow && distance < 8`), `startHistoryBackfill()` walks `mountedFromIndex` down to 0 in 40-row batches, one 80ms beat apart. Each prepend lands above the anchor-pinned viewport, invisible. Batches, not one shot: the one-shot variant let the bottom edge re-solve against 200+ estimated rows at once, and when the realized tail was tall (long essays), the inflated estimate stranded the viewport **26,882pt past the content end** (log-verified on re-entry). Batching bounds the error any single re-solve can see to one batch. The window only ever grows (an index anchor, so appends never unmount old rows); it never re-trims — the v5.1 trim/re-expand design caused visible history unloads and terminal stranding.
- **Follow**: `autoFollow` engages on send and stream start. The bottom anchor is attached only while following (`defaultScrollAnchor(autoFollow ? .bottom : nil, for: .sizeChanges)`).
- **Send**: sets `autoFollow = true` and issues *no bottom-edge seek*. The pending row's insertion is a size change; the anchor pins the bottom in-layout. The explicit edge seek this replaced solved against pre-layout estimates and produced a ±763pt offset flicker at every send (log-verified; ±70pt lockstep after). If a pill/clamp seek happens to have left a live position, send and stream-start re-target it to `__pending__` / `__streaming__` so it can't hold the viewport against the anchor — normally there is no live position and the anchor alone follows.
- **Park**: while streaming, the just-sent user message's top edge is watched via preference. When it comes within 24pt of the viewport top, `disengageFollow()` pins that message id at top-leading — the question stays visible while the answer writes below. The pin fires *early* (24pt) because the preference emits at chunk cadence; a crossing check always overshot and the pin then yanked content backwards. A second pass 250ms later re-solves the pin exactly (the first solve can land off when tall rows nearby aren't realized). The park releases the instant the user takes the viewport (`isPositionedByUser`).
- **Disengage**: user-driven motion is detected *only* via `scrollPosition.isPositionedByUser` in the geometry handler. Scroll phases misfire on system motion (clamp bounces report `.decelerating` with no touch); a simultaneous `DragGesture` blocks the pan entirely on iOS 26.
- **Past-bottom clamp**: when following, idle, and not user-positioned, `distance < -1` re-pins the bottom without animation. Covers container growth (keyboard dismissal), which the sizeChanges anchor ignores by design.
- **Bottom-seek convergence**: the clamp's mirror, for landing SHORT. When following, idle, settled past entry, and `distance > 64`, re-seek the bottom without animation. Any seek issued from far above (the pill, a send while scrolled up) solves against estimated coordinates and can land thousands of points shy at heavy scale (log-verified: 3,316pt short at 1.17M points of content); each convergence pass realizes rows near the landing zone and refines the solve until the bottom is reached. At that scale this loop also carries the live follow — the system anchor chronically under-solves by ~80pt and convergence steps it forward — so follow reads as a fast crawl rather than glued, which is the accepted trade.
- **Terminal**: nothing positional happens. The messages array is replaced id-stable, the streaming row settles into the real row of the same content, and either the sticky bottom edge (following) or the park re-assert (parked, immediate + 300ms) holds the viewport.
- **Width containment, three layers**: the padded stack keeps its `maxWidth` cap (an *exact* width was tried and centers its content when a narrower proposal arrives — a 16pt left shift at rest); every ROW gets an exact `.frame(width: paneWidth - 32, alignment: .leading)` pin so a transition pass (keyboard show, send relayout — both video-verified re-laying single realized rows at ideal width) can't widen any row; and genuinely wide blocks (fenced code, tables) live inside their own horizontal scrollers in the `.clarkChat` markdown theme, so no block ever needs more than a row's width. What the pins can't stop — the position solver's center-x drift against width *estimates* — is handled by the leading-x anchor rule above.
- **Scroll-to-bottom pill**: TOP-anchored overlay, per explicit user preference (it floats over the parked message when one is pinned there; accepted trade). Tap = follow on + a non-animated bottom seek; the convergence clamp finishes the job when the estimate-solved target lands short. Always mounted, opacity/hit-test gated.

## Failure taxonomy (all reproduced, 2026-07-16)

| Symptom | Mechanism | Countermeasure |
|---|---|---|
| Viewport lands/strands far past the content end | bottom-seek or edge re-solve against inflated estimates | tail-window entry; staged backfill; past-bottom clamp |
| Offset flicker at send ("jumps halfway up, snaps back") | explicit seek in one pass, estimate refinement in the next | no explicit send seek; anchor-only tracking |
| Margins collapse during generation | wide-block row re-laid at ideal width during send relayout | exact width pin; per-block horizontal scrollers |
| Margins collapse when keyboard opens, until next touch | keyboard transition re-lays stack wider; static content never invalidates | exact width pin |
| Park lands off, corrects visibly | id-solve against estimates; preference cadence overshoot | early (24pt) park; realized-neighborhood two-pass pin |
| Viewport yanked at stream end while parked | terminal content swap re-fires scroll position | parked re-assert, immediate + 300ms |

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
  -chunk-delay 50ms -xl 110 -keep
```

`demo-seed`'s fake LLM answers by prompt keyword: `count` streams numbered words (`w000 …`, one word per chunk — viewport position readable off any frame), `wide` streams the margin stressors (unbreakable token, wide code fence, wide table), `essay` streams a long multi-section response (exercises follow-then-park), `filler` streams fast (bulk seeding). `-xl N` seeds a long conversation with N turns.

Capture during generation — screenshots after the fact cannot see these bugs:

- **Video**: `xcrun simctl io booted recordVideo --codec h264 /tmp/run.mov` (SIGINT to stop), frames extracted at 3fps via `AVAssetImageGenerator` (no ffmpeg needed; script pattern in the session notes).
- **Margin scanner**: sample the left 8px strip of the transcript band per frame; dark pixels = collapsed margin. Finds the exact onset frame across a thousand frames in seconds.
- **Breadcrumbs**: `xcrun simctl spawn booted log stream --predicate 'subsystem == "dev.jdpedrie.psmith"' --style compact`. The geometry handler logs `JUMP` (offset discontinuity with full state), `CONTENT-LURCH`, `PAST-END`, `WIDTH-BREAKOUT`, `X-DRIFT`, plus follow/park/backfill transitions.
- **Software keyboard ON** (Cmd+Shift+K in Simulator): hardware-keyboard mode never resizes the viewport and hides the entire keyboard-transition bug class.

Known probe limitation: the keyboard-show margin collapse does *not* move `contentSize` or `contentOffset.x` — the stack overflows its reported frame. Pixels (the scanner) are the authority on margin health; the log probes cover everything else.

## Mac status

`clients/psmithd-mac/PsmithMac/ConversationView.swift` still runs the pre-v7 design and has all four failure classes: animated `scrollTo` per streaming chunk (100ms throttle), `scrollTo(last, anchor: .top)` on message-count change (fires at terminal), phase-based user detection, and no width pin. Port this architecture when Mac scroll work resumes; the shared markdown theme (code/table scrollers) is already in place. Tracked in [docs/todo.md](../todo.md).
