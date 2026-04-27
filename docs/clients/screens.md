# Client screens & functionality

Exhaustive inventory of every screen in the macOS and iOS apps, the elements they contain, what each element does, and which server RPCs back it. Companion to [architecture.md](architecture.md) (code structure / sharing) and the server's [docs/architecture.md](../architecture.md).

Conventions:
- Each screen is shared between macOS and iOS unless tagged **(macOS only)** or **(iOS only)**.
- "Element" = a visible or interactive UI piece.
- "Functionality" = behavior + the server RPC(s) it triggers.
- RPCs are listed by the canonical name from `proto/clark/v1/*.proto`.
- A consolidated RPC inventory (with what's implemented vs deferred) lives at the bottom.

---

## 1. Onboarding & auth

### 1.1 Login

**Purpose:** authenticate against a Clark server.

**Elements:**
- Server URL field (with default; persisted in UserDefaults)
- Username field
- Password field (secure text)
- "Show password" toggle
- "Sign in" button (primary)
- Inline error label (auth failure / network / server unreachable)
- Server health indicator — small badge polled before submit

**Functionality:**
- Submit → `AuthService.Login(username, password)` → store bearer token in Keychain → navigate to Conversation List.
- 401 → inline "wrong username or password."
- Network error → inline "couldn't reach server."
- Loading spinner on submit; field validation (non-empty before enabling Sign in).

### 1.2 First-run server setup *(optional)*

**Purpose:** if no server URL is stored, prompt for one before showing Login.

**Elements:** server URL field, "Continue" button, link to docs.
**Functionality:** ping `/healthz` → store URL → segue to Login.

---

## 2. Conversation list (home)

### 2.1 Conversation list

**Purpose:** browse all conversations; entry point to everything else.

**Elements:**
- List rows, each:
  - Title (or "Untitled" + first user-message snippet)
  - Last-message preview (`display_content` of latest message, truncated)
  - Timestamp (relative: "2m ago" / "Yesterday" / absolute)
  - Profile name badge
  - Active-stream indicator (animated dot if a `stream_run` is `running`)
  - Per-row context menu: Rename, Delete, Open in new window **(macOS)**, Duplicate
- "New Conversation" button (primary, top-right)
- Search bar (filters by title, profile name, recent message body — client-side over the loaded list initially)
- Filter chips: Profile (multi-select), "Has active stream", "Compacted recently"
- Sort selector: Most recent activity / Created / Title
- Empty state: "No conversations yet — start one"
- Pull-to-refresh **(iOS)**
- Sidebar grouping toggle **(macOS)** — by profile vs flat

**Functionality:**
- Load → `ConversationsService.ListConversations` (paginated; for now returns all).
- New Conversation tap → opens Profile Picker sheet (2.2) → `CreateConversation` → navigates to Conversation View.
- Row tap → Conversation View (3).
- Delete → `DeleteConversation` (with confirmation alert).
- Rename → inline edit → `UpdateConversation(title=...)`.
- Live update: poll every 30s when foregrounded (no activity-feed RPC yet).

### 2.2 Profile picker (sheet/modal)

**Purpose:** pick a profile when creating a new conversation.

**Elements:**
- List of profiles (name, system message preview, default model badge)
- "Manage profiles…" link → Profile List (4.1)
- Optional title field (pre-fill empty)
- Cancel / Create

**Functionality:**
- Load → `ListProfiles`.
- Confirm → `CreateConversation(profile_id, title?)` → navigate to Conversation View.

---

## 3. Conversation view (the meat)

### 3.1 Conversation header

**Elements:**
- Title (editable inline; saves on blur via `UpdateConversation`)
- Active-context indicator (e.g., "Context #3 of 5" if compacted history exists; tap → Context History sheet 3.6). When the active context has a title (auto-generated or user-set), it appears here as a subtitle under the conversation title.
- Profile name (read-only with link to view profile; profile cannot be switched mid-conversation)
- Token count: "12,403 / 200,000 tokens" — colour-coded as it approaches the context window
- Cost-to-date for this conversation (sum of `total_cost_usd` over messages)
- Cache health badge: "Cache: stable=98 / trailing=2" with tap-to-expand explanation
- Overflow menu:
  - Compact now…
  - View context history
  - Token count details
  - Plugins active (read-only list, link to profile editor)
  - Export transcript
  - Delete conversation
  - Open in new window **(macOS)**

**Functionality:**
- Token count → `CountContextTokens(active_context, default_provider, default_model)` — debounced after each new message.
- Cost-to-date computed client-side from message rows.
- Cache health from latest `stream_run` for the active context (`prefix_length`, `cache_stable_prefix_length`, `cache_trailing_depth`).

### 3.2 Message list

**Purpose:** scrollable history, oldest at top, latest at bottom.

**Elements (per message, varying by role):**
- **System / Context** — collapsed by default into a small "System prompt" / "Context preamble" pill; tap to expand.
- **User** — right-aligned bubble (full-width row on Mac); content rendered as Markdown with code blocks; selection enabled; per-row menu (Edit & resend, Fork from here, Copy raw, Copy display, Delete branch).
- **Assistant** — left-aligned; `display_content` rendered as Markdown; thinking blob collapsible at top of message; tool-use blocks rendered as inset cards (when tool use lands); per-row menu (Regenerate, Fork here, Copy display, Copy raw, View raw, View thinking, Show usage/cost).
- **Compression Summary** — rendered as a horizontal divider with "Compacted to new context →" label; tap → Context History sheet (3.6).
- Branch indicators: when `sibling_count > 0`, show a "1/3" pill ("you're viewing branch 1 of 3") with prev/next chevrons → calls `SetCurrentLeaf` to navigate siblings.
- Streaming-in-progress row: ghost bubble that fills in as chunks arrive; "Cancel" button visible while streaming.
- Choices renderer: when the `lettered_choices` plugin is active and the most-recent assistant message contains them, the client detects the lettered list (from `display_content` after tag-stripping) and renders selectable buttons (A / B / C) above the composer. Tapping a choice prefills the composer with the letter.
- Sticky "scroll to latest" floating button when scrolled up while a stream is active.
- Per-message timestamp (long-press / hover to reveal).
- Per-message model badge (which model produced it; useful when per-turn model switching).
- Per-message usage tooltip (input/output/cache_read/cache_write tokens + cost).
- Read-receipt-style stream status icons: queued / streaming / completed / errored / cancelled / interrupted.
- "Edited" badge with relative timestamp when `edited_at` is non-null.
- Per-row Edit affordance → inline-editable content with optional role flip toggle (user ↔ assistant only; system / context / compression_summary cannot be transmuted).
- Per-row Delete affordance → confirmation: stitch ("Delete this message? Children will be reparented to its parent.") or cascade ("Delete this message and N descendants? Type DELETE to confirm.").
- Compression-summary rows render as a callout card with `[Edit] [Delete] [Promote to new context →]` and an explanatory note: "Sending new messages is paused until you promote this summary or delete it." Composer is disabled while a `compression_summary` exists in the active context.

**Functionality:**
- Initial load → `ListMessages(context_id, leaf_message_id=current_leaf)` → returns the linear chain with `sibling_count` populated by the recursive CTE.
- New send → `SendMessage` returns `user_message + stream_run` → immediately push the user bubble + ghost assistant bubble → start `SubscribeStream(stream_run_id, from_sequence=0)`.
- Branch nav → `SetCurrentLeaf(context_id, message_id)` → re-fetch chain via `ListMessages(context_id, leaf=new_leaf)`.
- Regenerate → `SendMessage(parent_message_id=user_msg_id, content=user_msg.content)` (forks off the user message that prompted the bad reply).
- Edit (in place) → `EditMessage(id, content, role?)`. No fork.
- Delete (stitch) → `DeleteMessage(id, cascade=false)` — children reparent to grandparent.
- Delete (cascade) → `DeleteMessage(id, cascade=true)` — descendant subtree removed.
- Promote summary → `PromoteCompactionToNewContext(message_id)` — creates the new active context.
- Cancel → `StreamsService.CancelStream(stream_run_id)`.
- Show usage → `GetMessage(id)` returns full `MessageUsage`.

**Conversation lock (server-enforced):** while any `stream_run` for this conversation is `running`, all mutating actions (Send / Edit / Delete / Compact / Promote / Activate / SetCurrentLeaf / UpdateConversation / DeleteConversation) reject with `FailedPrecondition`. UI mirrors by disabling the relevant controls and exposing a Cancel button.

### 3.3 Composer

**Elements:**
- Text input (multi-line, growing; Cmd+Enter to send **(macOS)** / Send button **(iOS)**)
- Attachment button (placeholder; vision/files deferred per server architecture)
- Model picker chip (current default; tap → Model Picker 3.4)
- Provider picker (collapsed under model picker; expert mode shows it)
- Plugin status pills (compact badges of active plugins; tap → Plugin Pipeline Inspector 3.5)
- Token-count preview (live: "+312 tokens" as you type)
- Send button — disabled when streaming, when text empty, or when the projected token count would exceed the window
- "Continue from cursor" badge: when `current_leaf_message_id` is set to a non-tail message (user explored a branch), show "You're sending from branch X — your reply will continue this branch" with a "Switch to latest" button
- Voice input button **(iOS)** (deferred)
- Slash commands menu (deferred placeholder)

**Functionality:**
- Send → `SendMessage(conversation_id, content, parent_message_id=current_leaf, provider_id?, model_id?, call_settings?)`.
- Per-turn model override → updates `ConversationSettings.default_model_id` locally for next send only (or persists with toggle).
- Token preview → debounced `CountContextTokens` with hypothetical user message appended (or local length-estimate for cheap-fast).
- "Switch to latest" → `SetCurrentLeaf(context_id, message_id="")` (clear cursor → fall back to latest-by-created_at).

### 3.4 Model picker (sheet)

**Elements:**
- Sectioned list:
  - "Default" (the conversation's resolved default model) — pre-selected
  - Per provider: enabled models
- Each row: `display_name`, provider name, context window, pricing (per-million in/out), capabilities icons (thinking / vision / tool use)
- Search bar
- "+ Manage providers / models" link → Providers screen (5.1)
- "Per-turn only" vs "Set as conversation default" toggle
- Cancel / Confirm

**Functionality:**
- Load → `ListUserModels(user_id)` (or per-provider).
- Confirm + per-turn → store in local state for next send.
- Confirm + persist → `UpdateConversation(settings={default_provider, default_model})`.

### 3.5 Plugin pipeline inspector (sheet)

**Purpose:** see what plugins are active for this conversation (read-only; editing is on the profile).

**Elements:**
- Ordered list of attached plugins (from `GetProfilePlugins(profile_id)`)
- Per plugin: name, capability badges (System / History / Display / Tool / Chunk / Outgoing / Configurable), config preview (truncated JSON), description from `ListPluginTypes`
- "Edit on profile" link → Profile Editor → Plugin section (4.3)
- Cache health card: `cache_stable_prefix_length`, `cache_trailing_depth`, plain-language explanation ("Your plugins keep the most recent 2 turns out of cache; long-term win on token cost.")

**Functionality:**
- Load → `GetProfilePlugins(profile_id)` + `ListPluginTypes` (for descriptions).

### 3.6 Context history (sheet)

**Purpose:** browse compacted contexts in this conversation.

**Elements:**
- Vertical list of contexts (newest first), each with:
  - Title (auto-generated by the server when configured; editable inline → `UpdateContext(context_id, title=...)`; falls back to "Untitled" when null)
  - Activation timestamp
  - Snippet of `role=context` message (the compression summary) for non-root contexts
  - Message count
  - "Active" pill on the current one
  - "Reactivate" button on inactive ones
  - "View" button (opens read-only Conversation View pinned to that context)
- Visual line connecting parent-child contexts

**Functionality:**
- Load → `ListContexts(conversation_id)`.
- Reactivate → `ActivateContext(context_id)` → reload Conversation View with new active context.
- Rename → `UpdateContext(context_id, title=...)`. Empty string clears the title back to null (server treats it as "use auto-generation again on next eligible turn"; in practice the title remains null until manually re-set since the auto-generate only fires for the first assistant message in the context).

### 3.7 Compact-now confirmation (sheet)

**Elements:**
- Current context summary: message count, token usage
- Compression model + guide preview (from profile)
- Mode (REPLACE / APPEND) — applied at promote time, not now
- Estimated cost (compression call's tokens × pricing)
- "Generate summary" / Cancel
- Notice: "After the summary appears, you'll review it and choose to promote it to a new context or delete it."

**Functionality (two-stage flow):**
- Confirm → `Compact(conversation_id)` → returns `stream_run` → subscribe → render compression progress in a subdued style ("Summarizing…") → on completion the summary appears as a callout card in the message timeline (3.2). The composer is disabled until the user resolves the summary.
- Then the user reviews:
  - Edit summary content via `EditMessage(id, content)` — server allows editing `compression_summary` rows specifically because the next step seeds the new context's framing from this content.
  - Delete summary via `DeleteMessage(id)` — composer re-enables, conversation continues in the source context as if compaction never happened. (The compression LLM call already cost money; that's the price of the abort.)
  - Promote via `PromoteCompactionToNewContext(message_id)` — creates the new active context. Conversation rerenders against it; token-count badge drops; composer re-enables.

### 3.8 Stream-error / interrupted banner

**Elements:**
- Inline banner above composer when a recent stream errored, was interrupted, or was cancelled
- Error message
- "Retry" → resends the user message that elicited it
- "Dismiss"

**Functionality:**
- Surface from `stream_run.status != completed` and `error_payload`.

---

## 4. Profile management

### 4.1 Profile list

**Elements:**
- List of profiles (name, parent profile chain, # conversations using it, last edited)
- "+ New Profile" button
- Per-row: Edit, Duplicate, Delete (handle FK violation: "in use by 3 conversations")
- Search

**Functionality:** `ListProfiles`, `DeleteProfile`.

### 4.2 Profile editor

Sections (each collapsible; saves on blur or via "Save"):

1. **Basics**
   - Name
   - Parent profile picker (for inheritance)
   - "Resolved view" toggle: shows the effective resolved profile (parent chain merged) — read-only.

2. **System message**
   - Multi-line editor
   - Preview button (shows what gets sent, including plugin SystemPrompter prepend/append wraps)
   - "Inherit from parent" toggle (when toggled, field is empty/disabled and resolved value shown grayed)

3. **Default user message**
   - Multi-line editor
   - "Inherit from parent" toggle

4. **Default model**
   - Provider + model picker (same shape as 3.4)
   - Include-thinking-in-history toggle
   - "Inherit from parent" toggle

5. **Compression settings**
   - Provider + model picker for compression
   - Compression guide editor (multi-line)
   - Mode picker: REPLACE / APPEND
   - "Inherit from parent" per-field

6. **Auto-title settings**
   - Provider + model picker for auto-titling (small/cheap model recommended)
   - Title guide editor (optional; default prompt shown grayed-out when blank)
   - "Inherit from parent" per-field
   - Notice: "When configured, the server generates a 2-5 word title for new conversations and contexts after the first assistant turn. You can always edit titles manually."

7. **Plugins** → opens Plugin Pipeline Editor (4.3)

8. **Danger zone:** Delete profile

**Functionality:**
- Load → `GetProfile(id, resolve=true)`.
- Save → `UpdateProfile(...)`.
- Delete → `DeleteProfile`.

### 4.3 Plugin pipeline editor

**Elements:**
- Top: "Available plugins" panel (list from `ListPluginTypes`):
  - Each: name, description, capability badges
  - Drag handle (drag onto the pipeline below)
  - "Add" button (alternative to drag)
- Bottom: "Pipeline" panel (ordered list):
  - Each entry: plugin name, capability badges, "Configure…" button, drag handle, Remove button
  - Reorder by drag
  - "All-or-nothing inheritance" notice when pipeline is empty: "This profile inherits its plugin list from {parent_profile.name}. Adding any plugin overrides the parent's full list."
- "Save Pipeline" button (atomic; nothing persists until clicked)
- Per-plugin Configuration sheet (4.4)
- Optional: "Test against current conversation" button (renders prefix preview without sending)

**Functionality:**
- Load → `GetProfilePlugins(profile_id)`, `ListPluginTypes`.
- Save → `SetProfilePlugins(profile_id, [...])` (atomic).

### 4.4 Plugin configuration sheet

**Elements:**
- Plugin name, description
- Form rendered from the plugin's JSON Schema (`PluginType.config_schema`):
  - String fields → text inputs (multi-line if marked `format: text`)
  - Integer fields → number steppers with min/max from schema
  - Boolean fields → toggles
  - Enum fields → segmented controls or pickers
- "Reset to defaults" button
- "Show raw JSON" toggle (advanced; lets the user paste arbitrary JSON)
- Cancel / Save

**Functionality:**
- Save → updates the in-memory pipeline entry's config; persisted only on parent's "Save Pipeline".
- Validation runs against the schema client-side.

---

## 5. Provider & model management

### 5.1 Provider list

**Elements:**
- List of configured providers (label, type, # enabled models, "Default" star)
- "+ Add Provider" button
- Per row: Edit credentials, Browse models, Disable, Delete

**Functionality:** `ListUserModelProviders`, `DeleteUserModelProvider`.

### 5.2 Add provider (sheet / wizard)

**Step 1 — Pick driver type:**
- List from `ListProviderTypes` (driver types compiled into server: anthropic, openai-compatible, claude-code-subprocess, etc.)
- Each: name, `display_name`, "Stateful" badge, description

**Step 2 — Pick from catalog template (optional):**
- List from `ListProviderTemplates` (catalog-known providers like Groq, OpenRouter, Together, Fireworks)
- Picking a template prefills the URL + driver type.

**Step 3 — Configure:**
- Form rendered from `ProviderType.config_schema`: api_key (secure field), base_url, etc.
- Friendly label field
- "Test connection" button → server-side `TestProvider` (deferred RPC; for now: try a no-op model list).

**Functionality:** `CreateUserModelProvider(type, label, config)`.

### 5.3 Provider detail / model browser

**Elements:**
- Header: provider label, type, base_url
- Two tabs: "Enabled" / "Catalog"
- **Enabled tab:** list of `UserModel` rows:
  - `display_name`, `model_id`, context window, pricing, capabilities icons, snapshot date
  - Per row: Edit display name, Disable, Refresh metadata (re-snapshot from catalog)
- **Catalog tab:** list of `CatalogModel` rows for this provider's `catalog_provider_id` (if any):
  - Search
  - Capability filter chips (thinking / vision / tool use / cache)
  - "Enable" button per row
- Bottom: "Add custom model…" → for models not in catalog

**Functionality:**
- `ListUserModels(provider_id)`, `EnableModels(provider_id, model_ids[])`, `DisableModel`, `UpdateUserModel`, `RefreshUserModelMetadata`.

### 5.4 Add custom model sheet

**Elements:** `model_id`, `display_name`, context window, max output tokens, prices (input/output/cache_read/cache_write), capabilities checkboxes, modalities multiselect, default settings JSON.

**Functionality:** `AddManualModel`.

---

## 6. Streams / debug

### 6.1 Stream runs panel **(macOS bottom panel + iOS Settings → Diagnostics)**

**Elements:**
- List of recent `stream_runs` (across all conversations), filterable by conversation/status
- Per row: status icon, conversation name, model, duration, total tokens, total cost, cache stable/trailing
- Tap → Stream Run Detail (6.2)

**Functionality:** `ListStreamRuns` (deferred; for v1, query per-conversation via `GetStreamRun` after the fact).

### 6.2 Stream run detail

**Elements:**
- All `stream_run` fields including provider, model, started_at, ended_at, status
- Cache observability: `cache_stable_prefix_length`, `prefix_length`, `cache_trailing_depth`, plain-language interpretation
- Token usage breakdown
- Cost breakdown
- "View raw chunks" → scrollable list of persisted chunks (sequence, type, payload preview)
- "Replay" — opens read-only viewer that re-runs `SubscribeStream` from sequence 0 (all from DB)
- Error payload (if any)

**Functionality:** `GetStreamRun`, `ListStreamChunks`, `SubscribeStream(from_sequence=0)`.

---

## 7. Settings

### 7.1 Settings (iOS) / Preferences (macOS)

Sections:

1. **Account**
   - Username, "Logged in as", server URL
   - "Change password" (deferred RPC; show as disabled with explanation for now)
   - Sign out

2. **Server**
   - Server URL (read-only or editable per build)
   - Connection health (live ping)
   - Server version (deferred `Version` RPC; show "—" for now)

3. **Appearance**
   - Theme: System / Light / Dark
   - Font size for message body
   - Markdown rendering toggle (raw vs rendered)
   - Show timestamps: Always / On hover / Never

4. **Behavior**
   - Default profile for new conversations
   - Confirm before deleting (toggle)
   - Confirm before compacting (toggle)
   - Stream auto-scroll (toggle)
   - Show cache observability badges (toggle)

5. **Notifications** **(iOS only)**
   - "Notify on stream completion when app is backgrounded" toggle (requires push setup)
   - "Notify on stream errors" toggle

6. **Keyboard shortcuts** **(macOS only)**
   - Editable keybinds for: New conversation, Send, Cancel stream, Switch to latest branch, Open profile editor, Toggle plugin pipeline inspector

7. **Diagnostics**
   - Recent stream runs link
   - Local cache size + clear button
   - Logs viewer (debug)

8. **About**
   - Version, build number, commit
   - Open-source acknowledgements
   - Link to docs / GitHub

---

## 8. macOS-only chrome

### 8.1 Menu bar
- **Clark menu:** About, Preferences (⌘,), Quit (⌘Q)
- **File menu:** New Conversation (⌘N), New Profile, New Provider, Close Window (⌘W), Export Transcript
- **Edit menu:** standard Cut/Copy/Paste/Find; "Find in conversation…" (⌘F)
- **View menu:** Show/Hide sidebar, Show/Hide context history, Toggle compact mode, Show stream runs panel
- **Conversation menu:** Send (⌘↩), Cancel stream (⌘.), Compact now, Switch to latest branch (⌘⇧L), Previous branch (⌘⇧[), Next branch (⌘⇧]), Switch model (⌘M)
- **Window menu:** standard; list of open conversation windows
- **Help:** Docs, Report issue

### 8.2 Sidebar (list-detail)
- Profiles section (collapsible)
- Conversations section (grouped by profile or flat)
- Bottom: settings gear, plugin manager link

### 8.3 Multiple windows
- Each conversation can open in its own window (⌘N for new, ⌘double-click to detach from list)
- Profile editor in own window
- Provider settings in own window
- Stream runs panel as a floating utility window

### 8.4 Spotlight integration
- Index conversation titles + message content via `CSSearchableIndex`
- Tap result → deep link into Conversation View at that message

### 8.5 Services menu
- "New Clark conversation with selection" — invokable from any app via the Services menu; opens a new conversation with the selected text as the first user message.

### 8.6 Status bar item *(optional)*
- Menu bar icon showing active stream count
- Click → quick-access menu: recent conversations, new conversation, preferences

---

## 9. iOS-only chrome

### 9.1 Tab bar (iPhone) / sidebar (iPad)
- **Conversations** tab — Conversation List
- **Profiles** tab — Profile List
- **Models** tab — Provider List + Models
- **Settings** tab

### 9.2 Background-aware affordances
- Active stream indicator in nav bar (animated dot) when a stream is running and the app is foregrounded.
- On returning from background: silent "catching up…" overlay while the client re-subscribes with `from_sequence = lastSeen + 1`.
- BGProcessingTask scheduled when app backgrounds with active streams: occasional catch-up so the local cache is fresh on next foreground.

### 9.3 Push notifications
- Stream-completion push (server-side push integration deferred; design slot reserved):
  - Tap → opens that conversation, scrolled to the new assistant message.
  - Notification Service Extension: pre-fetches the assistant message body so it's instant on launch.

### 9.4 Share sheet integration
- "Send to Clark" share extension — accept text/URLs from any app, open new conversation seeded with that content.

### 9.5 Swipe actions on Conversation List
- Swipe left: Delete, Rename
- Swipe right: Mark as favorite (deferred)

### 9.6 Keyboard avoidance
- Composer rises with keyboard; messages reflow; sticky "scroll to latest" button visible during composition.

### 9.7 Haptics
- Light tap on send, success on stream completion, error on failure.

---

## 10. Cross-cutting concerns (every screen)

- **Auth interceptor** — all RPCs carry `Authorization: Bearer <token>`. 401 response → drop to Login screen; preserve current view's state for restoration.
- **Connectivity banner** — global banner ("No connection — viewing cached data") when network drops.
- **Loading vs error states** — every list view has explicit empty / loading / error variants, not just a blank screen.
- **Optimistic updates** where safe (rename conversation, edit profile name) with rollback on server failure.
- **Local cache** — SwiftData (or Codable) for: conversations list, recent contexts, recent message chains. Server is source of truth; cache is a perf/offline read-only layer. No write-side conflict resolution needed — every mutation goes through the server.
- **Deep links** (both platforms) — `clark://conversation/<id>`, `clark://conversation/<id>/message/<id>`, `clark://profile/<id>`. Used by Spotlight (macOS) and push notifications (iOS).

---

## RPC inventory

The complete list of RPCs the client touches.

### Implemented (use immediately)

`Login`, `WhoAmI`,
`ListProfiles`, `GetProfile`, `CreateProfile`, `UpdateProfile`, `DeleteProfile`,
`ListPluginTypes`, `GetProfilePlugins`, `SetProfilePlugins`,
`ListProviderTypes`, `ListProviderTemplates`,
`ListUserModelProviders`, `CreateUserModelProvider`, `DeleteUserModelProvider`,
`ListUserModels`, `EnableModels`, `DisableModel`,
`ListConversations`, `GetConversation`, `CreateConversation`, `UpdateConversation`, `DeleteConversation`,
`ListContexts`, `UpdateContext`, `ActivateContext`, `SetCurrentLeaf`,
`ListMessages`, `GetMessage`, `EditMessage`, `DeleteMessage`,
`SendMessage`, `Compact`, `PromoteCompactionToNewContext`, `CountContextTokens`,
`SubscribeStream`, `CancelStream`, `GetStreamRun`.

### Deferred (clients should design with placeholders + TODO comments)

`AddManualModel`, `UpdateUserModel`, `RefreshUserModelMetadata`,
`TestProvider`,
`Version`,
`ListStreamRuns`,
`ChangePassword`,
`RegisterDevice` (push),
tool-use round-trip on existing stream,
vision/file attachments.
