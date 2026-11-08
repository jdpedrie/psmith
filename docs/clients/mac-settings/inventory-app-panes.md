> Snapshot of the Mac Settings window as built on 2026-11-06, taken before the no-modal redesign. The redesign's boards are on the Settings page of the "Psmith Mac redesign concepts" canvas. The companion inventory is [inventory-data-panes.md](inventory-data-panes.md).

# Psmith Mac settings: functional inventory (app-level panes)

Scope: General (context warning, notifications, location, cache), Appearance, Usage, Integrations (Langfuse, Embedder, Speech, Device tools), the sidebar account menu, View-menu commands, the Settings window structure and deep links, and settings iOS has that the Mac lacks. Models, Profiles, Plugins and Servers panes are out of scope here except where other parts of the app link into them.

Source files (Mac): `/Users/jdp/dev/psmith/clients/psmithd-mac/PsmithMac/` `SettingsView.swift`, `AppNavigation.swift`, `SettingsPage.swift`, `GeneralSettingsView.swift`, `NotificationsSettingsView.swift`, `PrivacySettingsView.swift`, `AppearanceSettingsView.swift`, `CostSettingsView.swift`, `LangfuseSettingsView.swift`, `EmbedderSettingsView.swift`, `SpeechSettingsView.swift`, `DeviceToolsSettingsView.swift`, `HomeView.swift`, `PsmithMacApp.swift`, `DockIconSync.swift`.
Shared: `/Users/jdp/dev/psmith/clients/PsmithSwift/Sources/` `PsmithUI/Composite/{Theme,ThemeCard,AppPreferences,VersionFooter}.swift`, `PsmithKit/ViewModels/{PreferencesViewModel,LangfuseViewModel,EmbedderViewModel,SpeechSettingsModel,SpeechPlaybackModel}.swift`, `PsmithKit/Cache/CachePreferences.swift`, `PsmithKit/DeviceFactsProvider.swift` (LocationFactPreference), `PsmithKit/DeviceToolHandlers/FilesFolderBookmark.swift`.

Storage legend used below:
- **Server (synced)**: stored per user on psmithd, follows the user to every device.
- **This Mac**: UserDefaults (or a security-scoped bookmark) on this machine only, not per account unless noted.

---

## 0. Modal / sheet / popover / alert / dialog / picker census

Every modal-ish surface in scope, for the "no modals" redesign:

| # | Where | Kind | Trigger | Content |
|---|---|---|---|---|
| M1 | General › Context warning | `.alert` with a TextField | Picking "Custom…" in the Warn at menu | Title "Warn at", message "In thousands of tokens: 120 warns at 120,000.", field placeholder "Thousands of tokens", buttons Save / Cancel |
| M2 | General › On-device cache | `.confirmationDialog` | "Clear Cache…" | Title "Clear on-device cache?", message "Conversations will reload from the server on next view. No server-side data is affected.", buttons Clear (destructive) / implicit Cancel |
| M3 | Integrations › Langfuse | `.confirmationDialog` | "Delete…" | "Delete Langfuse configuration?" / "Removes credentials and drops the in-memory cache. New turns won't be traced until you reconfigure." / Delete (destructive) |
| M4 | Integrations › Embedder | `.confirmationDialog` | "Delete…" | "Delete embedder configuration?" / "New messages stop getting embedded. The memory plugin will fail until reconfigured." / Delete |
| M5 | Integrations › Speech | `.confirmationDialog` | "Reset…" | "Reset speech configuration?" / "Credentials are forgotten. Playback switches to the on-device voice." / Reset |
| M6 | Integrations › Device tools | `.fileImporter` (system open panel, folders only) | "Choose Folder…" / "Change Folder…" | macOS folder picker |
| M7 | Account menu | `.sheet` | "Add Account…" | Header "Add Account" + Cancel (Esc), then the full LoginView (server probe then credentials). Min 460×420 |
| M8 | Account menu | `.confirmationDialog` | "Remove Account › <user · host>…" | "Remove <displayLabel>?" / "Removes the saved credentials and forgets this account on this Mac. Conversations on the server are unchanged." / Remove Account (destructive), Cancel |
| M9 | Account menu itself | Native pull-up `Menu` (popup) | Click the sidebar footer | See section 8 |
| M10 | Location | OS permission prompt (system, not ours) | Turning Send location on | CoreLocation authorization |
| M11 | Notifications | OS permission prompt (system) | First time a notification would post | UNUserNotificationCenter |
| M12 | Device tools | OS prompts for Calendar / Reminders (system) | First model call | EventKit |
| M13 | Location (denied) | Leaves the app | "Open System Settings…" | Opens Privacy › Location Services in System Settings |
| M14 | Settings window itself | Separate window (SwiftUI `Settings` scene) | ⌘, / app menu / account menu / deep links | Whole settings UI lives in a second window, not in the main window |
| M15 | Draft conversation "New Profile…" tile | Not modal but jumps windows | Click | Opens the Settings window on Profiles |

