# Psmith Mac: main window shell inventory

Scope: everything in the main (conversation) window except the Settings window and the transcript's message rows. Source of truth is the code as of commit `fc76aa6` plus the working tree. Paths are under `/Users/jdp/dev/psmith/clients/`.

Files read:
- `psmithd-mac/PsmithMac/PsmithMacApp.swift` (scene, AppDelegate, window chrome, menus)
- `psmithd-mac/PsmithMac/AppShell.swift`, `RootView.swift`, `LoginView.swift`
- `psmithd-mac/PsmithMac/HomeView.swift` (split view, account footer, list collapse)
- `psmithd-mac/PsmithMac/ConversationListView.swift` (list, search, filters, rows, sections)
- `psmithd-mac/PsmithMac/WelcomeView.swift`, `ConversationSheets.swift` (draft start grid, compress and model sheets, ProfileColor)
- `psmithd-mac/PsmithMac/ConversationView.swift` (detail toolbar, title, banners, composer bar, archived bar)
- `psmithd-mac/PsmithMac/ConversationInspector.swift` (header only), `ConversationModelPicker.swift`, `CompactView.swift`
- `psmithd-mac/PsmithMac/AppNavigation.swift` (Navigator), `MacNotifier.swift`, `DockIconSync.swift`
- `PsmithSwift/Sources/PsmithUI/Composite/Theme.swift`, `Toast.swift`, `LoadMoreFooter.swift`, `OnboardingView.swift`, `ElicitSheet.swift`, `AppPreferences.swift`
- `PsmithSwift/Sources/PsmithKit/ViewModels/ConversationsModel.swift`

---

## 0. Things a designer should know up front

1. **There is no command palette, no global search, no swipe actions, and no multi-select** in the main window. The list is single-selection (`List(selection: $convos.selectedID)` bound to one optional id). Search is title-only, server-side, inside the list column.
2. **"By Profile" grouping does not exist on Mac anymore.** `ConversationListMode.byProfile` exists in PsmithKit and three snapshot tests set it (`byProfileSingleProfileEmpty`, `byProfileSingleProfileMany`, `byProfileTwoProfiles`), but `ConversationListView` never reads `listMode` for grouping. The Mac replaced it with a client-side **Profile filter chip** (one profile at a time). Those snapshots render the date-grouped list.
3. **Toasts exist in PsmithUI (`Toast.swift`) but the Mac main window shows none.** Nothing in `psmithd-mac/PsmithMac` calls `.toast(...)`. All transient feedback is inline banners.
4. **Notification click does not select the conversation.** `MacNotifier` sets `navigator.pendingConversationSelection`, but no Mac view consumes it. Clicking a "reply ready" notification only activates the app. (Bug or gap worth knowing if the redesign draws that flow.)
5. `Navigator.mode` (`.chats` / `.settings`) is vestigial: Settings is its own window now. `startNewConversation()` still sets `mode = .chats`.
6. Theme tokens actually used in the shell: `accent`, `chrome`. `highlight` is not used anywhere in `psmithd-mac/PsmithMac` (row selection uses the system sidebar selection tinted by `theme.accent`). `bubbleTint` and `personaColors` are used by transcript rows in PsmithUI, not by shell chrome.

---

## 1. Theme tokens (PsmithUI `Theme.swift`)

Each theme carries `id`, `name`, `blurb`, `accent`, `bubbleTint`, `highlight`, `chrome`, `personaColors[5]`. All colors are dynamic light/dark. Semantic colors (orange warning, red error/delete, yellow star, green connected) are system colors and never themed. Persona sets deliberately contain no red, orange or yellow.

| Theme (id) | accent L / D | highlight L / D | chrome L / D |
|---|---|---|---|
| System (`system`) | `controlAccentColor` | same | `windowBackgroundColor` |
| Sage & Graphite (`sage`) | #2C7550 / #3EA36E | #CFE5D8 / #24402F | #E6F0E9 / #15241C |
| Clay & Ink (`clay`) | #B04A22 / #E46F3A | #F3D2BF / #4A2A1B | #F7EADC / #2B1C14 |
| Slate Pro (`slate`) | #2C65A0 / #4C96D9 | #CCDDF0 / #1F3550 | #E4ECF5 / #131D29 |
| Aubergine & Cream (`aubergine`) | #7A3A8C / #B87CCA | #E6D1EC / #3A2445 | #F4E9F2 / #22162A |
| Nordic Mist (`nordic`) | #1C6F8E / #299CC1 | #C8E4EF / #193A47 | #E2EEF4 / #12202A |

`bubbleTint` equals `accent` in every theme. Contrast floors (from code comment): accent as text on chrome at least 4.5:1, white on accent at least 3:1.

