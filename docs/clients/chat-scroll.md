# Chat scroll architecture

The conversation transcript is the hardest view in the app. This doc records how the iOS scroll machinery works, the failure taxonomy behind months of "scroll jumps during generation" reports, and the repro harness that finally made the transients observable. Read this before touching `ConversationView.swift` scroll code on either platform. The Mac ConversationView has NOT received this architecture yet (see "Mac status" below).

## The one governing principle

Every visible scroll bug in this view's history came from the same physics: **LazyVStack's content size is an estimate wherever rows aren't realized, and any scroll command solved against an estimate lands wrong when the estimate refines.** The refinement happens in a *different layout pass* than the command, so the viewport visibly moves once (wrong target), then again (correction). On a fast simulator both passes land inside one frame and nothing is visible. On a device they straddle visible frames: the user sees the jump, then the snap-back.

The corollaries:

1. The **system bottom anchor** (`defaultScrollAnchor(UnitPoint(x: 0, y: 1), for: .sizeChanges)`) solves *inside* the layout pass, in lockstep with realization. Offset and content height move together; nothing is visible. It is the only primitive allowed to track the stream.
2. Explicit `scrollTo` commands are allowed only where the surrounding content is realized (cold-entry seek over the 12-row tail, park pin on an on-screen row) or as an idempotent clamp.
3. **The solver owns x too, and center-x anchors drift the transcript.** `Edge.bottom` and `.top` are center-x anchors (`UnitPoint(x: 0.5, …)`); every sticky-position re-pin re-solves BOTH axes against the solver's own (estimated, transiently oversized) content width, parking the content 16pt left — the "margins shifted left" bug, persisting on static content because nothing re-solves it back. UIKit-level probing proved the backing UIScrollView never sees it (offset 0, insets 0, container clean): it is SwiftUI-internal placement, so no UIKit clamp can fix it. Every position this view ever holds must therefore carry a **leading-x anchor** (`UnitPoint(x: 0, …)`). The one exception is the cold-entry edge seek (ids aren't trustworthy before the array is final); a polling task upgrades it to the id pin the moment load + backfill complete.
4. Whatever cannot be prevented must be **observable**: the geometry handler logs offset discontinuities, past-end excursions, width breakouts, and horizontal drift at notice level (`subsystem dev.jdpedrie.psmith`, category `ChatScroll`), so a device repro is diagnosable from `log collect` after the fact.

## Mechanics (iOS, current)

State lives on `ConversationBody` (`clients/psmithd-ios/PsmithiOS/Chats/ConversationView.swift`):

- **Cold entry**: mount only the newest `coldEntryTail` (12) rows, seek `scrollTo(edge: .bottom)` in `onAppear`. Twelve rows realize fully in one pass, so the content size is exact and the seek lands true. Handing LazyVStack 200+ rows in one shot instead accumulates all its estimate error as phantom blank space *below* the last message (device-confirmed: ~5 screens of desert).
- **Entry curtain**: the transcript renders at opacity 0 (layout fully live) until the geometry handler first observes the viewport settled at the bottom, then fades in over 120ms; a 700ms timeout reveals regardless. Even the 12-row tail runs an estimate oscillation while realizing (logged 2196→42365→16228pt on a tall tail) that the entry seek chases across a few passes — sub-frame on a simulator, a visible settle-flash on device. The curtain makes entry cut straight to the correct frame.
- **Staged backfill**: the instant the geometry handler observes the viewport settled at the bottom (`needsBackfill && autoFollow && distance < 8`), `startHistoryBackfill()` walks `mountedFromIndex` down to 0 in 40-row batches, one 80ms beat apart. Each prepend lands above the anchor-pinned viewport, invisible. Batches, not one shot: the one-shot variant let the bottom edge re-solve against 200+ estimated rows at once, and when the realized tail was tall (long essays), the inflated estimate stranded the viewport **26,882pt past the content end** (log-verified on re-entry). Batching bounds the error any single re-solve can see to one batch. The window only ever grows (an index anchor, so appends never unmount old rows); it never re-trims — the v5.1 trim/re-expand design caused visible history unloads and terminal stranding.
- **Follow**: `autoFollow` engages on send and stream start. The bottom anchor is attached only while following (`defaultScrollAnchor(autoFollow ? .bottom : nil, for: .sizeChanges)`).
- **Send**: sets `autoFollow = true`, re-targets the sticky pin to `__pending__`, and issues *no bottom-edge seek*. The pending row's insertion is a size change; the anchor pins the bottom in-layout. The explicit edge seek this replaced solved against pre-layout estimates and produced a ±763pt offset flicker at every send (log-verified; ±70pt lockstep after). Stream start hands the pin to `__streaming__`; a following (non-parked) terminal re-pins the settled last message 300ms after the reload.
- **Park**: while streaming, the just-sent user message's top edge is watched via preference. When it comes within 24pt of the viewport top, `disengageFollow()` pins that message id at top-leading — the question stays visible while the answer writes below. The pin fires *early* (24pt) because the preference emits at chunk cadence; a crossing check always overshot and the pin then yanked content backwards. A second pass 250ms later re-solves the pin exactly (the first solve can land off when tall rows nearby aren't realized). The park releases the instant the user takes the viewport (`isPositionedByUser`).
- **Disengage**: user-driven motion is detected *only* via `scrollPosition.isPositionedByUser` in the geometry handler. Scroll phases misfire on system motion (clamp bounces report `.decelerating` with no touch); a simultaneous `DragGesture` blocks the pan entirely on iOS 26.
- **Past-bottom clamp**: when following, idle, and not user-positioned, `distance < -1` re-pins the bottom without animation. Covers container growth (keyboard dismissal), which the sizeChanges anchor ignores by design.
- **Terminal**: nothing positional happens. The messages array is replaced id-stable, the streaming row settles into the real row of the same content, and either the sticky bottom edge (following) or the park re-assert (parked, immediate + 300ms) holds the viewport.
- **Width containment, three layers**: the padded stack keeps its `maxWidth` cap (an *exact* width was tried and centers its content when a narrower proposal arrives — a 16pt left shift at rest); every ROW gets an exact `.frame(width: paneWidth - 32, alignment: .leading)` pin so a transition pass (keyboard show, send relayout — both video-verified re-laying single realized rows at ideal width) can't widen any row; and genuinely wide blocks (fenced code, tables) live inside their own horizontal scrollers in the `.clarkChat` markdown theme, so no block ever needs more than a row's width. What the pins can't stop — the position solver's center-x drift against width *estimates* — is handled by the leading-x anchor rule above.
- **Scroll-to-bottom pill**: bottom-anchored overlay (it used to sit at `.top`, directly on top of the parked message). Always mounted, opacity/hit-test gated.

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
