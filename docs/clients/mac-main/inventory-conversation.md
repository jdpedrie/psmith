# Psmith Mac: conversation surfaces inventory

Read-only inventory of the main window's conversation reading pane, written so a designer can redraw every screen, state and control without reading code. Source of truth at time of writing (master, with uncommitted working-tree changes):

- `clients/psmithd-mac/PsmithMac/ConversationView.swift` (shell, body, toolbar, transcript, composer, banners, pending rows, usage popover, archived bar, TitleBand)
- `clients/psmithd-mac/PsmithMac/MessageRowMac.swift` (message row, action row, inline editor, ActionIcon, HuggingWidth)
- `clients/psmithd-mac/PsmithMac/MessageAttachmentsMac.swift` (thumbnail, chip, lightbox)
- `clients/psmithd-mac/PsmithMac/ComposerTextView.swift` (AppKit text input)
- `clients/psmithd-mac/PsmithMac/ConversationSheets.swift` (CompressSheet, ModelPickerSheet, DraftStartView, ProfileColor)
- `clients/psmithd-mac/PsmithMac/CompactView.swift` (CompactPane, the body of the compress sheet)
- `clients/psmithd-mac/PsmithMac/ContextListView.swift` (ContextListPane, currently not reachable from the UI, see section 13)
- `clients/psmithd-mac/PsmithMac/ConversationInspector.swift`, `ConversationSettingsView.swift`, `ConversationModelPicker.swift`, `WelcomeView.swift`, `HomeView.swift` (hosting)
- PsmithUI shared: `Composite/Theme.swift`, `StreamingRow.swift`, `ThinkingDisclosure.swift`, `ToolCallDisclosure.swift`, `PersonaLabel.swift`, `CompressionSummaryCard.swift`, `CompressionReviewBar.swift`, `ElicitSheet.swift`, `ContextRow.swift`, `ModelPickerList.swift`, `ModelMetaStrip.swift`, `HarnessBindingCard.swift`, `CallSettingsForm.swift`, `Atomic/MarkdownText.swift`, `BoundedMarkdown.swift`, `SelectableMessageText.swift`, `WelcomeReveal.swift`, `PluginRenderers/*`
- PsmithKit: `ViewModels/ConversationViewModel.swift`, `PreferencesViewModel.swift` (ContextWarning), `AppPreferences.swift`, `DraftStore.swift`

Conventions used below: fonts are SwiftUI text styles passed through `scaledFont` (all scale with the app-wide text size, 0.8x to 1.6x in 0.1 steps; ⌘= / ⌘- / ⌘0). "Glass" means the macOS 26 Liquid Glass effect (`.glassEffect`, `.glass`, `.glassProminent` button styles). Colors called `.secondary/.tertiary/.quaternary` are system hierarchical label colors. `primary.opacity(x)` means a neutral wash of the label color at that alpha.

---

## 0. Theme tokens

Defined in `PsmithUI/Composite/Theme.swift`. Six themes: System, Sage & Graphite, Clay & Ink, Slate Pro, Aubergine & Cream, Nordic Mist. Each token has a light and dark value.

| Theme | accent (L / D) | highlight (L / D) | chrome (L / D) |
|---|---|---|---|
| System | controlAccentColor | controlAccentColor | windowBackgroundColor |
| Sage | #2C7550 / #3EA36E | #CFE5D8 / #24402F | #E6F0E9 / #15241C |
| Clay | #B04A22 / #E46F3A | #F3D2BF / #4A2A1B | #F7EADC / #2B1C14 |
| Slate | #2C65A0 / #4C96D9 | #CCDDF0 / #1F3550 | #E4ECF5 / #131D29 |
| Aubergine | #7A3A8C / #B87CCA | #E6D1EC / #3A2445 | #F4E9F2 / #22162A |
| Nordic | #1C6F8E / #299CC1 | #C8E4EF / #193A47 | #E2EEF4 / #12202A |

`bubbleTint` equals `accent` in every theme. Each theme also has five `personaColors` (no reds, oranges or yellows; they are reserved for error, warning, delete). Persona slot index wraps modulo 5. Example System set: #5B6B7A/#93A5B5, #6E7F63/#A3B594, #7A6A80/#AE9BB4, #4F7A78/#85B0AD, #7C7060/#B3A48D.

Where each token shows up in the conversation surfaces:

- `theme.chrome`: the whole reading-pane background (extends under the toolbar), the TitleBand fill, the base layer of the user bubble, the stream-clip fade gradient.
- `theme.bubbleTint`: user bubble and pending/queued bubble, at 0.24 alpha over chrome (`ThemedUserBubbleBackground`).
- `theme.accent`: inline-editor bubble fill (0.10) and stroke (0.6, 1.5pt); speaking / "Done selecting" action icon tint; draft-start selected profile card fill (0.16) and stroke (1.5pt) and its "Default" label; inspector context-size bar fill (normal state), growth line chart, cost bars (0.75), active context row fill (0.16) and stroke (0.45); CompactPane selected model row glass tint (0.18); ContextRow active glass tint (0.18); ModelPickerList notice band (0.07), selected row fill (0.10) and stroke (0.4) and checkmark; HarnessBindingCard fill (0.07), icon and title. App `.tint` is also set from accent, so `.tint` foregrounds (e.g. "this conversation" source label in the inspector) use it.
- `theme.highlight`: not used in conversation surfaces (sidebar active row only).
- `theme.personaColor(i)`: persona dot (7pt), persona name text, persona rail (0.55 alpha, 3pt).
- System-fixed semantic colors: orange (errors, warnings, compression, queued badge, banners, over-threshold context), red (near-window context, error text, stop button, delete, truncated), yellow (partial cache dot, favorite stars), green (good cache dot).

Separate non-theme palette `ProfileColor` (ConversationSheets.swift): 7 fixed colors hashed (FNV-1a) from the profile id, used for the 8pt dot on draft-start profile cards: rgb(0.30,0.59,0.85), (0.24,0.64,0.43), (0.72,0.49,0.79), (0.89,0.44,0.23), (0.78,0.64,0.23), (0.16,0.61,0.76), (0.85,0.42,0.55).

---

## 1. Hosting and screen states of the reading pane

`HomeView.detailContent` picks one of three:

1. Draft new conversation (`navigator.draft` set): `ConversationView(newConversation:)`.
2. A selected conversation (live or archived): `ConversationView(conversation:)`.
3. Nothing selected: `WelcomeView` (section 15).

`ConversationView` (outer shell):

- Loading model: full-pane centered `ProgressView` until the view model exists.
- Existing conversation: cache-first. Cached transcript renders immediately, network load replaces it, then an on-device title may be generated (Apple Foundation Models titler).
- Draft: default profile (`isDefault && !parentOnly`) is auto-chosen; otherwise only the model list loads.
- On appear / id change: marks the conversation as "being viewed" so its sidebar row shows no new-message dot.
- Reconnect: when connectivity goes offline to online, the transcript reloads.
- Sheet: the MCP elicitation form (`ElicitSheet`, section 11) is presented whenever the active stream has a pending elicitation.

`ConversationBody` states for the scroll area (`scrollBody`):

| State | Condition | Rendering |
|---|---|---|
| Load failure, empty | `loadError` set, no messages, not draft | `EmptyStateView` "Failed to load", icon `exclamationmark.triangle`, description = error |
| Loading, empty | `loading` and no messages | centered spinner |
| Draft start screen | draft, no user message yet, nothing pending, not creating | `DraftStartView` (section 14) with banners + composer inside it |
| Transcript | otherwise | scroll view (section 3) + bottom inset (banners + bottom bar) |

Pane background: `theme.chrome`, ignoring the top safe area so the toolbar band is solid.

Window-level keyboard shortcuts relevant here (PsmithMacApp commands): ⌘N New Conversation; ⌃⌘S Hide/Show Conversation List; ⌘R Reload From Server; ⌘= / ⌘- / ⌘0 text size. Settings window ⌘, (standard).

---

## 2. Title band and toolbar

### TitleBand (struct `TitleBand`)

A solid, non-interactive band drawn behind the window toolbar so transcript text never shows through.

