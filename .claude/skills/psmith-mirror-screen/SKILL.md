---
name: psmith-mirror-screen
description: "Add an iOS surface that mirrors an existing Mac one in Psmith. Maps Mac UX patterns to their iOS equivalents and prefers extracting the view into PsmithUI so both platforms share it. Use when a feature exists on Mac and needs an iOS counterpart."
trigger: /psmith-mirror-screen
---

# /psmith-mirror-screen

Adds an iOS counterpart for a Mac surface, one screen at a time.

Note the direction of travel. iOS is the daily driver and Mac is the one
lagging, so this skill is often run in reverse: check
[`docs/clients/ios-reference.md`](../../../docs/clients/ios-reference.md)
before assuming Mac is ahead. When it is the Mac side that needs building, the
same extraction path applies with the platforms swapped.

## Usage

```
/psmith-mirror-screen <view-name>
```

E.g. `/psmith-mirror-screen ProvidersView`.

## Pre-flight

1. **Read [`docs/clients/ios-reference.md`](../../../docs/clients/ios-reference.md)** for how the screen fits the iOS app: PsmithKit and PsmithUI layering, the stream hub, repositories, view models, the offline queue, device-tool dispatch. (The old `docs/ios-screens.md` and `docs/ios-plan.md` are gone; their content lives here now, reorganized.)
2. **Check whether the view is already in `clients/PsmithSwift/Sources/PsmithUI/Composite/`.** If yes, the iOS side is `import PsmithUI` plus thin binding. If no, decide between extracting first (preferred, below) and writing a parallel view against the same view models.
3. **Check the PsmithKit ViewModel.** The iOS view uses the same `@Observable` the Mac uses. If it is missing an iOS-relevant method, add it to PsmithKit first, with a test.
4. **If the screen scrolls a transcript**, read [`docs/clients/chat-scroll.md`](../../../docs/clients/chat-scroll.md) before touching anything. The scroll architecture is inverted (`scaleEffect(y: -1)` on the scroll view plus a per-row flip) and load-bearing; that doc records the estimate-error physics behind every historical scroll bug.

## Extract first (preferred)

If the Mac view has no AppKit-specific parts, hoist it to PsmithUI in its own
commit:

1. Move `clients/psmithd-mac/PsmithMac/X.swift` → `clients/PsmithSwift/Sources/PsmithUI/Composite/X.swift`.
2. Replace `NSColor` / `NSImage` / AppKit calls with `#if canImport(AppKit) … #else … #endif` branches falling through to the shared `Theme` and `ProviderLogo` helpers.
3. Update Mac call sites with `import PsmithUI`.
4. `make swift-test-l2`. Snapshots verify Mac is unchanged. If anything diverges the extraction was not pure; back out and revisit.

Non-UI code belongs in PsmithSwift regardless. View models, repositories and
domain types live there so iOS can reuse them.

## Mac to iOS pattern map

| Mac pattern | iOS equivalent |
|---|---|
| NavigationSplitView (sidebar + detail) | NavigationStack(path:) push-pop drilldown |
| Popover | `.sheet(isPresented:)` with `.presentationDetents([.medium, .large])` |
| Hover affordances (`.onHover` reveals buttons) | Long-press. See the note below. |
| Right-click menu | Long-press, same path |
| Segmented Picker (4+ options) | `.menu` style Picker; segmented overflows on iPhone width |
| Multiple `.sheet(isPresented:)` on a parent | Attach each sheet to its trigger view, not the parent |
| Window resize handles | iPhone is fixed; iPad uses size-class detection |
| Keyboard accessory bar | Don't. `ToolbarItemGroup(placement: .keyboard)` orphans chrome above the dismissed keyboard |
| Page-replaces-pane (Compact, Contexts) | Half-height `.sheet` with detents |
| Dock icon menu | Account-avatar menu in `topBarLeading` |
| `.help("…")` tooltip | `.accessibilityHint("…")`; tooltips do not render on iOS |
| Cmd-shortcut Buttons | None on iOS. Swipe, long-press, or tap |

**Long-press on transcript rows is not `.contextMenu`.** `.contextMenu` builds a
lift portal that renders inverted rows upside-down, which is structural, not a
timing bug. Use `MessageActionMenu`
(`clients/psmithd-ios/PsmithiOS/Chats/MessageActionMenu.swift`), the custom
overlay built for exactly this. Elsewhere in the app `.contextMenu` is fine.

## Known platform traps

- **macOS SwiftUI `Menu` drops items silently.** Use direct Buttons for a single action and inline rows for a picker. Don't debug-spiral on it.
- **`.onHover` combined with `withAnimation` faults at runtime on macOS 26.** Strip the `withAnimation` wrapper.
- **No app-wide font scaling on macOS.** `.dynamicTypeSize` is a no-op for semantic fonts and `scaleEffect` breaks hit testing.
- **Title-bar overlay.** `fullSizeContentView` plus a transparent titlebar means detail panes need `.padding(.top, 28)`. The sidebar extends naturally. Not `toolbarBackground`.
- **Liquid Glass (macOS 26).** `.glassProminent` for primary actions, `.glass` for secondary, `.glassEffect(in:)` for chips, thinMaterial for footer and status bands.
- **Settings and routine flows stay inline.** No sheets or popovers for ordinary actions.

## Files

```
clients/psmithd-ios/PsmithiOS/<Section>/<Name>.swift
docs/clients/ios-reference.md          # update if the treatment differs from what's recorded
```

iOS-specific platform glue (haptics, notifications, deep links) goes under
`clients/psmithd-ios/PsmithiOS/Platform/`. Cross-platform glue belongs in
`clients/PsmithSwift/Sources/PsmithKit/Platform/` beside `Clipboard` and
`Notifier`.

## Tests

There is no iOS L2 snapshot harness yet; L2 covers Mac only
(`clients/psmithd-mac/Tests/PsmithMacSnapshotTests`). So iOS coverage is:

- PsmithKit L1 green for any ViewModel method the screen uses.
- Manual exercise via `make ios-app-run` against a real conversation. Golden path and one edge case (empty, error).
- A screenshot via `/psmith-screenshot-ios`, compared against the Mac equivalent.

If the view lands in PsmithUI, it gets Mac L2 coverage for free, which is
another reason to extract.

## Verification

```bash
make ios-build      # compile-only
make ios-app-run    # boot, install, launch
```

Then drive the screen end to end in the simulator.

## Don't

- Don't write iOS-specific copies of view models. Use the shared `@Observable`; Mac tolerates an unused method.
- Don't fork a shared view for an iOS tweak. Use `#if canImport(UIKit)` inside it.
- Don't reach for UIKit from a shared view. Go through `PsmithKit/Platform/` or add a platform-glue protocol.
- Don't use `.contextMenu` on transcript rows.
- Don't ship a screen that looks unconsidered. Design taste is graded the same as functionality here; vanilla SwiftUI with a sheet for everything reads as low effort.
