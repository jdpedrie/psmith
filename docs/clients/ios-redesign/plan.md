# iOS redesign: build plan

The iOS app is being rebuilt to the "Psmith iOS redesign" canvas
(https://claude.ai/artifact/FEjKhDx8cccSKBCNCRgHVJ). The canvas is the spec. It
has 76 dark boards, a light variant of each (pages prefixed "Light:"), a Themes
board with every theme in both appearances, and a Tokens and parts board. When a
board turns out wrong, we fix the board first and then the code. We don't
improvise in Swift.

## Rules carried over from the Mac rebuild

- Pixel conformance to the boards, checked by rendering the real views and
  diffing against board renders. Anything within half a point counts as a match.
- Every screen at four widths: 375 (SE), 390 (the boards' width), 402 (17 Pro),
  440 (Pro Max). It's also checked in light and dark, and under all six themes.
- No alerts, action sheets, popovers or modal sheets. Confirms happen in place.
  Things that replace the composer (review, compress, archived, elicitation) sit in
  the composer's slot. Detail opens as a pushed page.
- Liquid Glass on everything that floats. Titles never sit on glass over text.
- No tab bar. Settings is a pushed page, reached from the account menu.

## Tokens

These are defined on the Themes board. A theme supplies `accent`, `chrome` and
`highlight` for light and dark (PsmithUI `Theme.swift`). Everything else
derives:

| Token | Dark | Light |
|---|---|---|
| well (list ground) | chrome + 24% black | chrome + 50% white |
| bubble | chrome mixed with accent 24% | chrome mixed with accent 16% |
| accent ink | accent + 45% white | accent |
| glass | chrome + 10% white, 55% opacity, blurred | white 62%, blurred |
| settings ground / group | #1B2027 / #20262E | #F2F2F7 / #FFFFFF |
| text / secondary / tertiary | #E6EAEE / #9AA6B2 / #7F8B97 | #17202A / #525E6A / #5C6773 |
| red / orange / green | #F08A80 / #F2A65A / #7FD3A2 | #BF3A2F / #A85808 / #237A4B |

## Decisions from review (2026-11-07)

These ship as drawn, even though they change today's behavior:

- **Remove account:** the Accounts page gets an in-place Remove.
- **Archived chip:** an Archived filter chip in the list replaces the separate archived screen.
- **Explicit save bars:** plugin settings and conversation call settings get Save / Revert instead of autosave.
- **Turning off inherited plugins:** a profile can switch off a plugin it inherits.
- **Edit on summary review:** Edit is a button on the summary review card.

## Harness

- An iOS snapshot test target, `PsmithiOSSnapshotTests` in `project.yml`, hosted
  in the app. It uses swift-snapshot-testing and renders views at the four
  widths × light/dark.
- A board probe in the same target mounts each screen with the boards' fixture
  content and writes PNGs. A script compares them with the board renders.
- Event tests drive real gestures for the interactive pieces (swipe, long-press,
  composer, confirm-in-place), and each one is confirmed to fail against broken
  code.

## Phases

1. Shared kit: tokens, glass, nav row, groups and rows, confirm card, slot card,
   banners, pills, save bar.
2. Shell: sign in, launch, onboarding, account menu, the list and its states,
   and the new-conversation draft.
3. Conversation: transcript, message states, composer and tray, slots, info
   page, models page, call settings, full text, image page.
4. Settings: every page on the Settings boards.
5. Conformance sweep: every board at every width, in both appearances and under
   every theme.
6. Tests, docs (`ios-reference.md`, inventories) and `docs/todo.md`.

## Board corrections made while building

These are recorded so nobody "restores" the old drawing:

- **List rows:** the second line shows the profile, not a last-message snippet.
  Conversations carry no message preview. Draft text, queued text and
  "Replying…" stay, because those exist.
- **List header:** gains a sort control (Recently Used / Recently Created). It
  replaces the old filter menu, so the feature isn't lost.
- **Chips:** the chip row always includes Archived, after All.
- **Navigation rows:** every row uses the system bar's geometry (44pt tall at
  y 59, 16pt sides), because pushed pages use the native iOS 26 bar.
- **Second pass:** about 25 more corrections came out of building. Examples:
  the composer chip shows the model's full name; one rule now decides which
  reply shows its action row; Council uses the theme's persona colors; Discover
  drops knowledge-cutoff dates the data doesn't have; the profile page drops a
  color picker profiles don't have; Appearance lists themes in the app's order.
- **Selection:** under the System theme, selection uses the accent at 22%,
  because System's highlight is the solid accent (`Theme.selection`).

## Progress

Checked off as each phase lands with its tests.

- [x] 1 Shared kit
- [x] 2 Shell and list
- [x] 3 Conversation
- [x] 4 Settings
- [x] 5 Conformance sweep: 132 of 148 board/appearance pairs score at antialiasing level (5% or under) at 390. The rest are listed in `docs/todo.md` under "iOS redesign", each with its reason. Every theme renders in light and dark (`ThemeProbeTests`).
- [x] 6 Docs and todo