- Height = top safe area (toolbar height), fallback 52pt, plus a 1pt hairline `primary.opacity(0.08)` at the bottom.
- Fill `theme.chrome`. Overlaid on top of both the transcript scroll view and the draft start screen.
- It can draw its own title (leading 20, trailing 360 padding, headline + caption subtitle) but in the conversation it is used with empty strings; the actual title is a toolbar item. The system top scroll edge effect is hidden (`scrollEdgeEffectHidden(.top)`), the band replaces it.

### Toolbar contents (left to right)

1. **Title block** (ToolbarItem, `.automatic`, shared glass background hidden): VStack spacing 0.
   - Title: `.headline`, 1 line. "New Conversation" for a draft; otherwise the conversation title, or "Untitled" when empty. Live-updates when an auto title arrives from the sidebar list.
   - Subtitle (only when non-empty): `.caption`, secondary, 1 line. Parts joined by " · ": the profile name (draft profile or the conversation's profile); plus, when the conversation has more than one context, the active context's title or "Context N of M".
   - Leading padding 8; max width 520; header accessibility trait.
2. Flexible spacer.
3. **Model menu** (primary action group). A `Menu` with label `Label(<model display name>, systemImage: "cpu")`, title + icon, visible menu indicator, tooltip "Model for this conversation". Label text is the selected model's display name, else raw model id, else "Choose model". Disabled when there are no selectable models.
   - Menu contents, in order: harness notice text (non-interactive line, only for harness-bound conversations); section "Favorites" (favorites sorted by name); one section per provider (provider label, models sorted by name); divider; "All Models…" (opens ModelPickerSheet, section 12). The current model shows a `checkmark` icon. Picking a model calls `selectModel` immediately.
   - Harness-bound conversations list only models from the bound provider.
4. **Context chip** (same group; hidden for drafts and when no token count is known). Button, `Label(<compact tokens>, systemImage: "gauge.with.needle")`, title + icon, monospaced digits. Compact form like "82k", "1.2M".
   - Tint: default primary; orange when past the user's warning threshold (`contextWarningTokens` preference; 0 = off); red when at or above 90% of the model's context window (always, regardless of threshold).
   - Tooltip: "Context: 12,345 tokens" normally; "Context is N tokens, past your warning level. Click to compress." (orange); "Context is N of the model's W tokens. Click to compress." (red).
   - Action: opens the inspector on the Context tab.
   - Token source: server token count when available, else last reply's prompt (cache-aware) plus its output.
5. **Inspector toggle** (not for drafts). `Label("Inspector", systemImage: "sidebar.trailing")`, tooltip "Show the inspector (⌥⌘I)", shortcut ⌥⌘I. Toggles the right inspector column (section 16).

When the conversation list is hidden, HomeView adds two navigation items in this pane's toolbar: "Show Conversations" (`sidebar.leading`, tooltip "Show the conversation list (⌃⌘S)") and "New Conversation" (`square.and.pencil`, tooltip "New conversation (⌘N)").

The inspector stays open, on its tab, across conversation switches. Never shown for a draft.

---

## 3. Transcript

### Layout

- Column: `min(paneWidth - 48, 820)` points. Content is a leading-aligned eager `VStack` (spacing 14) capped at 820, horizontal padding 24, top 16, bottom 12, centered in the pane. Eager (not lazy) on purpose: all offsets are exact.
- The column width is published to rows as `chatPaneWidth`; user bubbles cap at 80% of it (fallback 600 when not yet measured).
- Order of rows: settled history (each message, or a compression card), then pending rows (in-flight user message, then offline-queued messages), then either the compacting row or the streaming row.
- Bottom inset (safe-area inset, floating over the transcript): VStack spacing 6 of banners (section 9) then the bottom bar (composer, review bar, or archived bar), framed to `column + 32` wide, centered.
- Drag and drop: dropping file URLs anywhere on the transcript attaches them (only when the selected provider accepts attachments).
- There is no "load older" control. The whole active-context chain loads at once.

### Scroll behavior (follow then park)

Design reference: `docs/clients/chat-scroll.md`.

- Entry: anchored at the bottom (newest).
- Following: while the viewport sits at the bottom, any content growth or viewport shrink re-pins to the bottom.
- Any user scroll gesture (tracking, interacting, decelerating) stops following immediately. When the gesture settles, following resumes only if within 32pt of the bottom.
- Sending (optimistic user text appears) always jumps to the bottom and resumes following, wherever the user was.
- Streaming: at stream start the streaming row is clipped to `max(160, viewportHeight - 40)`. Once the reply fills one viewport, content stops growing, so the reply's first line rests near the top and the tail accumulates under the clip. A 48pt gradient fade (`theme.chrome` 0 to 1 alpha, top to bottom) sits over the clip's bottom edge while the clip is actually cutting.
- Stream end: clip releases; nothing re-pins. After 120ms the view scrolls the last assistant message's top into view; after another 250ms following resumes if within 32pt of the bottom. A short reply just lands at the bottom and keeps following.
- Jump-to-latest button: appears when more than 240pt from the bottom. 32x32 circle, `arrow.down` 13pt semibold, interactive regular glass, positioned centered 44pt above the bottom bar. Tooltip "Jump to the latest message". Appears with opacity + scale 0.8 transition. Click resumes following and animates (`.snappy`) to bottom.

### Rows in the transcript

- `MessageRow` for user, assistant, system, context roles (section 4).
- `CompressionSummaryCard` for `compressionSummary` role, unless that message is being edited (then MessageRow renders its inline editor).
- `PendingAreaMac`: optimistic sending bubble and queued bubbles (section 5).
- `CompactingRow` while compaction streams, or `StreamingRow` while a reply streams (section 6).

---

## 4. Message row (`MessageRow`)

Row frame: full width, trailing-aligned for user, leading-aligned otherwise. VStack spacing 2 of the content then the action row (action row hidden on drafts and while editing). Whole row hover-tracked (drives action visibility).

### 4.1 Shapes by role and state

| Case | Shape |
|---|---|
| User, not errored, not editing | **User bubble**: hugs text width up to 80% of column; padding 14 h / 10 v; corner radius 16; fill = chrome + bubbleTint at 0.24; stroke `primary.opacity(0.06)`. Right-aligned. |
| Assistant, not errored, not editing | **Bare page content**, no bubble, full width; wrapped in persona rail if it has a persona slot. |
| System or context, collapsed (default) | **Collapsed strip** (see 4.2) |
| Errored (any role), editing, or expanded system/context | **Framed bubble**: padding 12, corner 12, full width. Fill: editing `accent.opacity(0.10)`; errored `orange.opacity(0.10)`; else `primary.opacity(0.04)`. Stroke: editing `accent.opacity(0.6)` 1.5pt; errored `orange.opacity(0.55)` 1.5pt; else `primary.opacity(0.06)` 1pt. |

### 4.2 Collapsed system/context strip

A full-width plain button: HStack spacing 10 of icon (`gearshape` for system, `tray.full` for context; caption, secondary), role label ("SYSTEM"/"CONTEXT", caption2 semibold, secondary), preview line (first non-empty line with a leading `# `, `## `, `### `, `- `, `* `, `> ` stripped; "(empty)" if blank; caption, tertiary, 1 line tail-truncated), spacer, `chevron.down` (caption2, tertiary). Padding 12 h / 8 v; corner 10; fill `primary.opacity(0.04)`, stroke 0.06. Tooltip "Show the system message" / "Show the context message". Click expands (row becomes a framed bubble). Has the message context menu.

### 4.3 Inner content stack (VStack spacing 6, top to bottom)

1. **Header row** (only when it has content): HStack spacing 6.
   - Errored: `exclamationmark.triangle.fill` orange, small.
   - Expanded framing row: a fold button "SYSTEM ⌃" / "CONTEXT ⌃" (role label + `chevron.up` small, caption2 semibold, secondary), tooltip "Fold the system message".
   - Else persona label when the message has a persona slot and name and is not errored (`PersonaLabel`, section 4.6).
   - Else role label ("USER", "ASSISTANT", "SUMMARY", "?") when turn details are on, or the row is errored: caption2, regular (semibold orange when errored), secondary.
   - "FAILED" caption2 semibold orange, when errored.
   - "edited" caption2 tertiary, when `editedAt` set.
   - Model label (assistant only, when turn details on OR this reply's model differs from the previous reply's): spacer then `Label("<Provider> <Model>", icon)`, caption2, tertiary, 1 line middle-truncated. Icon `arrow.triangle.swap` when it is a model-change marker with details off, otherwise `cpu`. Tooltip "This reply came from a different model than the one before it" for a change, else the label. The first answering model is never a "change".
2. **Thinking disclosure** (assistant with reasoning; section 7.1). Settled phase, duration from `thinkingDurationMs`.
3. **Tool call disclosures** (assistant; one per tool call; section 7.2 settled).
4. **Image attachments**: horizontal scroll strip, spacing 6, of 140x140 thumbnails (section 8).
5. **Non-image attachments**: horizontal scroll strip, spacing 6, of file chips (section 8).
6. **Body**, one of:
   - Inline editor (section 4.8).
   - Errored body (4.5).
   - UI fragments (plugin components; section 10) when `uiFragments` non-empty.
   - Markdown body (4.4).
7. **Details footer** (when "Show turn details" is on, not editing): HStack spacing 6, caption2 monospaced digits, tertiary. Left: assistant usage summary "in 12,345 (10,000 cached) · cache write 2,000 · out 456 · $0.0123" (1 line, middle truncation). Right: timestamp "3:47 PM" today, "Yesterday 3:47 PM", or "Apr 2 · 3:47 PM".

### 4.4 Markdown body

- Empty body: "(empty)" secondary.
- Selection mode for this message: `SelectableMessageText` (AppKit text view; section 4.9).
- Welcome message (`isWelcome`) not yet played this session: `WelcomeReveal` types out word by word at 30 words/sec, then marks itself played.
- Otherwise `BoundedMarkdownText`: renders in full up to 48,000 characters (chunked at ~4,000 char paragraph boundaries for performance). Past the limit: a head preview plus a small bordered button `Label("Show full text (48 KB)", systemImage: "doc.text.magnifyingglass")` caption, which opens the **Full text sheet** (`MarkdownDocumentView`: NavigationStack, title "Full text", lazy chunked markdown, selectable, "Done" confirmation button; min 560x640).
- Markdown theme `clarkChat`: primary text; headings semibold at 1.5 / 1.3 / 1.15 em for h1 to h3, body size h4 to h6, 1em top margin; inline code monospaced 0.92em with `secondary.opacity(0.18)` background; code blocks monospaced 0.88em, padding 10, `secondary.opacity(0.12)` fill, corner 6, own horizontal scroller (no wrap), 0.5em margins; blockquotes secondary text, 11pt leading inset, 3pt `secondary` bar; tables in their own horizontal scroller.
- Per-paragraph SwiftUI selection is turned off; drag anywhere on the body enters selection mode instead (4.9).

### 4.5 Errored body

VStack spacing 8:
- Error text: callout, red, selectable.
- If partial content exists: `DisclosureGroup` labeled "Partial output streamed before failure" (caption, secondary), expands to the partial markdown (callout, secondary, top 4).
- Assistant only: trailing "Retry" button `Label("Retry", systemImage: "arrow.clockwise")`, glass prominent, small. Disabled while streaming or sending. Tooltip "Run this turn again. The retry is a new branch; the failed turn stays." Action: regenerate from this message.

### 4.6 Persona (council mode)

- `PersonaLabel`: 7pt dot in `personaColor(slot)` plus name in caption semibold of the same color, 1 line. The name collapses (dot only) when the previous message has the same role and the same persona. Accessibility "Said by <name>".
- `PersonaRail`: assistant body is placed in an HStack (top aligned, spacing 8) with a 3pt wide rounded (1.5) rail in `personaColor(slot)` at 0.55 alpha on the left. No rail when there is no persona.
- "Continue the discussion" chip above the composer (section 9.1) when the last message is a persona reply.

### 4.7 Action row

Height fixed at 24pt (hover never moves layout). Horizontal padding 4 for user rows. Fades actions in/out over 0.12s ease-in-out.

- User rows: [actions][branch switcher], trailing-aligned under the bubble.
- Other rows: [branch switcher][actions] spacer [signals].

Actions are visible when: hovering the row, OR it is the latest assistant reply (and not streaming), OR it is being read aloud, OR it is in selection mode, OR its usage popover is open, OR "Copied" feedback is showing. Hidden actions are also non-hit-testable. Signals and branch switcher are always visible.

**Action icons** (`ActionIcon`: 24x22 frame, SF Symbol 12pt medium, plain; hover wash `primary.opacity(0.08)` rounded 6; foreground secondary, tint when given, quaternary when disabled):

| Icon | Shown for | Tooltip | Effect |
|---|---|---|---|
| `doc.on.doc`, becomes `checkmark` for 1.4s | all | "Copy" | copies body text (display content) to clipboard |
| `speaker.wave.2` / `speaker.slash` (accent tint while speaking) | assistant, not errored | "Read aloud" / "Stop reading aloud" | toggles TTS playback of this message |
| `arrow.clockwise` | non-user | "Regenerate from here (a new branch)" | regenerate; disabled when not an editable role or while streaming |
| `character.cursor.ibeam` (accent tint) | only in selection mode | "Done selecting" | exits selection mode |
| `ellipsis` menu (24x22, 12pt medium, no indicator) | all | "More" | opens More menu |

**More menu** (`ellipsis`), items in order:
- "Select Text" / "Done Selecting" (only when selectable: not errored, no UI fragments, non-empty body).
- "Edit…" (user, assistant, system, context).
- "Usage and Cost…" (assistant with usage or model id): opens the **Usage popover** anchored below the ellipsis (section 4.10).
- Divider, "Delete…" destructive (editable roles): opens delete confirmation.

**Branch switcher** (when the message has siblings): capsule `primary.opacity(0.06)`, padding 8 h / 3 v, HStack spacing 4: `chevron.left` button (caption2 semibold, tooltip "Previous branch"), "2/3" (caption2 monospaced, secondary), `chevron.right` button ("Next branch"). Wraps around at both ends. Switches the visible branch.

**Signals** (non-user rows):
- Cache dot (turn details off; assistant; provider reports cache fields; prompt at least 4,096 tokens; not the conversation's first metered reply when it has zero cache reads): 7pt circle plus "94% cached" caption2 tertiary. Green at 80% or more ("Excellent cache hit: N% of the prompt served from cache"), yellow 30 to 79% ("Partial cache hit…"), red below 30% ("Poor cache hit…").
- Stop reason (assistant, finish reason not stop/end_turn/tool_use/tool_calls): "Stopped: max tokens" (caption2, orange, 1 line). This is the "stopped" state.

### 4.8 Inline editor (edit mode)

Replaces the body inside a framed bubble with accent fill/stroke. Opened from "Edit…" (More menu or context menu). Exits selection mode on entry. Action row hidden while editing.

- Role picker (user and assistant rows only): segmented "User" | "Assistant", labels hidden, max width 220.
- `TextEditor`: body font, min height 100, padding 8, fill `primary.opacity(0.04)`, separator stroke, corner 6. Prefilled with the message content.
- Buttons row (trailing, spacing 8):
  - "Cancel" (Escape). Ends editing.
  - "Save" glass button. Disabled when trimmed text is empty. Saves content (and role for user/assistant).
  - "Save and Resend" glass prominent, default action (Return), only for user/assistant. Disabled when empty or while streaming. Tooltip "Save the edit and send it again as a new branch beside the original." Effect: user role forks a new sibling user turn under the original's parent; assistant role saves in place then chains a new reply after it.
- System/context rows: content-only save (no role picker, no resend).

### 4.9 Selection mode

- Enter: "Select Text" in More menu or context menu, or drag on a message body (first drag movement swaps to the AppKit text view and the drag continues as its selection).
- Body becomes `SelectableMessageText`: one NSTextView holding the whole message as an attributed string (system font at base size × scale, headings semibold scaled like the markdown theme, monospaced code 0.92 with 0.12 to 0.18 alpha background, secondary color for quotes), so any range selects, double/triple-click work, ⌘A / ⌘C work.
- Exit: Escape, clicking elsewhere (text view loses focus, e.g. into the composer), "Done selecting" icon, or the menu item. Switching or re-entering a conversation clears it. Only one message at a time (`selectingTextMessageID`).
- Compression summary cards support the same mode; their exit is a small bordered "Done selecting" button in the card header.

### 4.10 Usage popover (`MessageUsagePopover`)

Popover with arrow at the bottom edge of the ellipsis button. Padding 14, min width 280, section spacing 14. Section titles caption, secondary, uppercase; rows callout: label secondary left, value right (secondary, or primary semibold for bold rows).

- MODEL: Model (display name or raw id), Provider (label or id).
- TOKENS: Input, Output, Cache read, Cache write, Reasoning (each when present).
- CACHE (when cache reads > 0 or explicit-cache flag present): Cache read; Cache write (if > 0); "Explicit cache" = "Attached" or "Enabled — not attached this turn", or "Source" = "Implicit (provider-side)"; "Estimated savings" bold (cache reads × input price × 0.9 Anthropic or 0.5 others).
- COST (USD): Input, Output, Cache read, Cache write, Tools, Total (bold). Currency with 6 decimals.

### 4.11 Message context menu (right-click)

On user bubble, assistant content, framed bubbles and collapsed strips. Not on drafts.
- "Copy"
- "Select Text" / "Done Selecting" (disabled when not selectable)
- "Edit…" (disabled for non-editable roles)
- "Regenerate From Here" (disabled for user rows, non-editable roles, or while streaming)
- Divider
- "Delete…" destructive (disabled for non-editable roles)

### 4.12 Confirmations owned by the row

- **Delete message** (confirmation dialog, title visible): "Delete message?" / message "This message is removed from the conversation. Its replies attach to the message before it." / buttons "Delete" (destructive), implicit Cancel.
- **Fork choice** (confirmation dialog): "Submit choice on an earlier message?" / "This forks the conversation from this message and sends your choice as a new branch. The current branch stays as it is." / "Fork & Send", "Cancel". Triggered by a `send:` choice in a UI fragment on a message that is not the latest assistant reply.

---

## 5. Pending and queued rows

`PendingAreaMac`, drawn exactly like the user bubble it becomes (same hugging width, padding 14/10, corner 16, themed fill), at 0.7 opacity, right-aligned. Under it a 24pt-tall row (padding h 4): optional badge then a mini spinner.

- Sending: the optimistic text (`pendingUserText`), no badge, mini spinner.
- Queued offline: one bubble per queued outbound entry, badge "Queued" (caption2 medium, orange), mini spinner. Failed sends that look like network blips are queued and sent when the server returns. Non-transient failures restore the draft text and attachments and show the load-error banner.

---

## 6. Streaming and compacting rows

### StreamingRow (assistant reply in flight)

Bare (no bubble), full width, so the swap to the settled row at terminal is invisible. VStack spacing 4:
- Header: "ASSISTANT" caption2 secondary + mini spinner.
- Thinking disclosure, ticking or settled (7.1), expansion state survives into the settled row.
- One live tool pill per tool call (7.2). On Mac these are non-interactive (no expansion binding passed).
- Text: if empty and nothing else is visible, "…" secondary. Otherwise streamed markdown (chunked), body font. When the pipeline declares streaming component tags, closed `<tag>{json}</tag>` blocks render live as UI fragments; a `text` component folds into prose; an unclosed tag or invalid JSON shows "…" until complete.
- Clipped and faded per the scroll rules (section 3).

StreamingRow also has a compression variant (orange "Compression summary" header + spinner, card chrome) not used by the Mac transcript, which uses CompactingRow instead.

### CompactingRow (compression summary streaming)

Padding 10, fill `orange.opacity(0.07)`, stroke `orange.opacity(0.3)`, corner 8. Header HStack spacing 6: `wand.and.stars` orange, "COMPACTING" caption2 semibold orange, mini spinner. Body: "Summarizing conversation…" callout secondary when empty, else live chunked markdown in callout.

---

## 7. Disclosures

### 7.1 ThinkingDisclosure

Pill: HStack spacing 6, padding 8 h / 4 v, capsule fill `primary.opacity(0.05)`, stroke `primary.opacity(0.08)` 0.5pt.
- Icon caption: `brain` while ticking, `brain.head.profile` settled; secondary.
- Label caption medium, secondary, monospaced digits: "Thinking… (3.2s)" (updates every 0.1s), "Thought for 12.4s", or "Thought" when the duration is unknown.
- Chevron 9pt semibold tertiary: `chevron.right` collapsed, `chevron.down` expanded. Only when there is text to show; otherwise the pill is a disabled, static badge (model reasoned but provider gave no text).
- Ticking pill has a gentle repeating pulse (0.9s ease-in-out).
- Expanded body: scroll area max height 220; reasoning text callout secondary selectable, leading inset 10, 3pt `primary.opacity(0.18)` bar. Toggle animates 0.15s.

### 7.2 Tool calls

Pill chrome identical to thinking (capsule, 8/4 padding, 0.05 fill, 0.08 stroke). Icon and label caption; label medium, monospaced digits.

Live pill (streaming), three phases, timer updates every 0.1s:
- Generating args: `wrench.and.screwdriver`, "Using <tool> (1.2s)".
- Executing: `gearshape.2`, "Processing <tool> result (0.8s)".
- Done: `checkmark`, "Used <tool> (2.0s)"; or error `exclamationmark.triangle`, "<tool> failed (2.0s)", orange icon and label.

Settled disclosure (history): a button pill with the done label and chevron; expands to a scroll area max height 260 with a 3pt bar, sections "INPUT" and "OUTPUT" (or "ERROR" in orange): titles caption2 semibold tertiary uppercase, bodies caption monospaced secondary selectable, pretty-printed sorted JSON, "(empty)" for empty. Expansion keyed per message+index and remembered on the view model.

Tool calls include device tools (calendar, reminders, files) run on the Mac. Their only in-conversation UI is these pills; first use may raise the OS's own EventKit permission prompt.

---

## 8. Attachments

### On sent messages

- **Image thumbnail** (`MessageAttachmentImageMac`): 140x140, aspect fill, corner 10, stroke `primary.opacity(0.08)` 0.5pt. States: loading/no URL placeholder (`photo` title2 tertiary on `primary.opacity(0.05)`), failed (`exclamationmark.triangle`), loaded image (fades in 0.15s). Signed URL minted on first appear. Click opens the lightbox (only when loaded).
- **Lightbox sheet** (`MessageAttachmentLightboxMac`): black background, scrollable both axes, image fit within 760x560; double-click toggles 2x zoom (0.18s). Failure: `exclamationmark.triangle.fill` largeTitle orange + "Couldn't load image" callout white 80%. Loading: large white spinner. Close button top-right: `xmark.circle.fill` title size, white on black 40%, padding 12, Escape, tooltip "Close". Sheet min 480x360, ideal 800x600.
- **File chip** (`MessageAttachmentChipMac`): HStack spacing 8: icon title3 secondary (`doc.richtext` document, `waveform` audio, `film` video, `doc` other); filename caption 1 line middle-truncated (fallback "Document"/"Audio"/"Video"/"File"); size caption2 tertiary (e.g. "1.2 MB"). Padding 10 h / 6 v, fill `primary.opacity(0.05)`, stroke 0.08 0.5pt, corner 8, max width 240. Informational, not clickable.

### Pending, in the composer

Horizontal strip (no indicators), spacing 8, padding h 14 / top 8, above the composer island.
- Image chip: 56x56 thumbnail, corner 8, stroke 0.08 0.5pt.
- File chip: `doc.richtext` (PDF) or `doc` secondary + filename caption (middle-truncated), height 56, max width 180, padding h 10, fill 0.05, corner 8.
- Remove button on each chip: `xmark.circle.fill` 14pt, white on black 55%, offset (+5, -5) at the top-right corner, tooltip "Remove attachment".
- Upload in progress chip: small spinner + "Uploading…" caption secondary, padding 10/6, fill 0.05, corner 8.

### Attach entry points and rules

- Paperclip button (composer), file importer (multiple selection), drag-and-drop on the transcript, ⌘V with file URLs or image data on the pasteboard (files win over image data; image data normalized to PNG). Images are resized/thumbnailed before upload; other files upload as-is.
- Accepted types by provider type: Anthropic images + PDF; Google images + PDF + audio + video; OpenAI-compatible images only; others none. Harness-bound conversations whose harness refuses attachments accept none.

---

## 9. Composer and bottom bar

### Bottom bar selection

1. Archived conversation: `ArchivedBarMac` (9.4).
2. A clean compression summary awaiting review: `CompressionReviewBar` (section 13.3).
3. Otherwise the composer.

On the draft start screen, banners and composer sit inside the start screen instead (max width 760).

### 9.1 Continue chip

Only when the last message is a persona (council) reply and nothing is busy. Borderless button, `Label("Continue the discussion", systemImage: "arrow.turn.down.right")` caption, secondary, leading-aligned, horizontal padding 20. Disabled offline. Asks the server for the next speaker (no model is sent).

### 9.2 Composer island

VStack spacing 6: continue chip, pending attachment strip, then one glass island: `GlassEffectContainer(spacing 8)` with a VStack spacing 6 using `.glassEffect(.regular, in: rect(cornerRadius 22))`. Outer padding h 16, bottom 14.

- **Text input** (`ComposerTextView`, AppKit NSTextView in a scroll view): plain text, body system font × text scale, grows from one line up to 10 lines then scrolls (overlay scrollers, caret kept visible). Padding h 14, top 12. No smart quotes/dashes/replacements; continuous spell check on; undo. Takes key focus on entry and on every conversation switch, once per request (never steals focus back from a selection). Editable only when the composer is enabled; disabled text color is secondary label.
- **Placeholder** (overlay, top-leading, body, `placeholderTextColor`): "Choose a profile to start" (draft with no profile), "Message <Profile name>", or "Message".
- **Footer row** (HStack spacing 8, padding h 8, bottom 8): paperclip button, hint text, spacer, send/stop button.
  - Paperclip: `paperclip` callout in a 26x26 circle hit area, plain. Secondary when attachable, tertiary and disabled otherwise. Tooltips: "Attach files — or drop them on the composer"; "Attachments not supported by this model"; "<Harness provider> cannot receive attachments".
  - Hint: "Return to send · ⇧Return for a new line" caption tertiary, 1 line.
  - Send / Stop / Resend button (glass prominent), see 9.3.

Composer enabled unless: sending, a compression awaits review, compacting, or the draft is being created. Additionally disabled for a draft with no profile.

### 9.3 Send button states

| State | Look | Shortcut | Tooltip | Effect / disabled rule |
|---|---|---|---|---|
| Streaming | `stop.fill`, red tint | ⌘. | "Stop (⌘.)" | cancels the stream |
| Resend (draft empty, last message is a user turn, not a draft conversation) | `arrow.clockwise`, spinner while sending | ⌘Return | "Send your last message again (a new branch)" | re-sends the trailing user turn; disabled while sending, pending compression, compacting |
| Send | `arrow.up` semibold; small spinner while sending or creating the conversation | ⌘Return | "Send (Return)" | disabled when no text and no attachments, an upload is in flight, streaming/sending/compacting/pending review/creating, or a draft has no profile |

Keyboard in the text view: Return and keypad Enter submit (only if sending is allowed); Shift-, Option- and Control-Return insert a real newline at the caret; ⌘V attaches files/images when present, otherwise pastes text. The text view registers no drag types of its own (drops go to the transcript drop target).

Attachment-only sends are allowed.

### 9.4 Archived bar (`ArchivedBarMac`)

HStack spacing 10, padding 16 h / 10 v, `.thinMaterial` background, then outer padding h 16 / bottom 12. `archivebox` secondary; "Archived" callout semibold over the archive date (caption2 secondary); spacer; "Unarchive" glass prominent small button (unarchives; the composer returns). The transcript stays readable; the server refuses writes.

### 9.5 Drafts (unsent text)

Per-conversation draft text is restored from `DraftStore` (UserDefaults) when the view model is created and cleared on a successful send. On the Mac, the store is written only when a send fails non-transiently (iOS writes on every keystroke). Typed text otherwise lives on the view model for the life of the screen.

No slash commands or @mentions exist in the Mac composer.

### 9.6 Banners (`InlineBanner`)

Stacked above the bottom bar (spacing 6). Each: HStack top-aligned spacing 8: icon orange, text caption (wrapping, selectable), spacer, optional dismiss `xmark` (caption2 semibold, secondary, tooltip "Dismiss"). Padding 12 h / 8 v, fill `orange.opacity(0.12)`, corner 10, outer padding h 16.

In order:
1. Compression failed: `exclamationmark.triangle.fill`, "Compression failed: <error>", dismissible.
2. Load/send error with messages present: `exclamationmark.triangle.fill`, error text, dismissible.
3. Speech playback error: `speaker.slash.fill`, error, dismissible.
4. Offline: `wifi.exclamationmark`, "Server unreachable. Messages queue and send when it's back.", not dismissible.

---

## 10. UI fragments (plugin components in a message)

`FragmentView` renders `message.uiFragments` instead of the markdown body (VStack spacing 8). Components:

| component | Rendering |
|---|---|
| `text` | markdown |
| `choice_list` (used by the lettered-choices plugin) | VStack spacing 6 of full-width glass buttons, label leading, padding 12 h / 6 v. Items without a parseable action render as plain text rows. |
| `card_list` | cards: padding 10, regularMaterial, corner 8; title callout semibold (2 lines); optional `arrow.up.right.square` external-link button (tooltip = URL); badges caption2 in material capsules (padding 6/2); description caption secondary (4 lines). Card is a button when it has an action. |
| `key_value` | padding 10, regularMaterial, corner 8; rows: key callout medium secondary (min width 100), value callout selectable |
| `image` | async image, fit, corner 6; spinner (min height 80) while loading; alt text on failure; caption caption2 tertiary |
| `image_grid` | adaptive grid min 140, spacing 6; cells fill, height 100 to 160, corner 6, gray 0.1 placeholder with spinner |
| `error` | `exclamationmark.triangle.fill` orange + message selectable + optional code chip (caption monospaced in material capsule); padding 10, `orange.opacity(0.08)`, corner 8 |
| `raw_json` | pretty JSON callout monospaced, horizontal scroll, padding 10, regularMaterial, corner 8 |
| unknown | "Unknown component: <name>" caption secondary + raw JSON |

Action strings: `compose:<text>` appends the text to the composer draft (newline-separated); `send:<text>` sends immediately when on the latest reply, otherwise opens the Fork & Send confirmation (4.12); `external:<url>` opens in the browser; `plugin:` is ignored in the transcript.

Rows with fragments are not text-selectable.

---

## 11. Elicitation sheet (MCP input request)

`ElicitSheet`, presented as a sheet over the conversation whenever the active stream has a pending elicitation. Padding 20, max width 480, spacing 16.

- Header: `key.fill` in tint (accent) + "Psmith needs input" headline; request message callout secondary.
- Fields from the JSON schema, sorted by name, spacing 12. Each: label (snake_case to Title Case, caption medium) + "required" caption2 tertiary; control: SecureField for `format: password`, rounded TextField for string and integer/number, switch Toggle for boolean; description caption2 tertiary.
- Inline error caption red.
- Footer: "Cancel" (bordered), "Decline" (bordered), spacer, "Submit" (bordered prominent, semibold; spinner while working). Submit disabled while working or until required text fields are non-empty. Cancel and Decline also send responses ("cancel" vs "decline") to the server. A not-found response (already expired) dismisses silently.

---

## 12. Model picker sheet

`ModelPickerSheet`, from the model menu's "All Models…". 680x620. Body `ConversationModelPicker` (scroll, padding h 14 / top 12 / bottom 24, plus 28 top inset), footer divider + trailing "Done" (default action), padding 12.

- Header label: "N MODELS ACROSS M PROVIDERS" caption semibold tertiary uppercase.
- `ModelPickerList`: optional harness notice band (`lock` caption tertiary + text caption secondary, padding 10/8, `accent.opacity(0.07)`, corner 10); one section per provider sorted by label: provider logo 18pt + label subheadline semibold secondary; rows spacing 6.
- Row (`PickerModelRow`): button, padding 12/10, corner 8. Name (semibold when selected) + `checkmark.circle.fill` accent when selected; `ModelMetaStrip` below; "Needs: vision, tool use" caption2 orange when the active profile requires capabilities the model lacks (row disabled, 0.55 opacity, tooltip "This model lacks: …"). Fill `accent.opacity(0.10)` selected else `primary.opacity(0.025)`; stroke accent 0.4 at 1.5pt selected else separator 0.5pt.
- `ModelMetaStrip` (clickable, opens a **Model detail popover**): chips caption2 in capsules with 0.12 fill, padding 5/2: context window "200K"; cost bucket "$" to "$$$$" in orange (by output price per M: <3, <15, <50, else); knowledge cutoff; capability icons caption2: `brain` purple (thinking), `eye` blue (vision), `wrench.adjustable` teal (tool use), `tray.full` green (prompt caching). Each chip has a tooltip.
- Model detail popover sections: MODEL (Name, ID, Provider); LIMITS (Context window, Max output); PRICING (USD per 1M tokens) (Input, Output, Cache read, Cache write); CAPABILITIES (icon rows: Streaming `waveform`, Thinking, Vision, Tool use, Prompt caching, each with a one-line description); MODALITIES; KNOWLEDGE (Cutoff).
- Selecting a row sets the conversation's model and closes the sheet.

Empty state: "No models available", `cpu`, "Configure a provider in Settings to enable models."

---

## 13. Compression flow

### 13.1 Entry

Inspector Context tab button "Compress into a New Context…" (section 16.1) or the red/orange context chip (opens the Context tab first). Opens the compress sheet.

### 13.2 Compress sheet (`CompressSheet` with `CompactPane` body)

620x640 sheet. Body scrolls, padding 28 h / 24 v, max width 760, spacing 24:

- Summary header: "N messages will be summarized." callout; "Current: 120,000 / 200,000 tokens (60%)." caption secondary (when known); "You'll review the summary before it replaces the active context." caption2 tertiary.
- PROMPT section: label caption semibold secondary uppercase; helper "System prompt sent to the compression model. Pre-filled from the profile; this edit is per-call only." caption2 tertiary; TextEditor callout, padding 10, `primary.opacity(0.04)`, separator stroke, corner 8, height 140 to 280. Prefilled with the profile's compression guide.
- COMPRESSION MODEL section: helper "Used to write the summary. Pre-selected from the profile; pick another enabled model to override for this run."
  - Collapsed pill (default): max width 440, padding 12/8, interactive glass corner 10. `cpu` (or orange `exclamationmark.triangle` when not found) + model name callout / provider caption2 secondary; or "Model not found" with "Profile points at "<id>", which isn't enabled. Pick another to continue." / "No model resolved from the profile. Pick one to continue."; trailing "Change" glass button. Clicking the pill or Change expands the list.
  - Expanded list: "Filter models" rounded text field (only when more than 6 models; max width 440); scroll (max height 320 when more than 6); group headers (FAVORITES, then provider names, caption2 semibold tertiary uppercase); rows: interactive glass corner 10 (accent 0.18 tint when selected), `cpu` + name callout + optional provider caption2, trailing `checkmark` semibold in tint when selected, plus a separate 32x32 star button (`star` / `star.fill` yellow, 12pt semibold, tooltip "Mark as favorite" / "Unfavorite") that toggles the model's favorite. Empty states: "No models match "<query>"", "No enabled models. Enable one in Settings → Providers first."
- "Last attempt: <error>" callout red when a previous compaction failed.
- Footer (divider, padding 16): "You review the summary before the new context starts." callout secondary; "Cancel" (Escape); "Compress" (Return), disabled unless prompt is non-empty and the chosen model is enabled, and not compacting/sending. Compress dismisses the sheet and starts streaming into the transcript (CompactingRow).

### 13.3 Review (after a clean summary lands)

- **CompressionSummaryCard** in the transcript (success variant): padding 12, regularMaterial over `orange.opacity(0.08)`, stroke `orange.opacity(0.35)` 1.5pt, corner 10, spacing 10. Header: `wand.and.stars` orange + "Compression summary" caption semibold orange; spacer; "Truncated" `scissors` label caption2 semibold red (when output was cut); model label caption2 tertiary; "Done selecting" small bordered button in selection mode. Body: bounded markdown callout with a 1,500 character preview limit and "Show full text (size)" opening the full-text sheet titled "Compression summary". Truncation warning: "Cut off at the model's output limit — the tail of the summary is missing. Delete and re-run compaction rather than confirming." caption red. Usage line caption2 tertiary: "in: 12,345 (1,000 cached) · cw: 2,000 · out: 1,234 · $0.0123".
- Card context menu: "Edit" (`pencil`, opens inline editor via MessageRow), "Copy" (`doc.on.doc`), "Select Text"/"Done Selecting" (`character.cursor.ibeam`), divider, "Delete" (`trash`, destructive). Custom context-menu preview: header + first 600 chars of markdown, max width 340, padding 12.
- **CompressionReviewBar** replaces the composer (Mac layout): HStack spacing 12, padding 14 h / 10 v, thinMaterial, top divider with a 1pt `orange.opacity(0.5)` hairline. `wand.and.stars` orange; title subheadline semibold "Compression awaiting review" or "Truncated summary awaiting review"; subtext caption, wrapping: "Confirm to continue in a fresh context, or delete to resume here." (secondary) or "The summary hit the model's output limit and is incomplete. Delete and re-run compaction; confirming keeps the cut text." (red). Buttons: "Delete" bordered red tint (opens confirmation); "Confirm" glass prominent orange tint, min width 64, spinner while promoting, tooltip "Confirm the summary, open a fresh context, and continue from there". Both disabled while promoting.
- Sends, regenerate-safe actions and further compactions are blocked while a summary awaits review.

### 13.4 Failure

- **CompressionSummaryCard** (failure variant): header `exclamationmark.triangle.fill` + "Compression failed", stroke 0.55; error text callout red selectable; disclosure "Partial summary streamed before failure" (bounded preview, title "Partial summary"). Buttons trailing: "Dismiss" borderless secondary (deletes the failed card; tooltip "Remove this failed compaction from the history. You can retry compaction at any time."), "Retry" `arrow.clockwise` glass prominent (re-runs with profile defaults; disabled while compacting/sending/streaming; tooltip "Re-fire compaction with the current profile defaults. The failed summary stays in history until dismissed."). A failed summary does not block the conversation.
- Plus the "Compression failed: …" banner (9.6).

### 13.5 Confirmations

- "Delete compression summary?" / "The conversation will resume in the current context as if compaction never happened." / "Delete summary" destructive. Same dialog from the review bar's Delete and the card's context-menu Delete.

### 13.6 ContextListPane (legacy full-pane contexts list)

Defined in `ContextListView.swift` and snapshot-tested, but no Mac code path presents it now: `showingContextList` is intercepted and redirected to the inspector's Context tab. Contents for reference: section label "N CONTEXTS"; newest-first `ContextRow`s (interactive glass corner 12, accent 0.18 tint when active; `checkmark.circle.fill` tint or `tray.full`; "3. Title" headline 2 lines; "parent: 2. Title" caption2; "Active" caption2 semibold tint; trailing checkmark; metadata chips in a flow layout, each glass capsule caption2 secondary: `calendar` "Created Apr 2, 26", `clock.arrow.circlepath` "Updated …", `bubble.left` "12 msgs", `text.word.spacing` "45,000 tok", `dollarsign.circle` "$0.1234"); hover-revealed red `trash` 26pt glass circle on non-active rows (tooltip "Delete context and all of its messages"); confirmation "Delete this context?" / "Every message in this context is permanently deleted. This can't be undone." / "Delete Context and Messages", "Cancel". Empty state "No contexts yet", `tray`, "Contexts appear after the conversation starts. Compacting also creates new contexts."

---

## 14. Draft new conversation (start screen)

`DraftStartView`, shown until the first user message exists. Scroll view, centered anchor; content VStack spacing 26, padding 32 h / 40 v. TitleBand overlay on top. Toolbar title "New Conversation"; model menu present; no context chip, no inspector button.

- Heading: "Who are you talking to?" title bold; "A profile sets the system message, the model and the plugins. Nothing is saved until you send." callout secondary centered.
- Profile grid: adaptive columns 220 to 280, spacing 12, max width 860. Order: default first, then favorites, then name. Parent-only profiles excluded.
  - Card (plain button): padding 14, min height 96, corner 14. Header HStack spacing 6: 8pt `ProfileColor` dot, name headline 1 line, spacer, "Default" caption2 semibold (accent when selected, secondary otherwise) or yellow `star.fill` caption2 for favorites. Description callout secondary up to 3 lines, or "No description.". Fill `accent.opacity(0.16)` selected else `primary.opacity(0.04)`; stroke accent 1.5pt selected else `primary.opacity(0.08)` 1pt. Tooltip = description (or name). Clicking another card restarts the draft from that profile.
  - "New Profile…" tile: `plus` label, secondary, min height 96, dashed 1pt stroke (dash 4,4) `primary.opacity(0.12)`, corner 14. Opens Settings at Profiles.
- Below: banners + composer, max width 760. Placeholder "Choose a profile to start" until a profile is picked; composer disabled then.
- First send creates the conversation on the server (send button shows a spinner while creating), then the same screen becomes the transcript; the sidebar selects the new conversation. Choosing another sidebar conversation abandons the draft. Inspector never shows for a draft. Message action rows and context menus are suppressed while draft.

---

## 15. Welcome view (nothing selected)

`WelcomeView`, centered VStack spacing 14:
- `bubble.left.and.bubble.right` 40pt light, tertiary.
- "Welcome to Psmith" title3 semibold secondary.
- "Start a new conversation, or pick one from the sidebar." or, with no usable profiles, "Add a profile in Settings to start your first conversation." caption tertiary centered.
- "New Conversation" button, `plus.bubble`, glass prominent, padding 14 h / 6 v, top 4. Disabled with no usable profiles.

Distinct from the in-transcript "welcome message": an assistant message flagged `isWelcome` (seeded by the server/profile) that types itself out word by word at 30 words/sec the first time it is shown in a session (section 4.4).

---

## 16. Inspector (`ConversationInspector`)

Right column toggled by the toolbar button or ⌥⌘I. Width min 290, ideal 320, max 440. Top: segmented picker "Context | Settings | Plugins", labels hidden, padding 12 h / 10 v, divider.

### 16.1 Context tab (`ContextInspector`)

Scroll, padding 16, section spacing 22. Headings `.headline`.

1. **Context size**: "Context size" headline + trailing "12,345 tokens" callout semibold monospaced (tinted orange/red when warning). When the window is known: 8pt capsule bar (track `primary.opacity(0.08)`, fill accent, orange or red by warning; min 4pt), a 2x14pt primary tick at the user's threshold if below the window; caption secondary row "Your warning: 100k" (or "No warning set") / "Window: 200k". Button "Compress into a New Context…" `wand.and.stars`, large, full width, top 4; disabled while streaming, compacting, pending review, or empty. Opens the compress sheet.
2. **This context**: grid (h 12, v 6), callout: Cost "$0.1234" (server per-context total incl. all branches), Replies count, "Cache, last reply" "94% hit" (when known), Model changes count. Warning label (orange caption, `exclamationmark.triangle`): "No pricing for <models>, so the cost leaves those turns out."
3. **Context over this run** (2+ metered replies): line chart, height 110, accent line (monotone), dashed orange 0.7 rule at the warning threshold, ~4 x-axis marks, 3 leading y-axis marks in compact token form.
4. **Cost per reply** (if any priced): bar chart height 70, bars accent 0.75 or orange for cache misses on large prompts, x axis hidden, y axis "$0.01". Caption legend "Orange replies missed the cache on a large prompt." with a `circle.fill` icon.
5. **Branches** (when any message has siblings): rows "Message 7" / "2 of 3" (monospaced, secondary), callout. Display only.
6. **Contexts** (when any): header "Contexts" + count. Rows (plain buttons): padding 10/8, corner 8; fill accent 0.16 active else primary 0.04; stroke accent 0.45 when active. Title callout semibold ("Context N" fallback) + "active" caption secondary; subline caption secondary "12 messages · 45k · $0.12". Tooltip "The context you're in" / "Switch to this context". Click switches. Context menu: "Switch to This Context" (disabled if active), divider, "Delete Context…" destructive (disabled if active).
   - Confirmation: "Delete this context?" / "Its messages are removed. The other contexts are unchanged." / "Delete" destructive.

### 16.2 Settings tab (`CallSettingsSummary`)

Scroll, padding 16, spacing 14.
- Error label orange (callout) when settings failed to load. Spinner while preparing.
- "Call settings" headline, grid (h 10, v 8), callout: name secondary left; right column value (monospaced) over source caption2. Lines: Temperature, Top P, Max output, Top K, Thinking (effort label or Default), Explicit cache (On/Off), Stop sequences (count, only when any). Source: "this conversation" (tint/accent), "inherited" or "model" (tertiary); value "Default" when unset everywhere.
- Button "Edit Call Settings…" `slider.horizontal.3`, large, full width. Disabled only when settings failed and nothing is known.
- **Edit Call Settings sheet** (660x680): `ConversationSettingsView` embedded on Call Settings (16.4), footer divider + "Unset fields inherit from the profile, then the model." callout secondary + "Done" (default action), padding 14. Edits auto-save when the view disappears.

### 16.3 Plugins tab

`ConversationSettingsView` embedded on Plugins (16.4), padding 16 h / 12 v.

### 16.4 ConversationSettingsView (per-conversation overrides)

Only ever shown embedded (inspector Plugins tab, Edit Call Settings sheet). When not embedded it has its own tab bar ("Call Settings", "Plugins"; pills padding 12/6, corner 7, selected `accentColor.opacity(0.15)` fill and accent text), but nothing presents it that way now. Content max width 760, spacing 22; error label orange; spinner while preparing.

**Call Settings**:
- `HarnessBindingCard` first when the conversation is harness-bound: padding 12, `accent.opacity(0.07)` corner 12; `terminal` icon + provider label caption semibold in accent; explainer caption secondary; constraint rows (icon caption2 tertiary 14pt column, title caption medium, detail caption2 secondary): "Stays on this provider" (`arrow.left.arrow.right`), "System prompt is fixed" (`text.quote`, when frozen), "No attachments" (`paperclip`, when refused); footer "Start a new conversation to change any of this." caption2 tertiary.
- "Conversation overrides" headline + "Any field left unset inherits from the resolved profile (and below). Changes auto-save when you go back." caption secondary.
- `CallSettingsForm` (sections spacing 22), for the provider the next send will use:
  - Common: Temperature (slider with value readout, range per model constraints, Anthropic [0,1], otherwise [0,2]; locked models show "locked" and a disabled slider), Top P (slider), Max output tokens (stepper), Top K (stepper), Stop sequences (list of text fields with remove buttons, "Add stop sequence" `plus.circle`, "Inherits …" line).
  - Thinking: Effort picker ("Inherit (…)" plus each effort level), helper text; info note when the model lacks thinking.
  - Caching: "Explicit caching" tri-state toggle with long description.
  - Provider extras for the active driver only, or a segmented "Anthropic | OpenAI | Google" tab group under "PROVIDER EXTRAS" with caption "Applies to the currently selected model's provider." / "Saved, but only used when running on X.":
    - Anthropic: Prompt caching (Inherit / On / Off), Cache TTL (Inherit / 5 min / 1 hour).
    - OpenAI: Seed, Frequency penalty, Presence penalty, Top logprobs, Parallel tool calls (Inherit / On / Off), Service tier (Auto / Standard / Priority), Response format (Text / JSON object / JSON schema, with Schema name, Description, Strict toggle, Schema JSON editor), Logit bias JSON.
    - Google: safety thresholds for Harassment, Hate speech, Sexually explicit, Dangerous content (None / Low+ / Med+ / High), Response MIME type, Response schema JSON, Candidate count.
  - Every field shows its inherited value ("Inherit (…)", "(Inherited)", "—") and a reset button `arrow.counterclockwise` (18pt slot, tooltip "Reset to inherited (…)"). Disabled rows render at 0.45 opacity. Invalid JSON shows "Doesn't parse as JSON." with a warning icon.

**Plugins**:
- "Plugin pipeline" headline + caption secondary explainer ("Each row shows a plugin that's currently active for this conversation, with where it came from. Disable a row to subtract it from this conversation only — the profile chain stays intact for everyone else.").
- Empty: "No plugins are active for this conversation." callout secondary.
- Active row: padding 12/10, `secondary.opacity(0.06)` corner 8. Display name callout medium + source badge (caption2 semibold, padding 6/2, corner 4, color 0.18 fill): "Inherited" (secondary), "Conversation override" (accent), "Unknown". Plugin id caption2 tertiary below. Trailing small bordered button: "Disable here" for inherited rows, "Remove override" for conversation-sourced rows. Each persists immediately.
- Subtracted row: `orange.opacity(0.06)` fill; struck-through secondary name + "Disabled for this conversation" badge (orange 0.18 fill, orange text); "Restore" small bordered button.
- "Clear all conversation overrides" borderless destructive `arrow.uturn.backward` callout, after a divider, when any overrides exist.

---

## 17. Every modal, sheet, popover, alert, confirmation and menu

Sheets:
1. ElicitSheet (MCP input request): ConversationView.
2. CompressSheet (620x640): inspector Context tab, compress button.
3. ModelPickerSheet (680x620): model menu "All Models…".
4. Edit Call Settings sheet (660x680): inspector Settings tab.
5. Image lightbox sheet (min 480x360, ideal 800x600): clicking an image thumbnail.
6. Full text sheet (MarkdownDocumentView, min 560x640): "Show full text (size)" on long messages, compression summaries, partial summaries.

Popovers:
7. Usage and Cost popover: More menu "Usage and Cost…".
8. Model detail popover: clicking a ModelMetaStrip in the model picker sheet.

Confirmation dialogs:
9. "Delete message?" (message row).
10. "Submit choice on an earlier message?" (Fork & Send) (message row, fragment send action).
11. "Delete compression summary?" (review bar Delete, summary card Delete).
12. "Delete this context?" (inspector context row context menu).
13. "Delete this context?" with "Delete Context and Messages" (ContextListPane; currently unreachable).

Menus:
14. Toolbar model menu (Favorites, provider sections, All Models…).
15. Message More menu (`ellipsis`).
16. Message context menu (right-click).
17. Compression summary card context menu (with custom preview).
18. Inspector context row context menu.

Other modal-ish: system file importer (paperclip); OS permission prompts for device tools (calendar, reminders).

No alerts (`.alert`) exist in these surfaces.

---

## 18. Snapshot and event tests covering these surfaces

All in `clients/psmithd-mac/Tests/PsmithMacSnapshotTests/`. Snapshot images live in `__Snapshots__/<Suite>/<test>.<variant>.png`; most render two variants, `default` and `minColumn` (narrowest column).

ConversationViewSnapshots.swift: `empty`, `councilDiscussion`, `userAndAssistantPair`, `pendingCompressionReview`, `truncatedCompressionReview`, `longCompressionSummaryPreview`, `wideBlocksContained`, `longBullets`, `longBulletsScaled110`, `longBlockquotesScaled110`, `bulletsInBlockquote` (+ `scaled110` variant), `longAssistantMessageRendersInFull` (`tall`), `streamingLongText` (`tall`), `messageTextSelectionMode`, `compressionCardTextSelectionMode`, `composerGrowsWithDraft`, `composerCapsAtEightLinesAndScrolls`, `userAndAssistantPairScaled130`, `withThinkingEnabled`, `historicalToolCalls`, `liveStreamingToolCall`, `streaming`, `erroredStream`, `userMessageEditMode`, `compressSheet`, `inspectorSettings`, `inspectorContext`, `draftConversation`, `turnDetailsShown`, `contextChipNearTheModelsWindow`.

CompactViewSnapshots.swift: `defaultState`, `customCompressionModelPicked`, `running`.

ContextListViewSnapshots.swift (ContextListPane): `singleContext`, `multipleContextsWithParentChain`, `withCumulativeCosts`, `activatedContextHighlighted`.

ConversationSettingsViewSnapshots.swift: `noOverrides`, `temperatureOverride`, `thinkingOverride`, `anthropicProvider`, `openaiProvider`, `googleProvider`.

CallSettingsFormSnapshots.swift: `anthropicDriver`, `openaiCompatibleDriver`, `googleDriver`, `anthropicWithInheritedChips`, `capabilityGatedNoThinking`.

HarnessBindingCardSnapshots.swift: `allConstraints`, `longLabel`, `attachmentsAllowed`.

SelectableMessageTextSnapshots.swift: `rendersEveryBlockClass`, `rendererKeepsBlockStructure`, `rendererMarksOnlyTheFirstBlockOfAnItem`, `selectsBetweenPointsOnOneLine`, `selectsAcrossLinesInEitherDirection`, `pointsPastTheTextLandOnItsEnd`.

Event tests (real AppKit events, offscreen windows):
- SelectionModeTests.swift: `aDragAcrossParagraphsSelectsAcrossThem`, `escapeLeavesSelectionMode`, `clickingIntoTheComposerLeavesSelectionMode`, `typingInTheComposerDoesNotPullFocusOutOfASelection`.
- TranscriptScrollTests.swift: `entersAtTheNewestMessage`, `followsNewMessagesWhileAtTheBottom`, `aUserScrollLetsGoOfTheBottom`, `aLongReplyParksWithItsStartInView`, `theStreamEndingLeavesTheReplysStartInView`, `sendingCatchesUpFromAnywhere`.
- ComposerKeyTests.swift: `returnSubmitsAndLeavesTheDraftAlone`, `keypadEnterSubmits`, `shiftReturnInsertsANewline`, `shiftReturnInsertsAtTheCaret`, `optionReturnInsertsANewline`, `controlReturnInsertsANewlineNotALineSeparator`, `ordinaryTypingStillTypes`, `pasteIsSkippedWhenAnAttachmentWasTaken`, `keepsKeyFocusWhileSendingDisablesItAndTypesAgainAfter`, `registersNoDragTypesEvenAfterEditabilityChanges`, `aFocusRequestBeforeJoiningAWindowIsHonoredOnJoining`.
- ComposerTextViewTests.swift: `startsOneLineTallAndFullWidth`, `growsWhileTypingThenCapsAndScrolls`, `wrapsAtThePaneWidthAfterTheWindowGrows`, `wrapsAtThePaneWidthAfterTheWindowShrinks`, `clearingTheDraftShrinksBackToOneLine`, `takesKeyFocusWhenTheConversationOpens`, `keepsKeyFocusThroughASend`.
- WindowChromeTests.swift (popover/panel sizing, main window floor): `aPopoverKeepsItsOwnSize`, `aBorderlessPanelKeepsItsOwnSize`, `theMainWindowGetsItsFloorAndChrome`.

Related but outside this scope: WelcomeViewSnapshots, HomeViewSnapshots, ConversationListViewSnapshots, RootViewSnapshots.

Coverage gaps a redesign should know about (no snapshot found): queued/offline pending bubbles and the offline banner, archived bar, collapsed/expanded system and context strips, branch switcher, cache-dot and stop-reason signals, usage popover, attachment thumbnails/chips/lightbox, pending attachment strip, UI fragment renderers in a transcript, elicitation sheet, model picker sheet, inspector Plugins tab, failed compression card, continue-discussion chip, jump-to-latest button.

---

## 19. Discrepancies and loose ends spotted while reading

- The composer's maximum is 10 lines (`maxLines: 10`), but the snapshot test is named `composerCapsAtEightLinesAndScrolls`.
- Comments in `CompactView.swift`, `ContextListView.swift`, `ConversationSettingsView.swift` and `ConversationModelPicker.swift` still describe a "page replaces pane" pattern and toolbar back chevrons; in the current code these render inside sheets or the inspector.
- `ContextListPane` is unreachable from the UI but still snapshot-tested.
- Mac never writes `DraftStore` while typing (only on a failed send), so unsent text survives only while the view model lives; iOS persists on each keystroke.
- `StreamingRow`'s comment mentions a "~720pt" fallback cap; the Mac pane actually caps the column at 820 and bubbles at 80% (fallback 600).
