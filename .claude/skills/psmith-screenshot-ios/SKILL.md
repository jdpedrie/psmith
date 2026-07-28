---
name: psmith-screenshot-ios
description: "Capture iOS simulator screenshots for Psmith reliably, routing around the XcodeBuildMCP display-ID pitfall, plus the tap modalities and common screen flows. Use when you need to see or drive the iOS app's UI."
trigger: /psmith-screenshot-ios
---

# /psmith-screenshot-ios

Capture an iOS simulator screenshot reliably. The naive `XcodeBuildMCP
screenshot` call times out when its cached display ID does not match the booted
simulator; this routes around that.

## Usage

```
/psmith-screenshot-ios                                       # current sim state
/psmith-screenshot-ios --to docs/screenshots/<name>.png      # save somewhere specific
/psmith-screenshot-ios --drive "<navigation prose>"          # drive the UI, then capture
```

## The reliable capture

```bash
xcrun simctl io booted screenshot /tmp/<name>.png
```

Not `XcodeBuildMCP screenshot`. That tool caches a display ID at
session-defaults time, so when a different simulator gets booted behind your
back it fails with "Timeout waiting for screen surfaces". `simctl ... booted`
always resolves the actually-booted device.

Then `Read /tmp/<name>.png` to inspect, and copy it into
`docs/screenshots/<name>.png` only if it is a keeper.

## When booted sim and session defaults disagree

```bash
xcrun simctl list devices booted
```

Then `mcp__XcodeBuildMCP__session_set_defaults` with the real
`simulatorId`, or every `tap` returns "Cannot run accessibility commands
against <stale-udid> as it is not booted".

## Driving the UI

Three modalities, in order of preference:

1. **`mcp__XcodeBuildMCP__tap` with `label`.** Fastest when the AX label is unique. Run `snapshot_ui` first to see what is exposed.
2. **`tap` with `x`/`y`.** For elements absent from the AX tree, notably SwiftUI `Menu`s and the `topBarLeading` account avatar. Coordinates are the AX frame (402x874 on iPhone 17 Pro), not screenshot pixels.
3. **`mcp__computer-use__left_click` on the simulator window.** When AX coordinates do not line up, for deeper Menu chrome. Coordinates are screenshot pixels of the whole Mac display.

The account-menu avatar in `ChatsRoot` is a SwiftUI Menu and is not in the AX
tree. Tap it by AX coordinates (roughly 37, 85 on iPhone 17 Pro) or with a
computer-use click on the visible avatar.

Use `postDelay` on `tap` / `swipe` to inline a wait rather than polling.

## Scrolling

**Use computer-use drag, not `XcodeBuildMCP swipe`,** when exercising the
transcript. The scroll architecture is inverted and the synthetic swipe does not
reproduce real pan behavior. `docs/clients/chat-scroll.md` covers the repro
harness, including the seeded XL conversations in the local dev database.

## Common flows

| Goal | Sequence |
|---|---|
| Settings root | click avatar → `tap label="Settings"` |
| Providers list | Settings → `tap label="Providers"` |
| Provider detail | Providers → `tap label="<Provider name>, <driver>"` |
| Conversation | from the chats list, `tap label="<title>, <profile>"` |
| Toolbar menu | in a conversation, `tap` the ellipsis (top right) |
| Compact / Contexts / Settings sheets | toolbar menu → `tap label="<Compact\|Contexts\|Settings>"` |
| New conversation | `tap` the `+` (topBarTrailing) |
| Model picker | `tap` the model chip below the composer |
| Message action menu | long-press a transcript row (custom overlay, not `.contextMenu`) |

## Swipe-action rows

```
mcp__XcodeBuildMCP__swipe x1=300 y1=<row-y> x2=80 y2=<row-y> duration=0.3
```

Screenshot immediately. The row collapses if you wait or interact elsewhere.

## Where to save

- Debugging shots → `/tmp/`. Don't commit.
- Docs → `docs/screenshots/ios-<name>.png`.
- Snapshot baselines → `make swift-test-l2-record`, never a hand-placed PNG. (That harness is Mac-only; there is no iOS L2 yet.)

## Verify before keeping

`Read` the PNG and confirm it shows what you expect before moving it into
`docs/`. Simulator captures come back blank when the display surface is not
ready, partial when caught mid-transition, or showing a stale view when a sheet
was already dismissing.

## Privacy

Never use the real signed-in profile for screenshots that will be committed. It
carries private conversation data. Use the scratch account. On Mac, never sign
out an adopted real session: rebadge the bundle id and seed defaults instead (a
HOME jail does not work).

## Don't

- Don't use `XcodeBuildMCP screenshot` as the primary capture. `simctl ... booted` always works.
- Don't poll-wait between actions. Use `postDelay`.
- Don't screenshot before driving. The existing state is rarely what you want.
- Don't paste binary PNGs into the conversation. `Read` displays them inline.