Derived surfaces used in the shell:
- **Window / title bar / detail background**: `theme.chrome` (also pushed to `NSWindow.backgroundColor`).
- **SidebarWell** (list column ground): `theme.chrome` overlaid with black at 3.5% (light) / 24% (dark). Used behind the list, its top header inset, and its bottom account footer.
- **TitleBand** (behind detail toolbar on the draft start screen): solid `theme.chrome` plus a 1pt hairline `primary @ 8%`.
- **User bubble** (`ThemedUserBubbleBackground`): chrome, then `bubbleTint @ 24%`, radius 10.
- `.tint(theme.accent)` is applied at the window root, so all `.glassProminent` buttons, links, checkmarks and selection highlight follow accent.

Theme change side effects: re-runs window configuration (title-bar fill) and swaps the Dock icon (`DockIconSync`: `AppIcon-Sage/Clay/Slate/Aubergine/Nordic.png`; System restores the bundle icon). Dock only; Finder keeps the bundle icon.

Text size: app-wide `fontScale` from `AppPreferences` (min 0.8, max 1.6, step 0.1, persisted). Every `.scaledFont(...)` call site scales; plain `.font(...)` call sites (several in the list rows, account footer, toolbar title) do not scale except through the root `\.font` default for unstyled text. Snapshot variants exist at 110% and 130% for the transcript.

---

## 2. App, window and menus (`PsmithMacApp.swift`)

### Scenes
1. `WindowGroup("")`: the main window. Root is `AppShell`.
2. `Settings { SettingsWindowRoot }`: separate window, `.windowResizability(.contentMinSize)`. When nobody is signed in it shows `ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.questionmark", description: "Sign in to a server to change its settings.")` at 480 x 320. (Settings content itself is out of scope.)

