# Web redesign: build plan

The web client is being rebuilt to the "Psmith web design" canvas
(https://claude.ai/artifact/52eZinPifiLRUCxsdMCJAt). The canvas is the spec. When
a board turns out wrong, we fix the board first and then the code. The rules
match the [iOS rebuild](../ios-redesign/plan.md): pixel conformance, both
appearances, every theme, no modals.

## What the web client is

Server-rendered HTML from `psmithd` (templ + htmx), described in
[web.md](../web.md). Every screen works as plain HTML: forms post, links
navigate. htmx swaps fragments and streams replies over SSE. A small script adds
keyboard shortcuts, search-as-command, the composer's autosize and scroll
following. Nothing on a board may need a client-side app to exist.

## Rules

- Pixel conformance to the boards at 1440×900, checked by rendering the real
  templates with board fixtures and diffing against board renders. Phone boards
  at 390×844.
- One responsive layout. The list, conversation and inspector sit side by side
  on a desktop; the inspector drops below 1180px and becomes a page; the list
  folds behind a menu button below 760px.
- Light and dark, following the system or a per-browser choice. Six themes.
- No modal dialogs, lightboxes or `confirm()`. Destructive confirms happen in
  place. Small anchored menus are allowed where a native app shows a context
  menu.
- Detail opens in the inspector column or as its own page with its own URL.
- Keyboard first. `/` searches and runs commands.

## Tokens

A theme supplies `accent`, `chrome` and `highlight` for light and dark (the same
values as PsmithUI `Theme.swift`). Everything else derives in CSS with
`color-mix()`, using the same rules as iOS:

| Token | Dark | Light |
|---|---|---|
| well (list ground) | chrome + 24% black | chrome + 50% white |
| panel (inspector) | chrome + 12% black | chrome + 25% white |
| raise (composer, menus) | chrome + 5% white | white |
| code | chrome + 30% black | chrome + 70% white |
| bubble | chrome mixed with accent 24% | chrome mixed with accent 16% |
| accent ink | accent + 45% white | accent |
| hl (selection) | highlight (System: chrome + 22% accent) | same |
| settings ground / nav / group | #1B2027 / #171B21 / #20262E | #F2F2F7 / #EAEAF0 / #FFFFFF |
| text / strong / secondary / tertiary | #E6EAEE / #C9D2DB / #9AA6B2 / #7F8B97 | #17202A / #2E3A46 / #525E6A / #5C6773 |

The boards compute the same tokens in their script (`tokens()`), so any board
renders under any theme from its Tweaks panel. Inter is vendored in
`server/web/assets/fonts` so boards and pages render with the same font file.
The System theme uses #0A84FF / #007AFF and a neutral chrome (#1E1E1E / #ECECEC):
a browser can't read the platform accent.

## Gaps the redesign closes

The current web client lacks these server features. Each gets a board and an
implementation:

- Rename, generate title, search, select-many, pinned section.
- Branch navigation (`SetCurrentLeaf`), stop (`CancelStream`), reply failure and
  retry.
- Thinking, tool calls, usage, council personas, UI fragments, non-image
  attachments.
- Context gauge (`CountContextTokens`), the warning preference, contexts:
  activate, rename, delete.
- Plugin panels (`GetPluginPanel`, `InvokePluginAction`).
- Themes and appearance.
- Settings: General (warning, change password), Appearance, provider edit and
  defaults, model detail, favorites, manual models, global plugin settings,
  profile model slots, parent, default, export and import, Speech, Users (admin).
- First-run setup when an account has no provider.

## Harness

- `server/web/probe_test.go` renders every page template with board fixtures to
  HTML when `PSMITH_WEB_PROBE_OUT` is set. A WebKit script renders those and
  the boards to PNGs and scores them.
- Handler tests (httptest + pgtestdb) cover every route.
- Browser tests in headless Chrome cover streaming frame by frame and the
  keyboard: `/` search running a command, J and K, Esc, ⌘S.
- `TestMount_RoutesDontConflict` mounts every area's routes together.

## Board corrections made while building

Recorded so nobody restores the old drawing:

- **List meta line:** shows the filter's name ("All conversations",
  "Archived"), not a count. `ListConversations` returns no total.
- **Select many:** "Select all", not "Select all 27", for the same reason.
- **Reply actions:** every reply row is Copy, Regenerate, Edit, Delete, More.
- **Provider models table:** lists enabled models only. Turning one off
  disables it, which removes the row; there is no "off" row to draw.
- **Default profile:** one profile carries Default (`is_default`), not two.
- **Destructive page actions:** Remove and Delete live in a section at the
  bottom of the page and confirm in place. Reversible actions (Disable model)
  stay in the header.
- **Model picker:** opens in the inspector column everywhere, harness
  conversations included; no dropdown under the header button.
- **Theme cards:** each card carries its own `data-theme`, so its swatches
  show that theme's real accent, bubble and highlight.
- **Second pass, from building:** the phone list's search says "Search or run
  a command" (commands work there too); "Save and resend" shows only when
  editing a user turn; Langfuse and Speech keys are plain masks (the API says
  only whether a key is set); import warnings drop the server name (bundles
  don't record it) and renames read "Pirate tutor (2)"; the welcome message
  is "shown as the first reply" (it is sent to the model); the plugin panel
  drops copy only one plugin could supply; the elicitation card says "A tool
  needs input" (the stream doesn't carry the server's name); a new user's
  password starts empty; the Google template reads as the server returns it;
  the provider page links to its full call settings.
- **Third pass:** every reply keeps its action row, as Branches and the plan
  say, so Archived, Compress, CompressFailed and Elicit gain one on their
  first reply; Archived shows the list's read-only footnote, as ListArchived
  does. The embedder's dimensions are fixed at 768 (the vector column's
  size), so the page shows them as a value, not a field, and warns that
  saving a new model deletes the stored vectors and embeds everything again.

## Progress

- [x] 1 Boards: 80 screens, each with its light twin
- [x] 2 Foundation: tokens, themes, fonts, kit, shell
- [x] 3 List and shell screens
- [x] 4 Conversation and inspector
- [x] 5 Settings
- [x] 6 Conformance sweep at 1440 and 390, both appearances; Main under every theme. Columns shrink rather than wrap between 760 and 1180 (checked at 768 and 1024, which have no boards). What's left is in `docs/todo.md` under "Web redesign".
- [x] 7 Docs (`web.md`, `testing-plan.md`) and `docs/todo.md`