Also present but not modal: hover tooltips (`.help`) on the eye buttons, Refresh, connectivity dot, etc. Device-tool call rows expand inline (disclosure, no popover).

Dead state: `LangfuseSettingsView` declares `showingReplaceConfirm` but never presents anything with it. `Navigator.mode` has an `.settings` case that nothing sets anymore (settings moved to its own window).

---

## 1. Settings window structure and navigation

### 1.1 Window
- SwiftUI `Settings { }` scene. Opened by ⌘, and the app menu's "Settings…" (system-provided), the account menu's "Settings…" (`SettingsLink`), and programmatic deep links (`Navigator.showSettings`).
- Size: min 900×560, ideal 1050×640, same for every pane so the window doesn't jump. `windowResizability(.contentMinSize)`. Excluded from the main window's chrome treatment (keeps standard title bar). Window title = selected pane's label (SwiftUI does this).
- Environment: theme tint/accent, app font scale (`\.fontScale`), but not the `\.font` override the main window gets.
- **Not signed in state**: if there's no active account or it isn't signed in, the whole window shows `ContentUnavailableView` "Not Signed In", icon person.crop.circle.badge.questionmark, "Sign in to a server to change its settings.", fixed 480×320.
- Settings shown are always for the **active account**. Switching account in the main window swaps what the Settings window shows (server-synced panes reload on appear; Mac-local values are global to the Mac, not per account).

### 1.2 Pane toolbar (TabView rendered as Settings toolbar), in order
| Pane | Label | SF Symbol | Layout |
|---|---|---|---|
| general | General | gearshape | single grouped form |
| appearance | Appearance | circle.lefthalf.filled | single grouped form |
| models | Models | cpu | list + detail (out of scope) |
| profiles | Profiles | person.crop.circle | list + detail (out of scope) |
| plugins | Plugins | puzzlepiece.extension | list + detail (out of scope) |
| servers | Servers | server.rack | list + detail (out of scope; MCP servers) |
| usage | Usage | chart.bar | single grouped form |
| integrations | Integrations | chevron.left.forwardslash.chevron.right | list + detail |

- Default pane on first open: **Models** (`settingsCategory = .models`). The selected pane persists across opens within a run (held on the shared Navigator, not persisted across launches).
- List+detail panes (`SettingsSplit`): fixed 240pt list column on a "sidebar well" background (theme chrome a step darker), divider, detail fills the rest. No draggable divider.