### Window geometry and chrome
- Default size first run: **1100 x 720**.
- Minimum: SwiftUI `.frame(minWidth: 1080, minHeight: 560)`; AppKit `contentMinSize` **1080 x 520**. A restored frame below the floor is snapped up once per window per session.
- Title bar: `titlebarAppearsTransparent = true`, `.fullSizeContentView`, not movable by background, title hidden (`.navigationTitle("")` at root; each pane removes `.title` from its toolbar and draws its own). Traffic lights stay.
- Title-bar fill = `theme.chrome`, so window background is one uniform themed surface in normal, zoomed and fullscreen.
- `WindowState.mode` tracks `.normal`, `.zoomed` (window covers 90% or more of the visible screen on both axes), `.fullscreen`. Used for responsive top insets (zoomed draws an opaque ~36pt title-bar overlay).
- Panels, popovers, menus and the Settings window are excluded from this configuration (tested in `WindowChromeTests`).
- Activation policy forced to `.regular` and app activated at launch (SwiftPM build isn't a bundle).

### Menu commands (all in the system menu bar)
| Menu | Item | Shortcut | Action |
|---|---|---|---|
| File (replaces New Item) | New Conversation | ⌘N | `navigator.startNewConversation()`: creates a draft route, clears selection |
| View (replaces Sidebar group) | Hide Conversation List / Show Conversation List (label flips) | ⌃⌘S | toggles `navigator.listShown` with animation |
| View | Reload From Server | ⌘R | posts `.psmithReloadRequested`: kicks event stream, reloads preferences, debounced list refresh, staleness check on open conversation |
| View | Increase Text Size | ⌘= | `fontScale += 0.1` |
| View | Decrease Text Size | ⌘- | `fontScale -= 0.1` |
| View | Actual Text Size | ⌘0 | `fontScale = 1.0` |
| App menu | Settings… | ⌘, (system) | opens Settings window |

Other shortcuts in the main window (not in the menu bar):
- ⌥⌘I: toggle inspector (detail toolbar button; only when a real conversation, not a draft, is open).
- ⌘. : Stop streaming (composer stop button).
- Return: send (composer). ⇧Return: newline. ⌘Return: send / resend button's shortcut.
- Escape in the list search field: clears text and drops focus.
- No ⌘F to focus search. No ⌘1..9, no arrow-key shortcuts beyond List's native up/down selection.

Window focus (`NSWindow.didBecomeKeyNotification`) triggers the same reconcile as ⌘R.

---

## 3. Top-level routing

```
AppShell
 ├─ no active account  → LoginView()                         (cold start)
 └─ active account     → RootView  (env: that AppModel, .id(accountID) rebuilds tree on switch)
      ├─ authState .resolving        → large ProgressView, centered
      ├─ authState .signedIn, no user → large ProgressView (defensive)
      ├─ authState .signedOut         → LoginView(initialHost, initialUsername) (sign back in)
      └─ signed in
           ├─ splash: providers not loaded or convos model not built, and < 3s elapsed → large ProgressView
           ├─ providers.needsOnboarding → OnboardingView (full window)
           └─ HomeView(user)
```

Splash: hard 3-second ceiling (`splashExpired`), so an unreachable server never holds the window on a spinner; after that the real UI renders and the offline banner explains the empty list. Cached conversations hydrate before the first network refresh.

All spinners are `ProgressView().controlSize(.large)` filling the window on `theme.chrome`. No logo, no text.

---

## 4. LoginView (sign-in; three contexts, one look)

Contexts:
1. **Cold start**: no accounts. Starts at phase Server.
2. **Add account**: presented as a sheet from the account footer menu. Starts at phase Server.
3. **Sign back in**: active account signed out. Host and username pre-seeded; starts at phase Credentials; "Change" server link hidden.

Container: `VStack(spacing: 24)`, padding 40, full frame, **top-aligned** (not vertically centered). Content columns are capped at 380 (server phase) and 320 (credential fields).

### Phase 1: ServerURLEntry
- Title "Connect to psmithd" (`.title2`).
- Subtitle "Enter the URL where your Psmith server is running." (`.callout`, secondary, centered).
- TextField, rounded border, placeholder `https://psmith.example.com`, prefilled with the last-used server URL (`ServerURLStore.shared.current`), autocorrect off. Return runs the probe. Width max 380.
- Status line (below field), one of:
  - probing: small spinner + "Probing…" (secondary, callout)
  - idle: nothing
  - ok: green `checkmark.circle.fill` "Reachable — psmithd answered." or "Reachable — psmithd <version>."
  - wrong server: orange `exclamationmark.triangle.fill` "Server responded but isn't a Psmith server: <detail>"
  - unreachable: red `xmark.octagon.fill` "Couldn't reach this URL: <detail>" (also used for "not a valid URL")
- Buttons row (max 380): **Test connection** (`.glass`; disabled while probing or field blank) and **Continue** (`.glassProminent`, default action / Return; enabled only after a successful probe).
- Note: Continue requires an explicit successful test. Return in the field tests; Return again (default action) continues.

### Phase 2: CredentialsEntry
- Title "Sign in to Psmith" (`.title2`).
- Server chip: `server.rack` icon + full URL (callout, secondary, middle-truncated) + **Change** link button (`.link`) returning to phase 1 (hidden in sign-back-in).
- Username TextField (rounded, content type username), Password SecureField (rounded, content type password; Return submits). Width max 320.
- Inline error (red, callout, centered, max 320) from `PsmithError.display`.
- **Sign in** button, `.glassProminent`, full width 320, default action; shows small spinner while in flight; disabled when either field empty or in flight.
- Success: `accountManager.addAccount` (dedupes on host+username), then `dismiss()` (closes the sheet in add-account context).

### "OR CONTINUE AS" section (any phase, when other signed-in accounts exist)
- Divider-label-divider: hairlines (`.tertiary`, 1pt) around "OR CONTINUE AS" (`.caption2` semibold, secondary).
- One row per other account: `person.crop.circle` (24pt light, secondary), display label (callout semibold), host (caption, secondary, middle-truncated), chevron.right (tertiary). Padding 12h / 8v. Glass interactive rounded rect radius 8. Tap: switch account and dismiss.
- Max width 380.

Snapshots: `LoginViewSnapshots.empty` (default, minWindow), `RootViewSnapshots.loggedOut`.

---

## 5. OnboardingView (full-window gate; PsmithUI)

Shown when signed in but `providers.needsOnboarding` (no provider or no enabled model). Lifts live when a provider and model exist, including if added from the Settings window.

- ScrollView, content max width 720, padding 32h / 40v, leading aligned.
- Header: "Welcome to Psmith" (`.largeTitle` semibold) + explanatory paragraph (callout, secondary).
- Step indicator: three dots (22pt circles) "Provider", "Credentials", "Models" joined by 1pt lines (`secondary @ 30%`). Done = filled accent + white checkmark; active = accent @ 20% fill, accent numeral; future = secondary @ 15%.
- Step 1 "Choose a provider": adaptive grid (min 220, spacing 12) of template cards: ProviderLogo 22pt, name (callout semibold), driver type (caption2 secondary). Card padding 12, `primary @ 4%` fill, 0.5pt `secondary @ 20%` border, radius 8. Spinner while templates load.
- Step 2 credentials: logo + name header, **Back** (borderless). Fields: Label (TextField, "e.g. Anthropic"), API key (SecureField "sk-…", hint about env var), API base URL (only for `openai-compatible`). **Add Provider** (`.borderedProminent`, spinner while working; disabled until valid).
- Step 3 "Enable models": **Back**, explanatory text, discovered-model checklist (rows show "(already enabled)"), **Retry discovery** or "No models found." empty state, **Finish setup** button with spinner.
- Error line: caption, red.
- Uses `.borderedProminent` (not glass), unlike the rest of the shell.

---

## 6. HomeView: the three-column shell

`NavigationSplitView(columnVisibility: .doubleColumn)` with three columns:

| Column | Content | Width |
|---|---|---|
| 1 (sidebar) | `Color.clear`, always hidden. Exists only so the list sits in the docked middle column (macOS 26 floats a sidebar column as an inset glass panel with no way to dock it). | 0 |
| 2 (content) | `ConversationListView` + account footer | min 240, ideal 290, max 420 |
| 3 (detail) | Draft / ConversationView / WelcomeView | flexible, never collapses |

- The system sidebar toggle is removed from every column. Column visibility is forced back to `.doubleColumn` if anything changes it.
- Hiding the list collapses the **middle** `NSSplitViewItem` directly (`ListColumnCollapse`, 0.25s animation). While shown, the column cannot be dragged shut (`canCollapse` false).
- The system window title is removed; the detail pane draws its own.
- On appear: wires `navigator.openSettingsWindow` to SwiftUI `openSettings`; loads conversations, providers, profiles.

### Toolbar, list shown (items over the list column)
Right-aligned in the list section (Spacer first):
1. **Hide Conversations**: icon `sidebar.leading`, help "Hide the conversation list (⌃⌘S)".
2. **New Conversation**: icon `square.and.pencil`, help "New conversation (⌘N)".

### Toolbar, list hidden (items move to detail column, `.navigation` placement, left)
1. **Show Conversations**: `sidebar.leading`, help "Show the conversation list (⌃⌘S)".
2. **New Conversation**: `square.and.pencil`, help "New conversation (⌘N)".

When nothing is selected and no draft, a flexible `ToolbarSpacer` holds the detail section open so list buttons don't drift right.

### Detail column routing
1. `navigator.draft` set and (no selection or selection == draft's created id) → `ConversationView(newConversation:)` keyed on the draft UUID. After first send it carries on as that conversation (same screen, no remount).
2. Selection resolves in `conversations` or `archivedConversations` → `ConversationView(conversation:)` keyed on id.
3. Otherwise → `WelcomeView`.

Selection rules: picking a different conversation in the list abandons the draft; starting a draft clears the list selection. Detail background `theme.chrome` under the toolbar.

Snapshots: `HomeViewSnapshots.chatsNothingSelected`, `chatsConversationSelected`, `chatsComposingNew`, `settingsWindow` (each at default and minWindow). `ListToggleTests`: starts with list shown and spacer hidden; hiding collapses the list not the spacer.

---

## 7. Account footer (bottom of the list column)

Pinned in the list column's bottom safe-area inset: `Divider` then the account row, on solid `SidebarWell` so rows never show through. Padding 14h / 10v.

### Row anatomy (the Menu's label)
- Avatar: first letter of username, uppercased, `.caption` bold white, in a 22 x 22 circle filled `theme.accent`.
- Username (`.callout`) over server host (`.caption`, secondary); single line each.
- Connectivity dot, 7 x 7: green "Connected" / orange "Server unreachable" (tooltip).
- Whole row is the click target. Menu indicator hidden, plain button style.

### Menu contents (native pull-down)
1. Section **Accounts**: one item per account, label `username · host`; the active one has a checkmark. Click switches account (rebuilds the whole window tree).
2. **Add Account…** → Add Account sheet.
3. Submenu **Remove Account** (only if other accounts exist; the active account can't be removed): items `username · host…` → confirmation dialog.
4. Divider. **Settings…** (`SettingsLink`, opens Settings window).
5. Divider. **Sign Out of <username>** (destructive role). Signs out active account; RootView shows sign-back-in LoginView.

### Modals from the footer
- **Add Account sheet**: header row "Add Account" (`.title3` semibold) + **Cancel** (Esc), padding 20h / 16t; body is `LoginView()` from phase Server. Min size 460 x 420.
- **Remove account confirmation dialog**: title "Remove <display label>?" (visible), message "Removes the saved credentials and forgets this account on this Mac. Conversations on the server are unchanged.", buttons **Remove Account** (destructive), **Cancel**.

---

## 8. ConversationListView (middle column)

`List(.sidebar)` with hidden scroll background on `SidebarWell`, tint `theme.accent`, hard scroll-edge effects top and bottom.

### Top header (list's top safe-area inset; solid SidebarWell; padding 6 top / 8 bottom; spacing 6)
Order top to bottom:
1. **Offline banner** (only when `connectivity == .offline`): `wifi.exclamationmark` + "Server unavailable. Showing cached chats." (or "Server unavailable" when nothing cached). Caption, orange text, one line, padding 10h / 6v, fill `orange @ 14%`, radius 8, outer padding 10h.
2. Normal mode:
   - **SearchField** (custom, not `.searchable`): `magnifyingglass` (small, secondary), plain TextField "Search", clear button `xmark.circle.fill` (tertiary, help "Clear search") when text present. Height 28, padding 8h, fill `primary @ 7%`, radius 7, focus ring `accentColor @ 60%` 1.5pt. Outer padding 12h. Escape clears and unfocuses.
   - **Filter bar** (hidden while search text non-empty), padding 12h, spacing 6:
     - Chip **All**
     - Chip **Pinned**
     - Chip-styled Menu **Profile** (label becomes the chosen profile's name): items are all non-parent-only profiles, alphabetical. There is no "clear" item; tap All to clear.
     - Spacer
     - **Sort** menu: icon-only `arrow.up.arrow.down`, borderless, no indicator, help "Sort conversations". Inline picker "Sort By": **Last Activity** (`recentlyUsed`, default) / **Date Created** (`recentlyCreated`). Changing it refreshes from server.
   - Chip style: caption (semibold when on), padding 10h / 4v, capsule. On: fill `theme.accent`, white text. Off: fill `primary @ 7%` (14% pressed), primary text.
3. Archive mode: **archive header** replaces search and filters: borderless back button `chevron.left` "Conversations", centered "Archived" (`.headline`), 90pt clear spacer for balance. Padding 12h.
- A hairline divider appears under the header only once the list is scrolled.

### Content modes
1. **Grouped (default)**: sections from `SidebarSections.group` over the filtered set:
   - "Pinned" first (any pinned conversation, regardless of date), then "Today", "Yesterday", "Previous 7 Days" (2 to 7 days), "Previous 30 Days" (8 to 30), then one section per month ("October 2026"), newest first. Within each section, newest first by the active sort date (last activity or created).
   - Footer section: `LoadMoreFooter` (small centered spinner while another page exists; auto-loads on appear; page size 50) then an **Archived** row: `archivebox` label in secondary, plain button, not selectable, help "Browse archived conversations". Click enters archive mode.
2. **Search** (text non-empty; 250ms debounce; server matches titles only): one section "Titles matching “<text>”", flat list sorted by recency, load-more footer. Filters and pinned grouping don't apply.
3. **Archived**: one untitled section of archived conversations (loaded on entering), its own load-more footer. Rows never show the unread dot or "Replying".

Filters are client-side over the loaded pages (Pinned = `pinnedAt != nil`, Profile = `profileID == id`). Search and sort are server-side.

### Row anatomy (`SidebarRow`)
`HStack(alignment: .firstTextBaseline, spacing: 6)`, vertical padding 2:
1. **Unread dot**: 8 x 8 circle `theme.accent`, in a 10pt-wide gutter that stays even when the dot is hidden so titles align. Means "unseen reply" only (Mail convention). Cleared when the conversation is opened (viewing marks it seen).
2. Text stack (spacing 2):
   - Line 1: **title** (body; semibold when unread, medium otherwise; `labelColor`, one line; "Untitled" fallback), Spacer(4), trailing either **"Replying"** (caption, `theme.accent`) while a stream runs, or the **timestamp** (caption, secondary, monospaced digits): today = short time, within 7 days = abbreviated weekday, older = "Oct 3". Stamp uses the active sort date.
   - Line 2: **profile name** (caption, secondary, one line), omitted when profile unknown.
- No pin icon on the row; pinned status shows only by the "Pinned" section. No profile color dot on the row (ProfileColor exists but the row doesn't use it). No preview text, no model name, no message count.
- Selection: native sidebar selection highlight tinted by `theme.accent`.
- Accessibility: children combined; dot labeled "Unread reply".

### Context menus
- Normal row: **Pin** / **Unpin**, **Rename…**, **Archive**, divider, **Delete…** (destructive).
- Archived row: **Unarchive**, divider, **Delete…** (destructive).
- No swipe actions, no drag-and-drop, no keyboard Delete binding.

### Modals from the list
- **Rename alert**: title "Rename Conversation", TextField "Title" prefilled, buttons **Rename** (ignored if blank after trim), **Cancel**.
- **Delete confirmation dialog**: title "Delete “<title or Untitled>”?" (visible), message "This permanently deletes the conversation and all its messages.", **Delete** (destructive; routes to archive delete when in archive mode), **Cancel**.

### Empty / loading / error states (overlay over the list; first match wins)
1. Load error with no rows: ContentUnavailableView "Couldn't Load" `exclamationmark.triangle`, description = error, action **Try Again**.
2. Loading with no rows: plain `ProgressView`.
3. Archive mode, none archived: "Nothing Archived" `archivebox`.
4. Search, no results: system `ContentUnavailableView.search(text:)` ("No Results for …").
5. Grouped, nothing visible:
   - offline: "Can't Reach the Server" `wifi.exclamationmark`, "No cached chats to show."
   - filter active: "No Matches" `line.3.horizontal.decrease`, "No conversations fit this filter."
   - otherwise: "No Conversations" `bubble.left.and.bubble.right`, "Start one with ⌘N."

Snapshots (`ConversationListViewSnapshots`, each at default and minColumn): `offlineWithCachedChats`, `offlineWithEmptyCache`, `allChatsEmpty`, `allChatsSingle`, `allChatsMultiple`, `allChatsRecentlyCreated`, `byProfileSingleProfileEmpty`, `byProfileSingleProfileMany`, `byProfileTwoProfiles` (render as grouped; see section 0), `searchEmptyQuery`, `searchWithMatches`, `searchNoMatches`. `SidebarSectionsTests`: groupsByLastActivity, newestFirstWithinASection, dateCreatedOrderGroupsByCreation, olderMonthsComeAfterNewerOnes.

---

## 9. WelcomeView (detail, nothing selected)

Centered `VStack(spacing: 14)`, horizontal padding:
- `bubble.left.and.bubble.right`, 40pt light, tertiary.
- "Welcome to Psmith" (`.title3` semibold, secondary).
- Caption (tertiary, centered): "Start a new conversation, or pick one from the sidebar." or, when no startable profile exists, "Add a profile in Settings to start your first conversation."
- **New Conversation** button: `plus.bubble` label, padding 14h / 6v, `.glassProminent`, regular size, top padding 4. Disabled when no non-parent-only profile exists. (The disabled state offers no link to Settings; the copy says to go there.)

Detail toolbar in this state: just the flexible spacer (and Show/New buttons if the list is hidden).

Snapshots: `WelcomeViewSnapshots.welcomeCanCreate`, `welcomeCannotCreate` (default, minColumn).

---

## 10. New conversation (draft) flow

Entry points: File > New Conversation (⌘N), list toolbar `square.and.pencil`, detail toolbar `square.and.pencil` (list hidden), Welcome's button. All call `navigator.startNewConversation()`.

Lifecycle:
1. A `DraftRoute` (local UUID) is created; list selection clears; detail shows `ConversationView(newConversation:)`.
2. The view model auto-picks the **default** profile (`isDefault && !parentOnly`) if one exists; otherwise no profile is chosen and the composer is disabled with placeholder "Choose a profile to start".
3. Nothing exists on the server until the first send. On send, the conversation is created, inserted into the list (`convos.didCreate`), selected, and the same screen continues as the transcript.
4. Selecting any other conversation discards the draft silently (no "discard draft?" prompt).

### DraftStartView (start screen, before the first user message)
- ScrollView anchored center; padding 32h / 40v; `VStack(spacing: 26)`.
- Heading "Who are you talking to?" (`.title` bold) and subtitle "A profile sets the system message, the model and the plugins. Nothing is saved until you send." (callout, secondary, centered).
- **Profile grid**: `LazyVGrid` adaptive columns min 220 / max 280, spacing 12, grid max width 860. Order: default first, then favorites, then name. Parent-only profiles excluded.
  - **Profile card** (button): padding 14, min height 96, radius 14.
    - Header row: 8pt **profile color dot** (`ProfileColor.of(id)`, a stable FNV-1a hash into a fixed 7-color palette, not themed), name (`.headline`, one line), trailing "Default" badge (caption2 semibold; accent when selected, secondary otherwise) or a yellow `star.fill` for favorites.
    - Description (callout, secondary, up to 3 lines) or "No description."
    - Unselected: fill `primary @ 4%`, 1pt border `primary @ 8%`. Selected: fill `accent @ 16%`, 1.5pt border `accent`. Tooltip = description.
    - Click on another card restarts the draft from that profile (`chooseDraftProfile`), which resets model and settings.
  - **New Profile…** tile: `plus` label, secondary, min height 96, dashed 1pt border `primary @ 12%` (dash 4,4), radius 14. Opens Settings on Profiles.
- Below the grid: banners and the composer, max width 760.
- `TitleBand` overlay at top (solid chrome + hairline behind the toolbar).
- ProfileColor palette (fixed RGB): (0.30,0.59,0.85) blue, (0.24,0.64,0.43) green, (0.72,0.49,0.79) purple, (0.89,0.44,0.23) orange, (0.78,0.64,0.23) gold, (0.16,0.61,0.76) teal, (0.85,0.42,0.55) pink. These are outside the theme system and include orange and gold, which the theme rules otherwise reserve for warnings.

Draft toolbar: title "New Conversation", subtitle = chosen profile name; model menu present; no context chip, no inspector button (inspector is forced closed for drafts).

Snapshots: `HomeViewSnapshots.chatsComposingNew`, `ConversationViewSnapshots.draftConversation`.

---

## 11. Detail column chrome for an open conversation (shell-level only)

### Toolbar (detail section)
1. **Title item** (leading, `.automatic`, shared background hidden): title (`.headline`, one line; "Untitled" or "New Conversation") over subtitle (`.caption`, secondary) = profile name, plus active context title or "Context N of M" when there's more than one context, joined by " · ". Leading padding 8, max width 520.
2. Flexible spacer.
3. **Model menu** (`.primaryAction`): label `cpu` + current model display name (or model id, or "Choose model"), menu indicator visible, help "Model for this conversation", disabled when no selectable models. Contents: optional harness notice text, Section "Favorites", one Section per provider (alphabetical), divider, **All Models…** (opens Model Picker sheet). Current model has a checkmark.
4. **Context chip** (real conversations with a token count): `gauge.with.needle` + compact token count (monospaced). Normal = primary; past the user's warning threshold = orange; near the model's window = red. Help text explains and says "Click to compress." Click opens the inspector on its Context tab.
5. **Inspector toggle**: `sidebar.trailing`, ⌥⌘I, help "Show the inspector (⌥⌘I)". Hidden for drafts.

### Inspector (trailing column)
- Width min 290, ideal 320, max 440. State (open + tab) lives on the Navigator, so it persists across conversation switches.
- Header: segmented Picker **Context / Settings / Plugins**, padding 12h / 10v, then Divider.
- Context tab has its own context menus (**Switch to This Context**, **Delete Context…**) and a delete-context confirmation dialog; Settings tab opens a call-settings edit sheet with **Done**. (Inspector contents are a separate inventory.)

### Bottom inset (over transcript; column max 820 + 32)
Top to bottom: banners, then one of:
- **ArchivedBarMac** (archived conversation): `archivebox`, "Archived" (callout semibold) over the archive date (caption2 secondary), **Unarchive** (`.glassProminent`, small). Padding 16h / 10v, `.thinMaterial`. Replaces the composer (server refuses writes).
- **CompressionReviewBar** (pending compression summary awaiting review).
- **Composer**: optional "Continue the discussion" chip (`arrow.turn.down.right`, caption, borderless secondary; disabled offline), pending attachment strip (56pt thumbnails or file chips max 180 wide, "Uploading…" chip, remove `xmark.circle.fill`), then one glass island (radius 22, padding 16h / 14b): AppKit text view (max 10 lines, placeholder "Message <profile>"), footer row with paperclip (26 x 26; disabled with explanatory tooltip when the model/harness can't take files), hint "Return to send · ⇧Return for a new line" (caption tertiary), and the send button: `arrow.up` (`.glassProminent`), or `arrow.clockwise` resend when the last message is an unanswered user turn, or red `stop.fill` while streaming (⌘.).
- **Jump to latest**: 32pt glass circle `arrow.down`, floats 44pt above the bottom bar when scrolled far from bottom.
- Files can be dropped anywhere on the conversation; ⌘V with a file or image attaches.

### Inline banners (the only transient-feedback surface in the window)
`InlineBanner`: orange icon, caption text (selectable), optional `xmark` dismiss (help "Dismiss"); padding 12h / 8v, fill `orange @ 12%`, radius 10, outer padding 16h. Instances:
1. "Compression failed: <err>" (dismissible)
2. Load error when messages exist (dismissible)
3. Speech playback error, `speaker.slash.fill` (dismissible)
4. Offline: `wifi.exclamationmark` "Server unreachable. Messages queue and send when it's back." (not dismissible)

So offline shows in three places at once: the list's offline banner, the footer's orange dot, and this composer banner.

### Sheets and modals from the detail column
- **ElicitSheet** (server/plugin asks for input mid-stream; auto-presents from the stream's pending queue): `key.fill` accent + "Psmith needs input" (headline), message (callout secondary), schema-driven fields with "required" tags, red error line, buttons **Cancel**, **Decline**, **Submit** (semibold, spinner). Padding 20, max width 480.
- **CompressSheet** (620 x 640): `CompactPane` (summary of how many messages will be summarized and current token use, editable "PROMPT" text editor 140 to 280 tall, "COMPRESSION MODEL" pill with **Change**, inline filterable model rows with favorite stars) and a footer: "You review the summary before the new context starts." + **Cancel** (Esc) + **Compress** (Return; disabled without a guide and an enabled model, or while compacting/sending).
- **ModelPickerSheet** (680 x 620): `ConversationModelPicker` ("N models across M providers" header, `ModelPickerList` with capability requirements and harness notice) + **Done** (Return). Selecting a model closes it.
- **File importer** (system open panel) from the paperclip, multiple selection, types filtered by provider.
- Inspector's delete-context confirmation and call-settings sheet (see above).

---

## 12. System notifications

`MacNotifier`: when a reply completes while the app is not active and the "notify on unfocused completion" preference is on, posts a user notification: title "Psmith", subtitle = conversation title (or "Untitled"), body = reply preview, default sound, threaded per conversation. Requests permission lazily the first time. Foreground presentation suppressed. Click activates the app; conversation selection is not wired (section 0, item 4).

---

## 13. Complete list of modals, menus and transient UI in the main window

Sheets:
1. Add Account (LoginView in a sheet, 460 x 420 min)
2. ElicitSheet (max width 480)
3. CompressSheet (620 x 640)
4. ModelPickerSheet (680 x 620)
5. Inspector call-settings edit sheet (Done)

Alerts:
6. Rename Conversation (text field)

Confirmation dialogs:
7. Remove account
8. Delete conversation (normal and archived)
9. Delete context (inspector)

Menus:
10. Account footer menu (with Remove Account submenu)
11. Profile filter chip menu
12. Sort menu (inline picker)
13. Toolbar model menu
14. Row context menu (normal)
15. Row context menu (archived)
16. Inspector context-row context menu
17. Menu-bar commands (File, View)

System panels:
18. File importer (open panel)
19. User notifications

Banners: list offline banner; InlineBanner x4 in the conversation. Toasts: none on Mac. Popovers: `MessageUsagePopover` exists for message rows (transcript scope, not shell).

---

## 14. Snapshot and behavior tests naming shell states

`clients/psmithd-mac/Tests/PsmithMacSnapshotTests/`:
- `HomeViewSnapshots`: chatsNothingSelected, chatsConversationSelected, chatsComposingNew, settingsWindow (default + minWindow)
- `ConversationListViewSnapshots`: 12 states listed in section 8 (default + minColumn)
- `LoginViewSnapshots`: empty
- `RootViewSnapshots`: loggedOut, loggedIn
- `WelcomeViewSnapshots`: welcomeCanCreate, welcomeCannotCreate
- `ConversationViewSnapshots` (detail, partly shell): empty, draftConversation, compressSheet, inspectorContext, inspectorSettings, contextChipNearTheModelsWindow, pendingCompressionReview, truncatedCompressionReview, longCompressionSummaryPreview, streaming, streamingLongText, erroredStream, composerGrowsWithDraft, composerCapsAtEightLinesAndScrolls, messageTextSelectionMode, compressionCardTextSelectionMode, userMessageEditMode, turnDetailsShown, withThinkingEnabled, historicalToolCalls, liveStreamingToolCall, councilDiscussion, userAndAssistantPair (+Scaled130), longBullets (+Scaled110), longBlockquotesScaled110, bulletsInBlockquote, wideBlocksContained, longAssistantMessageRendersInFull
- `CompactViewSnapshots`: defaultState, customCompressionModelPicked, running
- Behavior tests: `ListToggleTests` (list hide/show), `WindowChromeTests` (popover and panel keep their size; main window gets floor and chrome), `SidebarSectionsTests` (date grouping), `SelectionModeTests` and `ComposerKeyTests` / `ComposerTextViewTests` (composer and text selection events), `TranscriptScrollTests`, `DockIconSyncTests`, `SettingsShellTests`.
- `LiveProbe.swift` renders the real app at 1280 x 820, 1052 x 600, 1440 x 900, 1920 x 1200 for manual probes.

---

## 15. Gaps and inconsistencies worth a design decision

1. `byProfile` grouping: dead in the Mac UI, alive in PsmithKit and in three snapshot names. Decide whether the redesign brings back grouping by profile or drops the mode.
2. Notification click doesn't open the conversation (`pendingConversationSelection` unconsumed).
3. No way to focus search by keyboard (no ⌘F); no keyboard Delete/Archive on rows; no multi-select bulk actions.
4. Rows show no pin glyph and no profile color; the profile color system (`ProfileColor`) appears only on the draft start cards and uses hues (orange, gold) that the theme rules reserve for warnings.
5. Offline appears three times (list banner, footer dot, composer banner).
6. Welcome's disabled "New Conversation" has no path to Settings, though copy says "Add a profile in Settings".
7. LoginView is top-aligned at padding 40 in a 1100 x 720 window; Onboarding uses `.borderedProminent` while everything else uses glass styles.
8. `theme.highlight` is defined per theme but unused in the Mac shell.
9. Mixed font APIs: list rows, account footer and toolbar title use fixed `.font(...)`, so they ignore the ⌘= / ⌘- text-size setting except through the root default; most other surfaces use `.scaledFont`.
10. Switching away from a draft discards typed text without a prompt.