### 1.3 Integrations list (left column)
`List` with sidebar style, single selection (can't deselect). Each row: icon, title, caption.
| Item | Title | Caption | Icon |
|---|---|---|---|
| langfuse | Langfuse | Tracing and cost | chart.line.uptrend.xyaxis |
| embedder | Embedder | Memory search | point.3.connected.trianglepath.dotted |
| speech | Speech | Read replies aloud | speaker.wave.2 |
| deviceTools | Device tools | Calendar, reminders, notes | wrench.and.screwdriver |
Default selection: Langfuse. Persists for the run. No status badges on rows (e.g., configured/enabled is not shown in the list).

### 1.4 Common page chrome (`SettingsPage`)
- Optional title (title2 semibold; used by the four Integrations pages since the window title says "Integrations"), subtitle (callout, secondary), then a grouped `Form`.
- Form content max width 680pt, centered beyond that.
- `SettingsSection`: header title, content rows, optional caption footer.
- `SettingsLabel`: row title with a caption line of explanation beneath it.
- `SettingsLoadFailed`: orange "Couldn't load these settings" with warning triangle, the error message (selectable), and a Retry button that shows a small spinner while retrying.

### 1.5 Deep links into Settings (`Navigator`, `AppNavigation.swift`)
- `showSettings(_ category)`: sets the pane then calls `openSettingsWindow` (a closure HomeView installs from SwiftUI's `openSettings`; only works once HomeView has appeared).
- `openProfileSettings(id:)`: sets `pendingProfileSelection = id` then `showSettings(.profiles)`. SettingsView consumes it on appear / on change: switches to Profiles, selects that profile, clears the flag.
- Call sites:
  - Draft conversation profile chooser (`ConversationSheets.swift`, "Who are you talking to?" grid): last tile "New Profile…" calls `showSettings(.profiles)` (opens Profiles; does not start a new-profile draft).
  - Profile form "Inherits from" picker (`ProfilesView.swift` → `ProfilePickerRow`, PsmithUI `ProfileCardPicker`): each card's gear button ("Open in Settings") calls `openProfileSettings(id:)`.
  - Account menu "Settings…" (`SettingsLink`, opens on whatever pane was last selected).
- No deep link exists into General, Appearance, Usage or any Integration item. There's no `settingsIntegration` setter outside the Integrations list.

---

## 2. General pane

Subtitle: "How Psmith behaves on this Mac, and the context warning that follows you to every device."
Save model: **every control applies immediately** (no Save bar). Server value is optimistic with rollback.
On appear: reads cache size; calls `preferences.load()` (cached copy first, then server).

### 2.1 Section "Context warning" (Server, synced)
- **Warn at**: menu Picker.
  - Options: Off (0), 50k tokens, 75k tokens, 100k tokens, 150k tokens, 200k tokens; if the current value is a non-preset custom value it appears as its own option ("120k tokens"); "Custom…".
  - Default: Off (server default `contextWarningTokens = 0`).
  - Choosing a preset: writes immediately (`PreferencesService.Update`), optimistic; on failure the value reverts and the error shows.
  - Choosing "Custom…": opens alert **M1**. Field prefilled with the current value in thousands (blank if Off). Validation: integer, 1…2000 (thousand tokens, i.e. up to 2,000,000). Invalid or out of range input: Save silently does nothing (no error shown). Saved value = input × 1000.
  - Compact format: "82k", "1.2M" (`ContextWarning.compact`).
- Footer: "Past this size, a conversation's context shows beside the model under the message field; click it to compress. Near a model's own limit it shows in red whatever this is set to. Applies on all your devices." Plus `preferences.error` in red when a load or write failed.
- Behavior note: near-window warning (≥90% of the model's context window) shows regardless of this setting, even when Off.
- States: loaded from cache instantly; load failure only shows as red footer text (picker still shows cached/default value). No spinner.

### 2.2 Section "Notifications" (This Mac) — `NotificationsSettingsSection`
- Toggle **"Notify when a reply finishes"**, detail "Only while Psmith is in the background; you're already looking at the result otherwise." Default **on**. Key `psmith.appPrefs.notifyOnUnfocusedCompletion`.
- Footer: "macOS asks for permission the first time a notification would post."
- No display of the macOS notification authorization state, no "denied, open System Settings" affordance (iOS has one; see 9).

### 2.3 Section "Location" (This Mac) — `LocationSettingsSection` in PrivacySettingsView.swift
- Toggle **"Send location"**, detail "Attach an approximate location to each message." Default **off**. Key `psmith.deviceFacts.locationEnabled`. Turning on calls `requestPermissionAndFix()` (may raise OS prompt **M10**). Turning off stops attaching immediately.
- Row **System permission** (read-only, colored value):
  - Not asked yet (secondary) / Restricted (red) / Denied (red) / Authorized (green) / Unknown (secondary).
  - When Denied: an extra right-aligned button **"Open System Settings…"** (deep link to Privacy › Location Services, **M13**).
- Preview rows, shown only when toggle on AND authorized (Mac checks `.authorizedAlways` only):
  - If a fix exists: **City** (if reverse-geocoded), **Coordinates** (secondary), **Last fix** (relative time, short style, e.g. "2 min. ago").
  - Else: "Acquiring location…" with small spinner.
- Footer: "Off until you turn it on. When on, each message this Mac sends includes an approximate location, such as "Brooklyn, NY". Only basic_grounding, or another plugin that asks for it, uses it."
- Data source: `LocationProvider.shared` (CoreLocation), live-updating.

### 2.4 Section "On-device cache" (This Mac)
- **Used**: read-only, monospaced. "N KB" under 1 MB, else "N.N MB". Source: local cache `totalBytes()` (read on appear and after cap change / clear).
- **Cap**: "N MB" + Stepper. Range 25…1024 MB, step 25. Default 100 MB. Key `psmith.cache.capBytes` (bytes, clamped). Applies immediately; lowering it evicts now and refreshes Used.
- **Clear cache**: label "Clear cache", detail "Conversations reload from the server the next time you open them." Destructive button "Clear Cache…" (label "Clearing…" while running). Disabled while clearing or when Used = 0. Confirmation **M2**. Clears local cache only.
- Cache is not per-account in the UI (one cap for the Mac).

---

## 3. Appearance pane (This Mac)

Subtitle: "How the app looks and how much it shows. Stored on this Mac."
Save model: immediate.

### 3.1 Section "Text size"
- Row **Size**: optional borderless "Reset" button (only visible when scale ≠ 100%; sets 1.0), small fixed-size "A" (11pt), Slider 220pt wide, large fixed-size "A" (18pt), percentage readout "100%".
- Range 0.8…1.6 (80%…160%), step 0.1, default 1.0. Clamped in the model. Key `psmith.appPrefs.fontScale`.
- Footer: "Scales every label, message, and control in the app. ⌘+ and ⌘− work anywhere; ⌘0 resets."
- Effect: drives `\.fontScale` for every `scaledFont` call, plus a body font override in the main window.

### 3.2 Section "Transcript"
- Toggle **"Show turn details"**, detail "Role labels, the model on every reply, token counts and times." Default **off**. Key `psmith.appPrefs.showTurnDetails`.
- Footer: "Off, the transcript keeps only what's worth noticing: a model change, a poor cache on a large prompt, a reply that stopped early. The details are always one click away under a reply's info button."

### 3.3 Section "Theme"
- Two-column grid (top aligned, 12pt spacing) of `ThemeCard`s. Clicking a card applies the theme instantly; there is no preview-then-commit. Key `psmith.theme.id`, default "system".
- Footer: "Sets the accent color, your message bubbles, the selection highlight, the window's tint, and the app icon. Light and dark follow your system setting."
- Side effects of a theme change: tint/accent everywhere, window background color reconfigured for all windows, Dock icon swapped to `AppIcon-<Theme>.png` (System restores the bundle icon; Finder/Launchpad icon unchanged).
- No light/dark override control: appearance always follows macOS.

**ThemeCard anatomy** (one per theme): button with rounded 12pt card filled with the theme's chrome color; border = accent at 2pt when selected, faint 1pt otherwise.
1. Header: name (headline), blurb (caption, secondary, wraps), trailing check (checkmark.circle.fill in accent when selected, empty circle otherwise).
2. Bubble preview: user bubble "What's the capital of Japan?" (bubble tint at 18%), assistant bubble "Tokyo." (neutral 4%).
3. Swatch row: four 22pt-tall swatches labelled accent, bubble, highlight, chrome (9pt tertiary labels).

**Themes** (order as shown):
| id | Name | Blurb | Accent light / dark | Highlight light / dark | Chrome light / dark |
|---|---|---|---|---|---|
| system | System | Platform default. Uses your system accent color and stock neutrals. | platform accent | platform accent | system chrome |
| sage | Sage & Graphite | Calm and green. Deep sage on a soft green-gray ground. | #2C7550 / #3EA36E | #CFE5D8 / #24402F | #E6F0E9 / #15241C |
| clay | Clay & Ink | Warm, approachable. Terracotta on linen-paper neutrals. | #B04A22 / #E46F3A | #F3D2BF / #4A2A1B | #F7EADC / #2B1C14 |
| slate | Slate Pro | Cool and focused. Steel blue on blue-gray neutrals. | #2C65A0 / #4C96D9 | #CCDDF0 / #1F3550 | #E4ECF5 / #131D29 |
| aubergine | Aubergine & Cream | Distinctive without being loud. Plum on warm cream. | #7A3A8C / #B87CCA | #E6D1EC / #3A2445 | #F4E9F2 / #22162A |
| nordic | Nordic Mist | Crisp and cold. Fjord blue on icy gray. | #1C6F8E / #299CC1 | #C8E4EF / #193A47 | #E2EEF4 / #12202A |

Bubble tint equals accent in every theme. Each theme also carries five persona (speaker) colors, none red/orange/yellow (reserved for error/warning/delete).

---

## 4. Usage pane (Server data, read-only)

Subtitle: "Spend recorded per assistant turn, including compression and speech synthesis. Free-tier and subscription models don't count."
No saving; the only state is the range, which is not persisted (resets to Month each time the view is created).

### 4.1 Section "Spend"
- **Range**: segmented Picker: Day, Week, Month, Year, Custom. Default Month. Rolling windows (now minus 1 / 7 / 30 / 365 days), not calendar-aligned.
- When Custom: two date-only DatePickers **From** (≤ To) and **To** (≥ From). Defaults: From = 30 days ago, To = today. To is inclusive (promoted to start of next day).
- **Total**: USD, monospaced. Hidden while the first load is in flight with no rows.
- Footer by range: "Trailing 24 hours." / "Trailing 7 days." / "Trailing 30 days." / "Trailing 365 days." / "<From medium date> – <To medium date>."

### 4.2 Section "By provider"
- Error line (red, selectable) if the load failed (`PsmithError.display`). Old rows remain visible under it.
- Empty + loading: centered small spinner. Empty + loaded: "No cost events in this window yet."
- Rows: label = provider label; detail = "<Type> · N turns" or "<Type> · no events in this window" (Type mapping: anthropic → Anthropic, openai-compatible → OpenAI-compatible, google → Google, else raw); value = USD.
- USD format: "$0.00" style, except a nonzero amount below one cent gets 3–6 decimals to its first significant digit.
- Source: `ModelProviders.ListProviderCosts(since, until)`. Reloads whenever the range or custom dates change; an older in-flight load is cancelled.
- No manual refresh control on Mac (iOS has pull-to-refresh). No per-model breakdown, no chart, no export.

---

## 5. Integrations › Langfuse (Server, synced; secrets encrypted at rest)

Title "Langfuse". Subtitle: "Mirror every assistant turn into your Langfuse instance for observability and cost tracking. Per-user and off by default. Credentials are encrypted at rest."
Save model: **explicit**. An inline Save bar section appears below the form only while dirty: right-aligned "Discard" and "Save Changes" (default action, Return). While saving: "Saving…" with spinner; both disabled.

### States
- Loading (first load not returned): centered spinner in a section.
- Load failed (never loaded): `SettingsLoadFailed` with Retry.
- Loaded, no row on server: form at defaults (host US cloud, empty keys, off). Delete disabled.
- Loaded, configured.
- Dirty: Save bar visible; Test disabled with explanation.
- Saving / Testing / Deleting: inline spinners on the respective buttons.
- Error after load: red selectable text section above the Save bar (save or delete failure; also a failed Refresh reload).
- Dirty definition: host, public key, or enabled differs from saved, or any secret typed. With no saved row: anything differs from the defaults.

### Section "Connection"
- **Host**: TextField, placeholder "https://us.cloud.langfuse.com", detail "Langfuse Cloud (US or EU) or your own URL." Default "https://us.cloud.langfuse.com". No client-side validation.
- **Public key**: TextField, placeholder "pk-lf-…", detail "Starts with pk-lf-." No client validation.
- **Secret key**: SecureField (or plain TextField when revealed) + borderless eye / eye.slash toggle (tooltip "Show what you're typing" / "Hide secret"). Placeholder "sk-lf-…", or "Replace existing secret…" when one is saved. Detail "Starts with sk-lf-." When a secret is saved and the field is empty: small "Saved" label with lock icon. Write-only: server never returns it; empty field on save = leave existing secret alone. No way to clear just the secret (only Delete).
- Footer: "Both keys are in Langfuse under Settings › API Keys. The secret is stored encrypted and the server never returns it."

### Section "State"
- Toggle **"Send traces to Langfuse"**. Disabled until a public key is entered and a secret is saved or typed; then shows orange caption "Save a public key and secret first." Default off. Part of the draft (needs Save).
- **Last successful emit** (only if server has one): "<relative, numeric> · <short time>".
- **Test trace** row: label detail varies: "Save changes first to send a test." (dirty) / "Save a secret first to send a test." / "Fires one synthetic trace using the saved credentials. Look for it in your Langfuse Traces tab."
  - Button "Refresh" (tooltip "Reload from server (refreshes the last-emit timestamp)"): reloads and **resets the drafts** to the server values (discards unsaved edits without asking).
  - Button "Send Test Trace" ("Testing…" + spinner). Disabled unless a secret is saved, not dirty, not testing, not saving. Tests the saved server row.
- Test result row (persists until next test/delete): green check "Test trace sent" or red triangle "Test failed", optional selectable error message, trailing latency "N ms".

### Section "Danger zone"
- **Delete configuration**: destructive "Delete…" ("Deleting…"). Disabled while deleting or when there's no saved row. Confirmation **M3**. On success drafts reset to defaults, test result cleared.
- Footer: "Delete removes the configuration entirely. To keep the credentials and pause tracing, turn off Send traces to Langfuse instead."

Order on page: Connection, State, [error], [Save bar], Danger zone.

---

## 6. Integrations › Embedder (Server, synced; key encrypted at rest)

Title "Embedder". Subtitle: "Run every message through a vector embedder so the memory plugin can pull older context back into long conversations. Per-user and off by default. API keys are encrypted at rest."
Save model: explicit, same inline Save bar as Langfuse. Same loading / load-failed / error / dirty / saving / deleting states.
On load, also fetches (quietly, errors ignored) the list of driver types and the stats.

### Section "Driver"
- **Type**: menu Picker of server-registered driver types (sorted). Default "openai". If the types list failed to load the menu is empty.
- Footer: ""openai" works with OpenAI, Ollama via /v1/embeddings, Voyage, Together, or any OpenAI-compatible API."

### Section "Connection"
- **Base URL**: TextField, placeholder "https://api.openai.com/v1", detail "Ends with /v1. The driver appends /embeddings." Default value "http://localhost:11434/v1" (Ollama). No validation.
- **Model**: TextField, placeholder "text-embedding-3-small", detail "Like nomic-embed-text or text-embedding-3-small." Default "nomic-embed-text".
- **Dimensions**: number readout + Stepper, range 1…8192, step 1, detail "Must match the model." Default 768. (Stepping by 1 to 1536 is impractical; no direct numeric entry.)
- **API key**: SecureField/TextField + eye toggle (no tooltip). Placeholder "sk-…" or "Replace existing key…". Detail "Leave empty for local Ollama." When saved and empty: "Key saved. Type a new one to replace it." with lock. Write-only; empty = leave alone. No way to clear the key alone.
- Footer: "nomic-embed-text has 768 dimensions, text-embedding-3-small 1536, text-embedding-3-large 3072. The server never sends a saved key back."

### Section "State"
- Toggle **"Use this embedder"** (draft; default off). Not gated on anything.
- Stats row (when stats loaded): label "N message(s) pending" (unembedded count), trailing capsule badge "Worker active" (green) or "Worker idle" (secondary). Stats refresh on load, save and delete only; not polled on Mac (the model has `refreshStats()` but nothing calls it).
- **Test connection** row, shown only when a saved row exists and not dirty: detail "Sends one Embed("ping") through the saved config." Button "Test Connection" ("Pinging…"), disabled while testing.
- Test result row: "Connection OK" / "Test failed", error (3 lines max, selectable), latency.

### Section "Danger zone"
- **Delete configuration**: "Delete…" with confirmation **M4**; disabled while deleting or no saved row. Resets drafts to defaults and refreshes stats.
- Footer: "Delete removes the configuration entirely. Messages already embedded stay searchable. To pause embedding and keep the credentials, turn off Use this embedder instead."

---

## 7. Integrations › Speech (Server synced, plus one Mac-local toggle)

Title "Speech". Subtitle: "Read assistant replies aloud. On-device synthesis needs no setup; configure a cloud or self-hosted voice for higher quality. Keys are encrypted at rest and audio is never stored."
Save model: explicit Save bar for the server config; the Playback toggle is immediate and local. Same loading / load-failed / error / dirty / saving states. Load also fetches (quietly) available kinds and the user's chat providers.

Sections are conditional on the drafted kind:

### Section "Synthesis" (always)
- **Kind**: menu Picker of server-registered kinds. Labels: apple_local → "On-device (Apple)", grok → "Grok (xAI)", openai-compatible → "OpenAI-compatible", others raw. Default apple_local.
- Footer per kind: apple_local "Synthesized on this Mac. Free, works offline, no configuration." / grok "xAI's voice API. Streams through your server; audio is never stored." / openai-compatible "OpenAI's TTS or any self-hosted server speaking the same API."

### Section "Voice" (always)
- **Voice**: TextField. Placeholder "System default voice" (apple_local), "eve" (grok), "alloy" (openai-compatible). Detail "Empty uses the system default voice." (apple_local) or "The provider's voice id." Default empty. Free text, no voice list/picker, no preview.
- **Model** (non-apple_local only): TextField, placeholder "gpt-4o-mini-tts" (openai-compatible) or "Model (optional)"; detail "Optional synthesis model." Default empty.
- **Speed**: Slider 0.7…1.5, step 0.1, readout "1.0×". Default 1.0 (server 0 = driver default, shown as 1.0).
- Footer (non-apple_local only): "Grok voices include eve and ara; OpenAI's include alloy, and its model is gpt-4o-mini-tts. Self-hosted servers define their own."

### Section "Endpoint" (openai-compatible only)
- **Base URL**: TextField, placeholder "https://api.openai.com", detail "Leave empty for OpenAI." Default empty.
- Footer: "Point at a self-hosted server (Kokoro, Piper, or XTTS behind an OpenAI-compatible bridge) to synthesize for free. The driver appends /v1/audio/speech."

### Section "Credentials" (non-apple_local only)
- **API key**: SecureField/TextField + eye toggle. Placeholder "API key" or "Replace existing key…". Detail "Wins over a reused provider credential." When saved and empty: "Key saved. Type a new one to replace it." Write-only.
- **Reuse provider credential** (only if the user has any chat providers): menu Picker, "None" + each provider label. Detail "Synthesis cost is then attributed to that provider on the Cost screen." Default None.
- No "Remove key" button on Mac, though the model supports `clearAPIKey()` and iOS shows it. Consequence: on Mac, once a key is stored you can't switch to provider-credential reuse (the key wins) without Reset.

### Section "Playback" (always; This Mac)
- Toggle **"Speak replies as they arrive"**, detail "Reads each completed reply aloud in the conversation you're viewing. This Mac only." Default off. `@AppStorage("psmith.speech.autoSpeak")`. Immediate, not part of the draft.

### Then
- Error section (red) if any.
- Save bar if dirty.
- Section **"Test"**: only when not dirty AND the saved kind isn't apple_local. "Test synthesis" / "Synthesizes one short phrase through the saved config." Button "Test Synthesis" ("Synthesizing…"). Result row: "Synthesis OK" / "Test failed", error (3 lines), "N bytes of audio" on success, latency. The test does not play audio. No test for the on-device voice.
- Section **"Danger zone"**: only when the saved kind isn't apple_local. "Reset to on-device" / destructive "Reset…" ("Resetting…"), confirmation **M5**. Deletes the row, re-reads the server default (apple_local). Footer: "Removes the configuration and credentials. Read-aloud falls back to the on-device voice."

Hidden model field: `enabledDraft` (server `enabled`, default true) exists and counts toward dirtiness but has no control on Mac or iOS.

---

## 8. Integrations › Device tools (This Mac + Server audit log)

Title "Device tools". Subtitle: "Tools the model runs on this Mac: Calendar, Reminders, and a folder of notes. macOS asks for Calendar and Reminders access the first time the model uses them. The files tools need a folder."
Save model: immediate. No Save bar.

### Section "Files" (This Mac; security-scoped bookmark, key `psmith.obsidian.vaultBookmark.v1`)
- **Folder** row: when set, green checkmark + folder's last path component (selectable; "Saved" if it can't resolve). When not set: "None" (secondary).
- Buttons (right-aligned):
  - "Forget Folder" (destructive, only when set): clears the bookmark immediately, unregisters files tools, re-registers device tools with the server. **No confirmation on Mac** (iOS confirms).
  - "Choose Folder…" / "Change Folder…": opens the system folder picker **M6**. On pick: saves bookmark, registers files tools, re-registers with server. Picker error shown in red: "Couldn't save bookmark: …".
- Footer: "Any folder of notes works; an Obsidian vault, or a folder inside one, is the usual pick. Psmith keeps a bookmark so the model can read and write inside it."
- Calendar and Reminders: no rows, no permission status display, no on/off switch. Always registered; OS prompts on first use (**M12**).

### Section "Recent activity" (Server data, read-only)
- Source: `DeviceTools.ListCalls` for this user, newest first, pages of 50; infinite scroll (loads next page when the last row appears; stops when a page < 50).
- Error line (red): "Couldn't load activity: …" or "Couldn't load more: …". No Retry button.
- Empty (not loading): "No device-tool activity yet. Calls the model makes on your devices show up here."
- Loading: centered small spinner below rows.
- Row: status dot (green ok, red error, orange other/timeout), tool name (monospaced, medium), relative time (short, tertiary), disclosure chevron. Click toggles inline expansion: error message (red, selectable), "Input" and "Output" JSON blocks (pretty-printed, sorted keys, monospaced, 12 lines max, selectable, subtle rounded background). Calls from all the user's devices appear (not only this Mac).
- Loaded once per view creation (only if empty); no refresh control. Not shown: duration, conversation link, device that ran it.

---

## 9. Account menu (main window, sidebar footer) — HomeView.swift

Not in the Settings window. A native pull-up `Menu` styled as the sidebar's footer row.

**Footer row (menu label)**: avatar circle in the theme accent with the username's first letter (white, bold); username (callout); server host (caption, secondary); trailing 7pt status dot: green "Connected" or orange "Server unreachable" (tooltip), from the connectivity monitor.

**Menu contents** in order:
1. Section "Accounts": one item per saved account, label "<username> · <host>", checkmark on the active account. Selecting switches account immediately (no confirm). Then **"Add Account…"** → sheet **M7** (LoginView; dedupes on host+username).
2. **"Remove Account"** submenu (only when there are other accounts): one item per non-active account "<username> · <host>…" → confirmation **M8**. Removing does a best-effort server logout, clears the token, forgets the account on this Mac. The active account can't be removed from here.
3. Divider, **"Settings…"** (`SettingsLink`, opens the Settings window on the last-used pane).
4. Divider, **"Sign Out of <username>"** (destructive role, no confirmation): server logout, clears token, main window returns to login for that account (account stays in the list).

Storage: account list, active account ID and per-account tokens are on this Mac (AccountStore / keychain-style token store). Not shown anywhere: account display label editing (the `displayLabel` field exists on Account but has no editor), full server URL, server version, app version.

---

## 10. Menu-bar commands related to settings (PsmithMacApp.swift)

- App menu: **Settings…** ⌘, (system, from the `Settings` scene).
- File: "New Conversation" ⌘N (replaces New Window).
- View (replaces the system sidebar group):
  - "Hide Conversation List" / "Show Conversation List" ⌃⌘S
  - "Reload From Server" ⌘R
  - **"Increase Text Size"** ⌘= (⌘+), +0.1
  - **"Decrease Text Size"** ⌘−, −0.1
  - **"Actual Text Size"** ⌘0, reset to 1.0
  - Text size commands clamp to 80…160% and write the same value as the Appearance slider (`psmith.appPrefs.fontScale`). They're never disabled at the limits.
- No menu items for theme, turn details, notifications, or opening a specific settings pane.

---

## 11. Storage summary

| Setting | Where | Key / RPC | Default |
|---|---|---|---|
| Context warning threshold | Server, synced | PreferencesService (`context_warning_tokens`) | 0 (Off) |
| Notify when a reply finishes | This Mac | `psmith.appPrefs.notifyOnUnfocusedCompletion` | on |
| Send location | This Mac | `psmith.deviceFacts.locationEnabled` | off |
| Cache cap | This Mac | `psmith.cache.capBytes` | 100 MB (25…1024) |
| Text size | This Mac | `psmith.appPrefs.fontScale` | 1.0 (0.8…1.6) |
| Show turn details | This Mac | `psmith.appPrefs.showTurnDetails` | off |
| Theme | This Mac | `psmith.theme.id` | system |
| Usage range | not stored | view state | Month |
| Langfuse host/keys/enabled | Server, synced, secret encrypted | LangfuseService Get/Update/Test/Delete | US cloud host, off |
| Embedder type/URL/model/dims/key/enabled | Server, synced, key encrypted | EmbedderService Get/Update/Test/Delete/ListTypes/Stats | openai, localhost:11434/v1, nomic-embed-text, 768, off |
| Speech kind/voice/model/speed/URL/key/provider ref | Server, synced, key encrypted | SpeechService Get/Update/Test/Delete/ListKinds | apple_local, speed 1.0 |
| Speak replies as they arrive | This Mac | `psmith.speech.autoSpeak` | off |
| Files folder | This Mac (bookmark) | `psmith.obsidian.vaultBookmark.v1` | none |
| Device tool activity | Server, read-only | DeviceToolsService ListCalls | n/a |
| Accounts, active account, tokens | This Mac | AccountStore | n/a |

Mac-local settings are global to the Mac, not per signed-in account (the Settings window's subtitle on General conflates "this Mac" and "every device" in one pane).

---

## 12. Save model per pane

| Pane | Model |
|---|---|
| General | Immediate. Context warning is optimistic server write with rollback + red footer error. Custom value via alert. |
| Appearance | Immediate, local. |
| Usage | Read-only; range change refetches. |
| Langfuse | Explicit Save Changes / Discard bar, shown only when dirty; Refresh also discards drafts. |
| Embedder | Explicit Save / Discard bar. |
| Speech | Explicit Save / Discard bar for server config; Playback toggle immediate and local. |
| Device tools | Immediate (folder bookmark); activity read-only. |
| Account menu | Immediate actions; Add via sheet, Remove via confirmation, Sign out unconfirmed. |

No pane warns about unsaved changes when switching panes, switching Integration items, or closing the window. The drafts are view-owned models recreated when the Integration detail view is recreated, so switching away from Langfuse/Embedder/Speech silently discards unsaved edits.

---

## 13. iOS settings the Mac lacks (or does differently)

From `/Users/jdp/dev/psmith/clients/psmithd-ios/PsmithiOS/Settings/` and `Chats/ChatsRoot.swift`:

1. **Build/version footer** (`VersionFooter`, Settings root): "Psmith <app commit> · Server <server version>" from an unauthenticated probe. Mac shows neither version anywhere in settings.
2. **Notification permission state**: iOS checks authorization, requests it when the toggle turns on, and when denied shows "Open iOS Settings" with footer "Notifications are turned off for Psmith in iOS Settings, so nothing will ring until they're allowed there." Mac has no status or fix-it link (relies on the first-post prompt).
3. **Speech "Remove" stored API key** button (`clearAPIKey()`), next to the "Key saved" label. Mac lacks it.
4. **Forget folder confirmation**: iOS confirms ("The files stay where they are. The model loses access until you pick the folder again."); Mac forgets immediately. iOS also explains: "Removes the bookmark from this device. The model will report "folder not configured" until you pick a folder again."
5. **Device tool activity**: iOS shows a per-call **Duration**, has pull-to-refresh and a **Retry** on error, and a `ContentUnavailableView` empty state. Mac has none of these.
6. **Cost**: pull-to-refresh (Mac has no refresh).
7. **Location authorization**: iOS accepts When-In-Use or Always for the preview; Mac requires Always (macOS reports Always when granted, so likely equivalent in practice).
8. **Health tools** (`DeviceTools/HealthTools.swift`): iOS-only HealthKit device tools (permission prompts at first use); no Mac counterpart, and no settings row on iOS either.
9. Account menu differences: iOS menu header shows the full server URL; uses a "Switch account" submenu listing other accounts by `resolvedDisplayLabel`. iOS has **no Remove Account** in the menu (Mac does). Neither platform edits the account display label.
10. iOS Settings is grouped "Data" (Providers, Profiles, Plugins, MCP Servers) and "Settings" (General, Appearance, Notifications, Privacy, Cost, Langfuse, Embedder, Speech, Files, Device tool activity). iOS has separate Notifications and Privacy screens; Mac folds them into General. iOS Appearance has no text-size control (Dynamic Type covers it).

Mac has that iOS lacks: text size slider and menu commands, a Langfuse "Refresh" button, Remove Account in the account menu. (Both show Langfuse "Last successful emit".)
