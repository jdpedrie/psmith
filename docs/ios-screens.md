# Reeve iOS — Per-Screen UX Plan

A detailed companion to `ios-plan.md`. The architecture skeleton (module layout, platform-glue protocols, shared `ReeveUI` views, multi-server-no-thanks decision) lives in that doc. **This** doc walks every Mac UI surface and decides its iOS treatment screen-by-screen — what's shared, what's per-platform, and *why* each call goes the way it does.

Read this as the input to Phase 5 (conversations on iPhone) and Phase 7 (settings on iPhone). It is opinionated; any deferred decisions are called out at their site so future-me has a hook to pick up from.

Target devices: **iPhone first** (primary user device), **iPad second** (single-binary fork via `horizontalSizeClass` switch — covered in §5).

---

## 0. Scope + how to read this

What's in this doc:

- A foundational layer of cross-cutting decisions (root container, navigation idioms, presentation patterns, gesture vocabulary, theming) that the per-screen sections lean on.
- A per-Mac-surface walkthrough of 23 distinct UI surfaces. Each entry: Mac shape recap, iPhone treatment, rationale, what's reused from `ReeveUI`, what stays per-platform, and outstanding risks/questions.
- A consolidated cross-cutting concerns chapter (ScenePhase, keyboard, accessibility, notifications) so platform-systemic stuff doesn't get lost in the per-screen weeds.
- An iPad addendum scoping the regular-size-class fork without designing every iPad screen in detail.
- Implementation sequencing (sub-phases inside Phase 5/7/8).
- Open threads — features the iOS app eventually wants but defers past first ship.

What's *not* in this doc:

- Pixel-level visual specs. Color tokens come from the existing `Theme` system; spacing, padding, font sizes follow the same conventions used in the Mac app (the shared `ReeveUI` views encode them). Where iOS-specific values are needed (safe-area insets, navigation bar height) they're derived from system defaults.
- Server-side changes. Every iOS feature in this plan rides on the existing `reeved` API; no new RPCs, no schema changes. Notes flag the spots where a new RPC would be required (deferred for now).
- Non-Reeve apps. There's no comparative analysis of how Messages/Slack/etc. handle X. Where I cite a precedent it's because that precedent is doing exactly what we want; otherwise it's just noise.

A "screen" in this doc means a distinct render mode the user can be in. A long-press context menu is not a screen; a sheet that opens over the conversation IS a screen.

---

## 1. Foundational decisions

These are the load-bearing calls. Every per-screen treatment in §2 rests on them.

### 1.1 Root container: single `NavigationStack` (Chats), Settings via account-menu sheet

**Decision** *(revised after Phase 5/7 shipped)*: no `TabView`. The conversation list is the root and Settings is presented as a sheet from the top-leading account avatar menu.

The original plan called for a two-tab `TabView` (Chats / Settings) — see the "Original alternative considered" subsection below. After flying with the TabView for one session, the bottom tab bar's ~50pt of vertical chrome was deemed too expensive given how heavily the conversation surface relies on every available row of message scroll. Settings is touched rarely after initial setup; promoting it to permanent bottom-bar real estate inverted that frequency.

The replacement: account avatar menu (already in the top-leading toolbar — username + server URL + sign out) gains a `Settings` item. Tapping it presents `SettingsRoot` as a sheet (`.large`, drag-to-dismiss, Done button in nav bar). Inside the sheet, the existing drill-down list + per-category screens render unchanged.

Implications elsewhere in this doc:
- Welcome state stays an inline empty-state on the conversation list (§2.11) — no change.
- "Open Profile in Settings" callbacks (§2.10 NewConversationSheet) still work via `iOSNavigator.pendingProfileSelection`, but the consumer flow changes: ChatsRoot opens the Settings sheet, then ProfilesListView inside the sheet reads + clears the pending id and pushes.
- iPad regular (§5) keeps the original plan: Settings is a sheet over the `NavigationSplitView` for the same reason — the iPad doesn't gain anything from a Settings tab when the sidebar already handles "where am I" navigation.

#### Original alternative considered (kept for context)

Initial decision was `TabView` with two tabs (Chats / Settings) over single-stack-with-drawer (Settings is many sub-screens; bury behind a hamburger inverts hierarchy) and over three+ tabs (Account is one screen — it lives off the Chats toolbar avatar, doesn't justify a tab). The vertical-cost argument flipped this after real use.

iPhone has three serious options for the top-level container shape:

1. **Single `NavigationStack`** with a hamburger drawer for cross-cutting nav (Slack, Discord). Works for chat-centric apps where settings are rare; reads as "the conversation IS the app."
2. **`TabView`** with 2–4 tabs. Default iOS pattern (Mail, Photos, App Store). Tabs persist across the app's life so users can flip between them without losing place.
3. **Sidebar-collapse-to-tabbar** via the new `TabView` + `Tab` API in iOS 18+. Promising but less proven; would require iPad to switch chrome at runtime.

Reeve has two distinct user concerns: *talking to AI* (the main thing — multiple conversations, frequent context-switching) and *configuration* (providers, profiles, plugins, appearance — touched rarely after initial setup but heavily then). A `TabView` separates them cleanly without burying either: tap-to-switch between Chats and Settings is a single gesture, settings stay one tap away during a conversation, and the user never loses their place in either.

Why two tabs and not three (e.g. Chats / Account / Settings)? Account is one screen — name, server, sign out. It's a sub-page of Chats reachable from a top-trailing toolbar avatar (matching the Mac sidebar tray pattern), not its own tab. Tabs cost discoverability and screen real-estate; we only spend a tab when the destination has multiple sub-screens worth of content.

Why not single-stack with drawer? Because Settings is *not* one screen — it's five categories with multiple sub-screens each. Burying that behind a hamburger menu inverts the hierarchy: configuration becomes a deeply-nested second-class concern instead of an explicit first-level destination. Dedicated tab is correct.

**Implementation**:

```swift
TabView {
    Tab("Chats", systemImage: "bubble.left.and.bubble.right") {
        NavigationStack(path: $chatsPath) { ChatsRoot() }
    }
    Tab("Settings", systemImage: "gear") {
        NavigationStack(path: $settingsPath) { SettingsRoot() }
    }
}
```

Each tab gets its own `NavigationPath` binding so back-stack survives tab switches.

### 1.2 Navigation idiom: push by default, sheet for compose-style modals, never popover

**Decision rule**: every drill-deeper destination is a `NavigationLink` push. Every "compose a new thing" is a `.sheet`. No popovers (the iOS popover API works but reads as iPad-shaped on iPhone). No `fullScreenCover` (used only when the screen *cannot* be dismissed by the user — auth flow doesn't qualify).

**Why push for drill-deeper**: edge-swipe-back (and the hard-coded chevron in the nav bar) gives the user a free escape hatch. The push stack mirrors the user's mental model of where they are: "I'm in Chats → in conversation X → in its settings." Settings on Mac is page-replaces-pane; on iOS that pattern *is* the push, just with the navigation bar visible above instead of a back-chevron in the toolbar.

**Why sheet for compose**: the modal-up-from-bottom gesture sets the user's mental model to "I'm doing a focused action that doesn't belong in the back-stack history." iOS Mail's compose, Messages' new chat, Notes' new note — all sheets. Sheets get a Cancel/Save toolbar bar and a swipe-down-to-dismiss gesture; they don't interfere with the underlying view's nav stack.

**The gray area**: **picker sheets** with `.presentationDetents([.medium, .large])`. The model picker is the canonical case — user wants to switch model, doesn't want to leave the conversation, doesn't want a full-screen sheet. Half-height sheet with the picker inside is the iOS-native answer. Same for the compaction form (which IS a focused action, but compact-from-conversation reads as "I'm tweaking something about this chat" not "I'm composing a whole new thing"). Compact gets sheet + `.large` detent; model picker gets sheet + `[.medium, .large]`.

Concrete mapping from Mac's page-replaces-pane pattern to iOS:

| Mac page-replace | iOS treatment | Why |
|---|---|---|
| `ContextListPane` | Push | Drill-deeper into "where this conversation has been"; back to return |
| `CompactPane` | Sheet (`.large`) | Focused action with a "do it" submit; sheet's swipe-down-to-cancel matches "nope, never mind" |
| `ConversationSettingsView` | Push | Drill-deeper into "what is this conversation"; settings persist on dismiss |
| `ConversationModelPicker` | Sheet (`.medium`/`.large`) | Quick picker, want to stay anchored in the conversation visually |

### 1.3 Hover affordances → long-press context menus

Mac's hover-pill pattern (Edit / Reload / Copy / Delete on each message bubble; trash icon on each conversation row) doesn't translate to touch — there's no equivalent of "I'm pointing at this without committing." iOS has two replacements:

- **Long-press context menu** (SwiftUI `.contextMenu`) for "show me what I can do with this." Native, system-styled, dismissed by tapping outside.
- **Swipe actions** (`.swipeActions`) for "do this thing fast" — typically destructive (Delete) or one-tap toggle (Pin / Mute / Mark read). Trailing edge for destructive, leading for accumulative.

Decision rule: every Mac hover affordance becomes a context menu item. Destructive single-tap actions ALSO get a swipe action (Delete on conversation rows). Branch-switcher chevrons are too important to bury behind a long-press; they stay visible inline (small, low-contrast) on every assistant message that has siblings.

The `.contextMenu` modifier works identically on both platforms — same SwiftUI code, different gesture entry. Right-click on Mac, long-press on iOS. The shared composite views in `ReeveUI` (when we eventually extract `MessageRow`) get one `.contextMenu` declaration that satisfies both.

### 1.4 Toolbar items → `.toolbar` placements

Mac uses `.toolbar { ToolbarItem(placement: .navigation) { … } }` style declarations heavily. iOS uses the same SwiftUI API; the placement values map cleanly:

| Mac placement | iPhone placement | What lives there |
|---|---|---|
| `.navigation` (leading) | `.topBarLeading` (auto-back) | Auto-managed by NavigationStack; only override for sheets where there's no back |
| `.primaryAction` (trailing) | `.topBarTrailing` | Settings/compact/contexts gear icons; account avatar on Chats root |
| `.confirmationAction` (trailing, accent) | `.topBarTrailing` (`.borderedProminent` styled button) | "Compact", "Save", "Sign in" — primary commits |
| `.principal` (centered title) | `.principal` (centered title) | Custom titles where `navigationTitle` doesn't suffice |

NavigationStack's automatic back chevron replaces the Mac's manually-rendered back chevron; we lose one button per page-replace screen.

### 1.5 Theming, glass, and the chrome problem

`Theme` (already cross-platform per Phase 0) carries accent / bubble tint / highlight / chrome. On iOS:

- **Accent** drives `.tint(theme.accent)` at the App root, same as Mac. Buttons, links, segmented control selection, swipe action backgrounds all inherit it.
- **Bubble tint** is the same value used by `MessageRow` (still per-platform; iOS version mirrors Mac shape with iOS-specific gesture wrapping).
- **Highlight** is unused on iPhone for now. The Mac sidebar's "selected row" highlight has no equivalent — iOS NavigationStack doesn't show "you are here" because *there* is the current screen. Reserved for potential iPad sidebar use (§5).
- **Chrome** is the trickier one. Mac uses chrome to color the title-bar overlay region (NSWindow.backgroundColor). iOS has nothing analogous — the `UINavigationBar` background is system-managed (translucent material with the underlying content showing through, modulated by `.toolbarBackground`).

iOS chrome treatment: apply `.toolbarBackground(theme.chrome.opacity(0.6), for: .navigationBar)` so themed colors tint the nav-bar tinted material. Same pattern for the tab bar. Won't be a 1:1 visual match with Mac (because the Mac's chrome region is opaque and the iOS one is translucent material) but stays in the same color family. Acceptable.

**Liquid Glass** modifiers (`.glassEffect`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`) work identically on iOS 26+. The glass capsule + chips + composer surface all carry over. Where Mac uses `.thinMaterial` for footer bands, iOS uses the same — but the iOS tab bar already has its own material, so we don't double up.

### 1.6 Title-bar inset (Mac `.padding(.top, 28)`) → drop entirely

Mac's per-pane `.padding(.top, 28)` exists because `fullSizeContentView` extends content under the title bar. iOS doesn't have that problem; `NavigationStack` manages safe-area insets correctly out of the box. Anywhere a Mac view has `.padding(.top, 28)`, the iOS equivalent has nothing.

Per-platform divergence — easiest to either:
- Compose the screens fresh in `ReeveiOS` (the path Phase 5 takes), so the inset never appears.
- Or, when a screen IS extracted to `ReeveUI`, gate the inset on `#if os(macOS)` inside the shared file.

The first path is correct for screen-level layouts (which the iOS plan deliberately keeps per-platform per `ios-plan.md` §"Stay platform-specific"). The second is appropriate for atomic/composite views that shouldn't know they're being composed differently.

### 1.7 Keyboard handling: rely on SwiftUI defaults, supplement with `.scrollDismissesKeyboard`

SwiftUI on iOS auto-resizes content for the keyboard via `.keyboardAvoidance`. The composer's text field will push the message scroll up when focused, no manual `KeyboardObservingView` needed.

Two opinionated additions:
- `.scrollDismissesKeyboard(.interactively)` on the message scroll, so the user can swipe down to dismiss the keyboard while scrolling history (matches Messages, Mail).
- A `.toolbar` keyboard accessory with a "Done" button that dismisses focus, for tooltip-free explicit dismissal.

Composer-specific behavior:
- `.submitLabel(.send)` on the text field for the keyboard's blue submit key.
- Multi-line input via `TextField("…", text: $draft, axis: .vertical)` with `.lineLimit(1...8)` (same shape as Mac).
- Return inserts a newline by default. **No** `shift+Return` magic — iOS doesn't have a shift modifier in the on-screen keyboard. Use the explicit Send button (in nav-bar trailing or in-line in the composer chrome) to send.

### 1.8 Streaming + ScenePhase

iOS aggressively suspends backgrounded apps. The Mac app's stream-via-SSE will quietly die when the app backgrounds and not resume on its own. The supervisor on the server side keeps streaming regardless and persists chunks to `stream_chunks` — that's the existing recovery path.

`ScenePhase` integration goes in `ReeveiOSApp` and propagates via env or callback:

- `.background` → cancel any active `client.streams.subscribe(streamRunID:)` task. Record the last seen sequence number on the active conversation's view-model.
- `.active` → if the conversation has an unfinished stream (poll `stream_runs.status`), call `client.streams.subscribe(streamRunID:, fromSequence: lastSeen + 1)` to replay missed chunks.

The supervisor's "broker only ever sends what's already in DB" invariant means replay is correct by construction. The view-model just re-applies the chunks; the existing `applyStreamChunk` path handles them as if they'd arrived live.

Implementation note: this needs to land in `ConversationViewModel` (already in `ReeveKit`) so it's shared. The Mac app doesn't need ScenePhase awareness today (mac apps don't suspend the same way) but the hook costs nothing on Mac. Concrete shape: `ConversationViewModel.suspendStreamIfActive() / resumeStreamIfPaused()` methods, called from `ScenePhase` change in `ReeveiOSApp`.

### 1.9 Local notifications: iOS Notifier implementation

Phase 1 already extracted the `Notifier` protocol into `ReeveKit`. Mac has `MacNotifier` conforming. iOS needs a counterpart `iOSNotifier`:

- Same suppression rule: don't fire if the app is currently active (check `UIApplication.shared.applicationState == .active` instead of `NSApp.isActive`).
- Same permission flow: request on first call via `UNUserNotificationCenter.current().requestAuthorization`.
- Same `UNNotificationRequest` build: title=Reeve, subtitle=conversation title, body=preview, threadIdentifier="conversation:\(id)" so consecutive notifications group per conversation.
- `UNUserNotificationCenterDelegate` for tap-to-focus: route to `Navigator.pendingConversationSelection = convID` so the Chats tab activates and switches to that conversation.

The codesign-identifier requirement that bit us on Mac (memory: `feedback_macos_notifications_codesign.md`) doesn't apply on iOS — Xcode's iOS build always signs with the bundle ID matching Info.plist. No special workaround.

### 1.10 Accessibility floor: VoiceOver-readable, Dynamic Type-compatible from day one

iOS users get app-wide font scaling for free via the system Dynamic Type setting (the thing we couldn't replicate on Mac per `feedback_macos_font_scaling.md`). Every `.font(.body)` / `.font(.callout)` / `.font(.caption)` already in `ReeveUI` will scale automatically; nothing to wire.

VoiceOver labels: every interactive element needs a meaningful label. The shared `ReeveUI` views mostly already have them (button text is the label); the per-platform iOS views need to add them where icons stand alone (e.g., a trailing-edge swipe action with just a trash icon needs `.accessibilityLabel("Delete conversation")`).

Floor commitment for first ship: every screen reachable via VoiceOver (no traps), every action reachable via the rotor, no orphan "Button" announcements. Audit pass at the end of Phase 5.

### 1.11 Haptics

iOS users expect haptic feedback on destructive actions and major state changes. Targeted use:

- **Send message**: `UIImpactFeedbackGenerator(style: .light)` impact when the send button fires.
- **Delete confirmed**: `.warning` notification when a conversation/message is deleted.
- **Sign in succeeded**: `.success` notification on the LoginView phase 2 → authenticated transition.

Wrap behind a thin `Haptics` enum so it's a single import; defer adding it to ReeveUI until a second platform needs the same hook (visionOS / iPadOS). For now, lives in `ReeveiOS/Platform/Haptics.swift`.

### 1.12 Pull-to-refresh

`.refreshable { … }` on `ScrollView` / `List` is the iOS-native pull-to-refresh. Two relevant places:

- **Conversation list**: pull → refetches conversations from server. The list ViewModel's `refresh()` is already a thing.
- **Inside a conversation**: pull → refetches the message list and re-subscribes to any active stream. Useful when a stream finished while the user was reading earlier history; rare but the muscle memory exists.

Both wire to existing ViewModel methods. No new RPCs.

### 1.13 Search

`.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))` on the conversation list root. The drawer placement keeps the search field above the list when scrolled to top; collapses out of sight when scrolled.

The Mac's three-pill mode toggle (All Chats / By Profile / Search) collapses on iOS into:
- "Search" mode → handled by `.searchable` (always available, no explicit pill needed).
- "All Chats" vs "By Profile" → `Picker(.segmented)` *below* the search bar, *above* the list.

So iOS gets two affordances (search field + segmented picker) where Mac has three (three pills, with search being one of them). Net cleaner.

---

## 2. Per-screen treatments

Twenty-three Mac surfaces from the inventory. Each gets: Mac shape recap (one sentence), iPhone treatment (the call), rationale, ReeveUI usage, what stays per-platform, risks/open questions.

### 2.1 LoginView — Phase 1: Server URL Entry

**Mac shape**: Centered modal-like form, 380pt-wide column, Test/Continue buttons, status banner.

**iPhone treatment**: Same shape, top-aligned (instead of centered) within a `NavigationStack` root. ✅ **Already shipped in Phase 4.**

**Rationale**: Already a focused single-purpose screen on Mac — translates 1:1.

**Reused**: nothing (it's per-platform login chrome). Calls `probeReeveServer(url:)` from ReeveKit.

**Per-platform**: the entire screen.

**Risks**: none — shipping smoothly.

### 2.2 LoginView — Phase 2: Credentials Entry

**Mac shape**: Server URL chip with "Change" link, username/password fields, error display, Sign in button.

**iPhone treatment**: Same shape, with iOS-native `SecureField` + `.textContentType(.password)` for keychain autofill suggestions. ✅ **Already shipped in Phase 4.**

**Rationale**: Standard login form, no Mac-specific anything. Keychain autofill comes for free with the right `.textContentType` declarations.

**Reused**: `ReeveError.display(_:)` from ReeveKit. AppModel injection.

**Per-platform**: form chrome.

**Risks**: nothing immediate. Eventually want to add "Sign in with Passkeys" once `reeved` supports WebAuthn — orthogonal.

### 2.3 RootView / HomeView — Auth gate + chats shell

**Mac shape**: `RootView` switches on `authState.isAuthenticated`; the authed branch is `HomeView`'s `NavigationSplitView` with sidebar (conversation list + tray) and detail (conversation / new-conv form / settings shell).

**iPhone treatment**: `RootView` keeps its auth-gating role (already done in Phase 4). The authed branch swaps to a **`TabView`** with two tabs:

- **Chats tab** = `NavigationStack` rooted at `ChatsRoot` (conversation list with `.searchable` + segmented mode picker; toolbar trailing = account avatar with menu, plus glass `+` for new conversation)
- **Settings tab** = `NavigationStack` rooted at `SettingsRoot` (categories list)

The Mac's "sidebar tray" with user menu + new-conversation button moves into the Chats tab's nav-bar trailing region. Sign out lives in the account menu (long-press the avatar OR a dedicated Account screen pushed from the avatar).

**Rationale**: §1.1.

**Reused**: `RootView`'s auth-gate pattern carries over. The `AppModel` env injection is identical.

**Per-platform**: `TabView` + tab roots are entirely iOS.

**Risks**:
- TabView with stack-deep nav: iOS will scroll-to-top a tab on second tap. Confirm this doesn't pop the user's mid-stack navigation unexpectedly; it shouldn't (scroll-to-top is in-screen behavior, not a stack pop).
- Account menu placement: putting it as a top-trailing avatar conflicts with the `+` for new conversation. Resolution: avatar is leftmost, then `+` to its right (matches iOS Mail's compose-on-trailing pattern).

### 2.4 ConversationListView — sidebar list

**Mac shape**: `List` with three modes (All Chats / By Profile / Search), conversation rows with hover-trash, right-click context menu, single-selection driving the detail pane.

**iPhone treatment**: Full-screen `List` inside the Chats tab's `NavigationStack`. Top: `.searchable` field (drawer-pinned). Below: `Picker(.segmented)` for "All Chats" / "By Profile". Below: the rows.

Row interactions:
- **Tap row** → push `ConversationView` onto the stack.
- **Trailing-edge swipe** → red Delete action; confirmation alert before commit.
- **Long-press** → context menu with Edit (rename inline — TBD) and Delete.

**Rationale**: §1.3 (swipe + context menu replace hover affordances). §1.13 (`.searchable` for search). The segmented picker collapses two of the three Mac mode-pills into one control; the third (Search) is always-on via the searchable modifier.

**Reused**: `ConversationsModel` from ReeveKit (the existing list ViewModel; selection binding is unused since iPhone pushes instead of selecting). `ProfileCard` (already shared) for the "By Profile" mode's per-profile section headers.

**Per-platform**: the screen-level scaffolding (mode picker + searchable). The row content (conversation title, profile chain, last-updated stamp) — extract to `ReeveUI/Composite/ConversationRow.swift` so iOS and the future iPad sidebar share the same row body, with iOS wrapping in `.swipeActions`.

**Risks**:
- "By Profile" mode renders sections per-profile. iOS's `List` section UX is well-understood, no problem.
- Empty state: no conversations yet → show an inline `EmptyStateView` ("Tap + to start a chat") above an unobtrusive Welcome. No separate Welcome screen on iPhone (see §2.11).

### 2.5 ConversationView — main pane

**Mac shape**: 1900-line file. Top-level: `ConversationBody` wraps a VStack of {status strip, error banners, message scroll, composer}. Four page-replace alternates take over the whole pane: Contexts, Compact, Conversation Settings, Model Picker. Toolbar carries leading back-chevron (when an alternate is active) + trailing primary actions (settings gear, compact wand, contexts tray icon).

**iPhone treatment**: A pushed `NavigationStack` destination (from the conversation list). Body = the same VStack of {status strip, error banners, message scroll, composer}, **without** the page-replace alternates. Each Mac page-replace becomes one of:

| Mac page-replace | iPhone treatment |
|---|---|
| Contexts | Push `ContextListView` |
| Compact | Sheet `CompactView` (`.large` detent) |
| Conversation Settings | Push `ConversationSettingsView` |
| Model Picker | Sheet `ModelPickerSheet` (`.medium` + `.large`) |

Toolbar:
- **Leading**: NavigationStack auto-back chevron (returns to conversation list).
- **Trailing**: a single `Menu` ("ellipsis.circle") containing Compact, Contexts, Conversation Settings. The model-picker chip stays in the composer where it is on Mac; not in the toolbar. This collapses 3 toolbar buttons into one ellipsis menu — iOS-native and saves nav-bar real estate (which is precious on iPhone).

**Rationale**: Push-vs-sheet decisions per §1.2. Ellipsis menu over multiple buttons because iPhone nav-bars get crowded fast and Reeve's nav-bar is already going to carry the conversation title (which can be long, e.g. "Wedding Weekend Tension — $0.27"). Compact + Contexts + Settings are all rare actions — burying them one tap deeper in a Menu is fine.

**Reused**:
- `MarkdownText` (atomic), `ThinkingDisclosure`, `ToolCallDisclosure`, `ToolCallLivePill`, `ModelMetaStrip` (composite) — all already in `ReeveUI`.
- `ConversationViewModel` (already in `ReeveKit`).

**Per-platform**:
- The screen-level scaffolding (status strip, scroll body, composer placement) — fresh in `ReeveiOS/ConversationView.swift`.
- `MessageRow` itself — for now stays per-platform on both Mac AND iOS, because the hover/right-click/keyboard interactions are platform-shaped. *Plan*: extract a shared `MessageBubble` into `ReeveUI/Composite/` that renders the bubble visual (label, content, branch switcher, errored state). Per-platform `MessageRow` wraps it with platform-specific gesture/menu chrome. Defer this extraction to **Phase 5f** (per-message actions); ship Phase 5c with a fresh iOS `MessageRow` first.

**Risks**:
- The Mac's `.padding(.top, 28)` for the title-bar overlay does NOT carry over (§1.6).
- Auto-follow-during-stream + "stop following on user scroll" logic — already shared via `ScrollView.onScrollPhaseChange`. Verify it works the same on iOS (it should; the API is cross-platform).
- Composer keyboard avoidance — see §1.7. ScrollView needs to not get scrolled out of view by the keyboard; SwiftUI handles this if the ScrollView is the safe-area-sized content of the screen.
- "Cost in title" ("Wedding Weekend Tension — $0.27") on Mac uses `.navigationTitle("Title — $X.YY")` + `.navigationSubtitle("Context N")`. iOS NavigationBar doesn't have a subtitle slot natively; need a custom titleView (via `ToolbarItem(placement: .principal)` with a VStack) OR drop the subtitle on iPhone. Decision: drop the subtitle on iPhone — the active context is shown as a chip in the status strip already, so the subtitle is redundant there. Title becomes just "Wedding Weekend Tension"; cost moves into the status strip below as another chip.

### 2.6 ContextListView — Contexts pane

**Mac shape**: Full-pane page-replace. Vertical list of context rows with metadata strip per row; tap activates and dismisses.

**iPhone treatment**: Push `ContextListView` onto the conversation's stack. `List` of context rows. Tap activates the context and **pops back to the conversation** (one-shot select-and-return).

Toolbar: title "Contexts" + auto-back. No trailing actions (no "create new context" action exists today; contexts are server-managed).

**Rationale**: Push because it's drill-deeper into "the conversation's pages." Pop-on-select because the user came here to switch contexts; landing them back on the conversation immediately confirms the switch happened.

**Reused**: `ContextRow` is currently per-Mac. Extract to `ReeveUI/Composite/ContextRow.swift` so iOS reuses the same row visual (title + metadata chips + active-tint).

**Per-platform**: screen scaffolding (List + nav).

**Risks**: None obvious.

### 2.7 CompactView — Compact pane

**Mac shape**: Full-pane page-replace. ScrollView with prompt textarea + model rows + cost preview. Toolbar's confirmation-action slot has the "Compact" button.

**iPhone treatment**: Sheet (`.large` detent, `.presentationDragIndicator(.visible)`). Inside the sheet: `NavigationStack` with title "Compact", leading "Cancel" button (dismisses sheet), trailing "Compact" button (`.borderedProminent`, disabled when invalid). Body = same shape as Mac — prompt section + model section + cost preview, scrollable.

**Rationale**: Compact is a focused action with a clear submit moment ("Compact" button). Sheet pattern matches iOS Mail's compose flow. `.large` detent because the form is multi-section and benefits from full screen real estate; `.medium` would force scrolling for the model picker.

**Reused**:
- `ModelPickerList` (composite) for the model selection.
- The cost preview computation (already in ReeveKit's CompactionViewModel — verify; if it's only in Mac's `CompactView.swift`, extract to ReeveKit).

**Per-platform**: sheet wrapper + nav-bar buttons.

**Risks**:
- Long compaction prompts + small `.large` sheet on iPhone SE = cramped. The textarea needs `.lineLimit(...)` constrained but expandable. iOS's `TextEditor` is fine for this; just give it a min-height and let it grow.
- "Cancel mid-compaction" — if the user taps Cancel while a compaction RPC is in flight, what happens? On Mac, it bails the dialog and the stream eventually delivers a compression message. iOS should match that; sheet dismissal is a UI-only action, not a server cancel.

### 2.8 ConversationSettingsView — in-conversation settings

**Mac shape**: Full-pane page-replace. ScrollView wrapping `CallSettingsForm` (the shared composite). Auto-saves on dismiss.

**iPhone treatment**: Push `ConversationSettingsView` onto the conversation stack. Same body (the shared `CallSettingsForm`). Auto-save on `onDisappear`.

Toolbar: title "Settings" + auto-back. No trailing actions (no manual "Save" — auto-save fires on back-tap via onDisappear).

**Rationale**: Push because it's drill-deeper into "configure this conversation." Auto-save matches Mac behavior; no Save button needed because every field is debounced and persisted on its own.

**Reused**: `CallSettingsForm` (composite, already in ReeveUI).

**Per-platform**: screen scaffolding.

**Risks**:
- `CallSettingsForm` was designed for Mac's wider pane. On iPhone the form is narrower; some segmented pickers (Service Tier, Response Format) might wrap awkwardly. Sanity-check at implementation time; if controls overflow, switch them to inline `Menu` pickers (Menu works on iOS — only the macOS Menu rendering is buggy).

### 2.9 ModelPickerSheet — model picker

**Mac shape**: Full-pane page-replace, ScrollView wrapping `ModelPickerList` (composite). Triggered by tapping the model chip in the composer.

**iPhone treatment**: Sheet (`.presentationDetents([.medium, .large])`, `.presentationDragIndicator(.visible)`). Inside: `NavigationStack` with title "Model" + leading "Cancel" + trailing "Done" (or no trailing — selection auto-closes the sheet, matching Mac's page-replace behavior). Body = `ModelPickerList`.

**Rationale**: Sheet so the conversation stays visible behind it (anchors context). `.medium` detent default for users with few models; `.large` for browsing across many providers. Drag indicator because users swipe to dismiss.

**Reused**: `ModelPickerList` (composite, already shared).

**Per-platform**: sheet wrapper.

**Risks**:
- `.medium` detent renders ~half-screen on iPhone. With 3+ providers each having 3+ models, that's tight. `.large` may need to be the default; user can still resize via the drag handle. Decision at implementation: open at `.medium`, let user pull to `.large`. Track UX over time.

### 2.10 NewConversationView — pre-send compose

**Mac shape**: Full-pane page-replace (in detail). Title field + profile picker + model override + chat settings. Confirmation-action "Start chat" button creates and selects the new conversation.

**iPhone treatment**: Sheet (`.large` detent). Inside: `NavigationStack` with title "New Conversation" + leading "Cancel" + trailing "Start" (`.borderedProminent`, disabled if no profile). Body = same form sections as Mac.

**Rationale**: Sheet because compose is a discrete modal action. `.large` detent because the form is multi-section. Cancel/Start in nav bar is iOS Mail-shaped.

**Reused**: `ProfilePickerRow` (composite, already shared, with `onOpenSettings:` callback). `ModelPickerList` (composite). `CallSettingsForm` (composite).

**Per-platform**: sheet wrapper + nav-bar buttons.

**Risks**:
- "Open Profile in Settings" callback (the `onOpenSettings:` we wired in Phase 0 for `ProfilePickerRow`) — on Mac, this jumps the navigator to settings + Profiles + selects the profile. On iOS with a sheet open, jumping to settings means dismissing the sheet first. Implementation: dismiss the sheet, then trigger a `Navigator`-equivalent for iOS that switches to the Settings tab + pushes the Profiles stack to that profile. The `Navigator` type itself stays Mac-only (it carries Mac chrome state); iOS gets its own `iOSNavigator` with the same conceptual roles (`pendingProfileSelection`, `pendingConversationSelection`, etc.).

### 2.11 WelcomeView — empty detail pane

**Mac shape**: Centered placeholder shown when no conversation is selected, with "New Conversation" CTA.

**iPhone treatment**: **Replaced by an inline empty-state in the conversation list**. When `conversations.isEmpty`, the list root shows a centered VStack with the icon + "Welcome to Reeve" + "Tap + to start a chat" + a `.borderedProminent` "New Conversation" button.

Once any conversation exists, the list shows that conversation; tapping it pushes the conversation view. There's no "I'm not in any conversation" intermediate state because iPhone navigation is push-based — you're either at the list (root) or in a specific conversation.

**Rationale**: iPhone has no "split view detail pane" to fill. Welcome on Mac fills empty space; on iPhone there IS no empty space.

**Reused**: `EmptyStateView` (composite, already shared) for the icon+title+description chrome; the iOS root composes it with the New Conversation button.

**Per-platform**: composition into the list root.

**Risks**: None.

### 2.12 MessageRow — message bubble + per-row affordances

**Mac shape**: Message bubble with role-aligned width-cap, hover-actions pill (Edit / Reload / Copy / Delete), context menu, branch switcher chevrons (visible-on-hover), edit-in-place state.

**iPhone treatment**: Message bubble with the same role-aligned width-cap shape. Hover-actions pill replaced by:

- **Long-press → context menu**: Edit, Reload (assistant only), Copy, Delete. Shared `.contextMenu` declaration.
- **Branch switcher chevrons**: always visible on assistant messages with siblings (low-contrast, small). Tap to navigate; long-press the chevron block reveals a menu of all sibling indices.
- **Edit-in-place**: same flow — tapping Edit replaces the bubble with a TextField + Save/Cancel buttons inline. Identical to Mac, just no `Esc` to cancel (use the Cancel button).
- **Message Usage Popover** (info icon tap) → iOS `.popover` works on iPhone but reads as iPad-shaped; better to use a sheet (`.medium` detent). Tap the small chip beneath the bubble → sheet slides up with the usage breakdown.

**Rationale**: §1.3 (long-press for hover replacement). Branch switcher always-visible because hiding it behind interaction makes it invisible on touch (no hover signal).

**Reused**:
- `MarkdownText` (atomic).
- `ThinkingDisclosure` (composite).
- `ToolCallSettledDisclosure` (composite).
- `ModelMetaStrip` (composite, used in the usage popover).

**Per-platform**: `MessageRow` itself is per-platform on both Mac and iOS for now (different gesture chrome). **Eventual plan** (deferred to Phase 5f): extract `MessageBubble` to `ReeveUI/Composite/` that renders the bubble shell (label, content, branch switcher, edit state). Per-platform `MessageRow` becomes a thin wrapper that adds platform-specific gestures (hover on Mac, swipe-actions on iOS).

**Risks**:
- iOS `.contextMenu` requires the modifier to be on a `.contentShape`-defined region. The bubble's existing layout supports this; verify the long-press gesture doesn't accidentally trigger on streaming bubbles (where gestures could interrupt the live update).
- Edit-in-place TextField on iPhone: needs `.focused($editing)` plus `Done` toolbar button on the keyboard, plus dismissing-keyboard-on-Save. Standard pattern.
- `.popover` falling back to sheet on iPhone — verify the iOS-26 popover behavior; if it auto-adapts to a sheet, the code is identical to Mac's popover usage.

### 2.13 MessageUsagePopover — usage details overlay

**Mac shape**: Popover triggered from a small info chip on the message row. Sections for Model / Tokens / Cache / Cost.

**iPhone treatment**: Sheet (`.medium` detent, `.presentationDragIndicator(.visible)`). Same content layout. Triggered by tapping the same small chip on the bubble.

**Rationale**: §1.2 (sheet over popover on iPhone).

**Reused**: The internal `section()` + `row()` helpers are simple enough to live alongside the iOS view; no extraction needed.

**Per-platform**: Sheet wrapper. The body content (section/row helpers) is small enough to duplicate or extract to `ReeveUI/Composite/MessageUsageContent.swift` if a future iOS/Mac/iPad audit calls for it. Defer.

**Risks**: None.

### 2.14 SettingsView — three-column shell

**Mac shape**: `HSplitView` with categories sidebar | items list | detail pane. Sidebar groups data categories (Providers / Profiles / Plugins) above app categories (Appearance / Notifications) under a SETTINGS header.

**iPhone treatment**: Settings tab's `NavigationStack` root = a single `List` of categories (no horizontal split, no separate items column). Drill-down model:

- Tap **Providers** → push `ProvidersListView` (iOS rendering of Mac's middle column for Providers)
- Tap **Profiles** → push `ProfilesListView`
- Tap **Plugins** → push `PluginsListView`
- Tap **Appearance** → push `AppearanceDetailView` directly (skip middle list — only one section)
- Tap **Notifications** → push `NotificationsDetailView` directly

The "items list" middle column from Mac becomes the second-level `NavigationStack` destination. The "detail pane" becomes the third-level destination, pushed from the items list.

For Appearance and Notifications which currently have only one sub-section each, we collapse the middle list and push directly to the detail. If/when those grow more sub-sections, we revisit (cheap re-organization).

**Rationale**: iPhone has no horizontal split. NavigationStack drill-down is iOS Settings.app's pattern and the most-recognized iOS configuration shape. Categories list with section headers preserves the Mac's logical grouping (data above app-prefs, divided by header).

**Reused**: `SettingsCategory` enum (already shared via Phase 0 candidate) and the `EmptyStateView` for empty subscreens.

**Per-platform**: Screen scaffolding (List, drill-down).

**Risks**:
- Mac's "selected category persists across launches" comes from app launch landing on the same `category` state. iOS NavigationStack restores `NavigationPath` automatically with state restoration — confirm behavior, ensure it doesn't get in the way. Probably fine; if not, just don't restore (settings rarely needs deep-state restoration).
- Sub-section navigation (e.g. AppearanceSection.theme, NotificationsSection.generationFinished) was Mac's "middle column" — iOS skips it for one-section categories. For multi-section future, re-add as a List between top-categories and detail.

### 2.15 ProvidersView — providers category

**Mac shape**: Middle column = list of configured + available providers; detail = ProviderDetailForm (Enabled Models / Discover Models / Default Settings tabs).

**iPhone treatment**: Push `ProvidersListView` (List of configured providers, with available providers as a separate section below). Tap a configured provider → push `ProviderDetailView`. Tap an available provider → present `AddProviderForm` as a sheet (`.large`). Tap the "+" toolbar button → present `AddProviderForm` (custom preset) as a sheet.

`ProviderDetailView` body = three sections shown via a top `Picker(.segmented)`: Models / Discover / Settings. Same conceptual three Mac tabs, rendered as the iOS-native segmented control inline.

Toolbar trailing on `ProvidersListView`: "+" → `AddProviderForm` sheet.

Toolbar trailing on `ProviderDetailView`: ellipsis `Menu` with Test (the existing test-connection action), Delete (destructive, confirmation-required).

**Rationale**: The Mac's three top-bar tabs become iOS's segmented control — same visual paradigm, iOS-native control. Detail-add-as-sheet matches iOS-Mail's "compose new" pattern.

**Reused**:
- `ProviderLogo` (composite, already cross-platform after Phase 0).
- `CallSettingsForm` (for the Default Settings segment).
- `ModelMetaStrip` (composite, already shared) for the per-model rows.

**Per-platform**: List/detail screens; segmented picker chrome.

**Risks**:
- "Discover Models" is the per-provider model fetch + enable flow. Heavy interactions (toggle each model on/off, see API metadata for each). The Mac UI has dedicated rows; on iPhone, narrower rows + smaller toggles. Sanity check at implementation time.
- The provider "Test" action: returns OK / Error popover on Mac. On iOS, can use `.alert` for the result.

### 2.16 ProfilesView — profiles category

**Mac shape**: Middle column = list of profiles with parent breadcrumb in caption. Detail = ProfileViewer (read-only) or ProfileForm (editing).

**iPhone treatment**: Push `ProfilesListView` (List of profiles, parent chain shown in row caption). Tap a profile → push `ProfileViewer`. ProfileViewer trailing toolbar: "Edit" → push `ProfileForm`. Toolbar trailing on `ProfilesListView`: "+" → present `ProfileForm` (new profile) as a sheet (`.large`).

**Rationale**: Drill-down read-then-edit is iOS-Settings.app pattern. Edit-as-push (not sheet) because the user came here to drill deeper; sheet would feel like a different mental mode. Add-as-sheet (not push) because creating a new thing is a discrete action.

**Reused**:
- `ProfileCard` and `NoneProfileCard` (composite, already shared) — for both the picker row inside ProfileForm and inline previews.
- `ModelPickerList` (composite) for the three default-model sections (default / compression / title).
- `CallSettingsForm` (composite) for the chat settings section.
- `PluginConfigForm` (composite) for per-profile plugin overrides.

**Per-platform**: List/viewer/form screens.

**Risks**:
- ProfileForm is enormous (1500+ lines on Mac, lots of nested forms). On iPhone, every collapsible section needs to default-collapsed to keep the screen scrollable — Mac's expanded-by-default approach won't work. Use `DisclosureGroup` for the model-picker sections and the plugin overrides.
- Inherit-from-parent previews: render as muted captions ("inherits: Claude Sonnet 4.6") rather than separate badges. Already the Mac pattern.
- The three model-picker sections (default model, compression model, title model) each currently expand inline on Mac. On iPhone, each becomes a `NavigationLink` that pushes a per-section model picker (with the "Inherit" affordance at the top). Cleaner stack.

### 2.17 PluginSettingsView — plugins category

**Mac shape**: Middle column = list of plugins (warning icon if required globals unset). Detail = PluginSettingsForm (PluginConfigForm + per-profile note).

**iPhone treatment**: Push `PluginsListView` (List of plugins; warning icon trailing if required globals unset). Tap a plugin → push `PluginSettingsView` containing the `PluginConfigForm` + a banner explaining per-profile vs global scope.

Toolbar trailing on `PluginsListView`: nothing (plugins are server-managed; no "+").

**Rationale**: Same drill-down pattern as Providers/Profiles. Per-profile note explains where to find profile-scoped plugin settings (cross-link to Profiles).

**Reused**: `PluginConfigForm` (composite, already shared).

**Per-platform**: List/form screens.

**Risks**:
- Auto-save on field change (the Mac pattern) needs careful handling with iOS keyboard focus. When the user is editing a TextField and rotates the screen / backgrounds the app / switches tabs, the in-flight save shouldn't drop edits. Same `Task` debounce as Mac, plus a save-on-disappear belt-and-braces.

### 2.18 AppearanceSettingsView — theme picker

**Mac shape**: LazyVGrid of ThemeCard tiles (adaptive 280–360pt wide). Click a card → instant theme apply.

**iPhone treatment**: Push `AppearanceDetailView` (skipping the one-item middle list). Body = a scrollable `LazyVGrid` of ThemeCard tiles, sized for iPhone (probably 1-column on iPhone SE, 2-column on Pro Max — `GridItem(.adaptive(minimum: 280))` handles it). Tap a card → instant theme apply, no navigation away.

**Rationale**: Theme card grid translates 1:1 from Mac to iOS. Adaptive grid scales gracefully across iPhone widths.

**Reused**: ThemeCard (extract to `ReeveUI/Composite/ThemeCard.swift` so iOS reuses the same card visual). Currently lives in `ReeveMac/AppearanceSettingsView.swift`.

**Per-platform**: Screen scaffolding (NavigationStack destination + grid composition).

**Risks**: None significant. The theme cards include preview message bubbles — those should render fine on iPhone (the cards are self-contained).

### 2.19 NotificationsSettingsView — notifications toggle

**Mac shape**: One Toggle for "Ring on generation finish", with explanatory caption.

**iPhone treatment**: Push `NotificationsDetailView` (skipping the one-item middle list). Body = a `Form` with a single Toggle in a section. iOS-native `Form` styling (rounded sections with separators) matches iOS Settings.app expectations.

**Rationale**: One toggle = use `Form` for iOS-Settings-app feel.

**Reused**: `AppPreferences.notifyOnUnfocusedCompletion` (already cross-platform).

**Per-platform**: Screen scaffolding.

**Risks**:
- Permission prompt on first toggle-to-on: Mac's flow is "permission requested on first notification that would fire." iOS should match — but the user might toggle-on and never get a notification (because they're never backgrounded mid-stream). Consider an upfront permission prompt on toggle-to-on to surface the system dialog immediately. Decision: prompt on toggle-to-on (matches iOS Mail's behavior — turning on notifications immediately requests permission).

### 2.20 PendingUserRow — optimistic user message

**Mac shape**: Right-aligned bubble shown while send RPC is in flight; semi-transparent.

**iPhone treatment**: Same shape, same opacity, in the iOS `MessageRow` adjacent space. Renders identically on both platforms.

**Rationale**: Trivial — no Mac-specific anything.

**Reused**: This row is currently in `ReeveMac/ConversationView.swift`. Extract to `ReeveUI/Composite/PendingUserRow.swift` since both platforms use it.

**Per-platform**: nothing.

**Risks**: None.

### 2.21 CompressionSummaryCard — compaction result

**Mac shape**: Orange-tinted card with success/failure variants. Buttons: Edit / Delete / Confirm (success); Dismiss (failure).

**iPhone treatment**: Same card visual. Buttons same, but Delete is a destructive `.alert`-confirmed action; Edit pushes an inline editor or a sheet (TBD when implementing).

**Rationale**: Visual is the same. Only the destructive-confirm UX is iOS-shaped (`.alert(role:)` with `Button(role: .destructive)`).

**Reused**: Extract `CompressionSummaryCard` to `ReeveUI/Composite/`. Mac and iOS both render it.

**Per-platform**: confirm-alert chrome.

**Risks**: None.

### 2.22 StreamingRow — live assistant streaming

**Mac shape**: Left-aligned bubble, MarkdownText for streamed text, optional thinking disclosure, optional tool-call live pills, cost badge.

**iPhone treatment**: Same shape. Already partially shared (the disclosures are in `ReeveUI/Composite/`).

**Rationale**: Cross-platform.

**Reused**: `MarkdownText`, `ThinkingDisclosure`, `ToolCallLivePill`. Extract `StreamingRow` itself to `ReeveUI/Composite/` once iOS needs it.

**Per-platform**: gesture wrapping (the Mac MessageRow swallows the streaming row into its hover/select model; iOS wraps it the same way).

**Risks**:
- ScenePhase backgrounding mid-stream — see §1.8. The streaming row's TimelineView will pause when the app is backgrounded (no rendering happens), and the live pills will resume from the right elapsed time when foregrounded (because their data comes from `chunk.firstSeenAt` timestamps, not local timers).

### 2.23 Composer — text input + model chip + send

**Mac shape**: TextField (vertical axis, 1-8 lines), model chip on the left of the control row, Send button on the right (glass-prominent). `shift+Return` for newline; `Return` for send.

**iPhone treatment**: TextField (vertical axis, 1-8 lines), pinned to bottom of the screen above the keyboard. Control row: model chip on left (taps → ModelPickerSheet, see §2.9), Send button on right.

Differences from Mac:
- **Return inserts a newline** (no shift modifier on iPhone). Send is the explicit Send button or the keyboard's blue Send key (via `.submitLabel(.send)`).
- **Stop button** when streaming: the Send button morphs into a Stop button (filled square icon) that cancels the stream when tapped. Same shape as Mac.
- **Keyboard avoidance**: SwiftUI handles the composer being above the keyboard; the message scroll above shrinks accordingly.
- **Mic button** (future): when the composer text is empty, the Send button could swap to a mic icon for STT input. **Defer** to multi-modal Phase 0; placeholder lives in the composer chrome with a clear extension point.

**Rationale**: iPhone composer is bottom-anchored; that's where the keyboard comes from and where users expect the input. Send-as-button-not-Return is more thumb-friendly.

**Reused**: `ProviderLogo` (composite, already shared) for the model chip's provider icon. `ModelPickerSheet` (per §2.9).

**Per-platform**: composer chrome (the `GlassEffectContainer` capsule is shared; the keyboard plumbing is iOS-specific).

**Risks**:
- Composer focus on conversation switch: Mac auto-focuses on appear and on conversation switch. iOS should match — `@FocusState` on the TextField, set true on `.task(id: conversation.id)`. Verify that doesn't interfere with the keyboard avoidance (it shouldn't; focus drives the keyboard up).
- Pasting long text: iOS handles this fine via the system paste menu. The model chip + send button stay anchored regardless of TextField size.
- Stop button hit-target: needs to be at least 44×44pt per Apple HIG. The current Send button on Mac is smaller; iOS makes the Send/Stop button generous on iPhone.

---

## 3. Per-screen ReeveUI usage

Quick reference table — which shared `ReeveUI/Composite/` views each iOS screen consumes.

| iOS screen | Reused composites |
|---|---|
| LoginView (P1+P2) | — |
| ChatsRoot (TabView) | — |
| ConversationListView (iOS) | `ProfileCard` (for By Profile mode), `ConversationRow` (to extract) |
| ConversationView (iOS) | `MarkdownText`, `ThinkingDisclosure`, `ToolCallSettledDisclosure`, `ToolCallLivePill`, `ModelMetaStrip`, `MessageBubble` (to extract) |
| ContextListView (iOS) | `ContextRow` (to extract) |
| CompactView sheet | `ModelPickerList` |
| ConversationSettingsView (iOS) | `CallSettingsForm` |
| ModelPickerSheet | `ModelPickerList` |
| NewConversationSheet | `ProfilePickerRow`, `ModelPickerList`, `CallSettingsForm` |
| MessageRow (iOS) | `MarkdownText`, `ThinkingDisclosure`, `ToolCallSettledDisclosure`, `ModelMetaStrip` |
| MessageUsageSheet | (helpers; potentially `MessageUsageContent` to extract) |
| SettingsRoot (iOS) | — |
| ProvidersListView (iOS) | `ProviderLogo` |
| ProviderDetailView (iOS) | `ProviderLogo`, `ModelMetaStrip`, `CallSettingsForm` |
| AddProviderForm sheet | `ProviderLogo` |
| ProfilesListView (iOS) | — |
| ProfileViewer (iOS) | `ProfileCard`, `ProviderLogo` |
| ProfileForm (iOS) | `ProfilePickerRow`, `ModelPickerList`, `CallSettingsForm`, `PluginConfigForm` |
| PluginsListView (iOS) | — |
| PluginSettingsView (iOS) | `PluginConfigForm` |
| AppearanceDetailView (iOS) | `ThemeCard` (to extract) |
| NotificationsDetailView (iOS) | — |

**To-extract list** (work for Phase 5 sub-phases):
- `ConversationRow` — list row visual. Extract from Mac `ConversationListView.swift`.
- `ContextRow` — context list row. Extract from Mac `ContextListView.swift`.
- `MessageBubble` — bubble shell (label + content + branch switcher + edit state). Extract from Mac `ConversationView.swift::MessageRow`.
- `PendingUserRow` — optimistic user bubble. Extract from Mac `ConversationView.swift`.
- `CompressionSummaryCard` — compaction result card. Extract from Mac `ConversationView.swift`.
- `StreamingRow` — live assistant streaming bubble. Extract from Mac `ConversationView.swift`.
- `ThemeCard` — theme tile. Extract from Mac `AppearanceSettingsView.swift`.
- `MessageUsageContent` (optional) — usage popover/sheet body. Extract on demand.

These extractions should happen as Phase 5 sub-phases reach each screen — not bulk-upfront. Each extraction is a Mac-side refactor that doesn't change Mac behavior; verified by running the Mac app + Layer-2 snapshot tests after each move.

---

## 4. Cross-cutting concerns

Things that don't fit cleanly under one screen but matter for the whole iOS surface.

### 4.1 ScenePhase

`@Environment(\.scenePhase)` in `ReeveiOSApp` plus `.onChange(of: scenePhase)` to fire suspend/resume on any active conversation:

```swift
.onChange(of: scenePhase) { _, newPhase in
    switch newPhase {
    case .background, .inactive:
        appModel.suspendActiveStreams()
    case .active:
        Task { await appModel.resumeStreamsIfPaused() }
    @unknown default:
        break
    }
}
```

Implementation lives in `ReeveKit` (so Mac inherits the no-op behavior; Mac never backgrounds the same way iOS does, but the API is harmless to call).

### 4.2 Keyboard handling

- `.scrollDismissesKeyboard(.interactively)` on the conversation message scroll.
- `.submitLabel(.send)` on the composer TextField, with `.onSubmit { send() }`.
- `.toolbar` keyboard accessory with a "Done" button to dismiss focus from composer or any form field.
- Login form: `.submitLabel(.next)` on username, `.submitLabel(.go)` on password, with `.onSubmit { focused = .password }` / `.onSubmit { Task { await submit() } }` chains. Already done in iOS LoginView.

### 4.3 Pull-to-refresh

`.refreshable { await convos.refresh() }` on:
- ConversationListView root.
- ConversationView's message scroll.
- ProvidersListView (refresh provider list).
- ProfilesListView (refresh profile list).

Async-await native; SwiftUI handles the refresh control rendering.

### 4.4 Swipe gestures and context menus

- Conversation list rows: `.swipeActions(edge: .trailing) { Button(role: .destructive) { Delete } }`.
- Message bubbles: long-press → `.contextMenu` (Edit, Reload, Copy, Delete).
- Provider rows: trailing swipe → Delete (destructive). Plus context menu for Edit / Test / Discover.

Edge-swipe-back on NavigationStack is automatic; no opt-in needed.

### 4.5 Long-press menus

The iOS implementation of `.contextMenu` is identical to Mac's right-click. SwiftUI `.contextMenu { … }` works on both. When extracting `MessageBubble` to `ReeveUI/Composite/`, declare the context menu items inside the shared view; Mac and iOS both inherit the same menu.

### 4.6 Dynamic Type

iOS users get app-wide font scaling for free via the system Dynamic Type setting. Every `.font(.body)` / `.font(.callout)` / `.font(.caption)` already in `ReeveUI` scales automatically; nothing to wire. The exception is `.font(.system(size: N))` literal sizes in `ReeveUI` (sparingly used) — those don't scale. Audit pass at end of Phase 5: where font size matters for legibility (message body, list rows), prefer semantic fonts; only use literal sizes for chrome elements (icons, badges).

### 4.7 Accessibility

Floor commitment: every interactive element has a meaningful VoiceOver label. Audit:
- Icon-only buttons (`Image(systemName: …)` inside a `Button`) need `.accessibilityLabel("Description")`.
- Bubbles need a role-prefixed announcement: "User message: …" / "Assistant message: …" via `.accessibilityElement(children: .combine)` + `.accessibilityLabel`.
- Streaming bubbles need a "still streaming" indicator for VoiceOver — `.accessibilityValue("\(percentComplete) percent complete")` if estimable, else just "loading".
- Form fields use `.accessibilityHint` for non-obvious behavior (e.g. "Test connection — probes the URL to confirm it's a Reeve server").

Implement during Phase 5 as each screen lands; final audit pass before tagging Phase 5 complete.

### 4.8 Notifications: iOS Notifier impl

`ReeveiOS/Platform/iOSNotifier.swift` (mirrors `ReeveMac/MacNotifier.swift`):

```swift
@MainActor
final class iOSNotifier: NSObject, UNUserNotificationCenterDelegate, Notifier {
    private let prefs: AppPreferences
    private let navigator: iOSNavigator

    init(prefs: AppPreferences, navigator: iOSNavigator) { … }

    func generationCompleted(conversationID:, conversationTitle:, messageID:, preview:) {
        guard prefs.notifyOnUnfocusedCompletion else { return }
        if UIApplication.shared.applicationState == .active { return }
        ensurePermission { granted in
            guard granted else { return }
            self.deliver(...)
        }
    }

    // Tap-to-focus
    func userNotificationCenter(_ center:, didReceive response:, withCompletionHandler:) {
        completionHandler()
        let convID = response.notification.request.content.userInfo["conversation_id"] as? String
        Task { @MainActor in
            navigator.pendingConversationSelection = convID
        }
    }
}
```

Wired in `ReeveiOSApp`:
```swift
.environment(\.notifier, sharedNotifier)
```

Identical to the Mac wiring done in Phase 1. The `UIApplication.shared.applicationState` check (vs Mac's `NSApp.isActive`) is the only platform divergence.

### 4.9 Haptics

`ReeveiOS/Platform/Haptics.swift`:

```swift
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func notify(_ kind: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(kind)
    }
}
```

Sites:
- `Haptics.impact()` on send button press in composer.
- `Haptics.notify(.warning)` on conversation/message delete confirmation.
- `Haptics.notify(.success)` on login success.
- `Haptics.impact(.light)` on context-menu open (iOS does this automatically — opt-out check needed).

Defer to a `ReeveUI/Atomic/` extraction only when a second platform (visionOS, etc.) needs the same hook.

### 4.10 Search

`.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))` on:
- Conversation list root (filters conversations).
- Providers list root (filters providers).
- Profiles list root (filters profiles).

Drawer placement keeps the search field above the list when scrolled to top, collapses out of sight when scrolled. Standard iOS search pattern.

For the conversation list specifically, the existing search-mode logic on Mac (which switches from list to search-results) is replaced by `.searchable` filtering the same list in place. Cleaner UX.

### 4.11 State restoration (deferred)

iOS has built-in NavigationPath state restoration via `.navigationDestination` + `Codable` paths. Tempting to wire from day one; deferred to first ship + 1. The cost of NOT having it: app cold-launch lands on the conversation list root, not deep inside whatever conversation the user was in. Acceptable for v1; users open the same conversation again with one tap.

---

## 5. iPad treatment (Phase 6)

iPad gets a single binary (no separate Xcode target) with `horizontalSizeClass`-driven shape switching:

- **Compact** (iPad in split-screen, iPhone everywhere): the iPhone shape — `TabView` + `NavigationStack`s.
- **Regular** (iPad in full-screen, iPad Mini portrait): a different shape with `NavigationSplitView`.

Regular shape:

```swift
NavigationSplitView {
    // Sidebar: conversation list (search + segmented mode picker + list)
    ConversationListView()
} detail: {
    if let selected = navigator.selectedConversation {
        ConversationView(conversation: selected)
    } else {
        WelcomeView()  // resurrected from Mac for iPad
    }
}
```

So iPad regular gets the Welcome screen back. iPhone (and iPad compact) does without. Settings on iPad regular = sheet over the split view (instead of a tab) — matches iPad Mail's pattern.

For the conversation view's child screens (Contexts, Compact, Conversation Settings, Model Picker), iPad regular keeps them as the iPhone treatment (push/sheet). Theoretically iPad could put them in a third column; that's deferred until a second user with an iPad complains.

The implementation strategy: Phase 5 ships iPhone-only. Phase 6 wraps iPhone screens in a `Group` + `if horizontalSizeClass == .regular` that swaps in the `NavigationSplitView` shell. The interior screens (ConversationView body, settings drill-down screens) reuse the iPhone implementations verbatim — no fork.

---

## 6. Implementation sequencing

Concrete sub-phases inside Phase 5 (conversations) and Phase 7 (settings). Each sub-phase is roughly a half-day to a day of work; ship-and-test each one before moving to the next.

### Phase 5 — iOS conversations (iPhone)

**5a — TabView shell + Chats tab scaffold** (~half day)
- `TabView` with two tabs in `RootView`'s authenticated branch.
- `ChatsRoot` (NavigationStack) with toolbar (avatar + "+") and a placeholder empty state.
- `SettingsRoot` placeholder.
- Verify auth flow → tab shell renders.

**5b — Conversation list** (~1 day)
- Extract `ConversationRow` from Mac to `ReeveUI/Composite/ConversationRow.swift`. Verify Mac still works (Layer-2 snapshot tests).
- iOS `ConversationListView` with: `.searchable`, segmented mode picker, sectioned/grouped list per mode, `.swipeActions` for delete, `.contextMenu` for Edit/Delete, `.refreshable` for pull-to-refresh.
- Tap row → push (placeholder) `ConversationView`.
- Empty state ("Welcome to Reeve" + "+" CTA).

**5c — Conversation view: messages + scroll** (~1 day)
- Skeleton `ConversationView` with `ConversationViewModel` injection.
- Status strip (cost chip, context selector chip).
- Message scroll (`ScrollView` + `LazyVStack`).
- iOS `MessageRow` (per-platform) consuming `MarkdownText`/`ThinkingDisclosure`/`ToolCallSettledDisclosure`/`ModelMetaStrip` from ReeveUI.
- Pending user row + compression summary card (extracted to ReeveUI in this sub-phase).
- Streaming row (extracted to ReeveUI in this sub-phase).
- Auto-follow scroll behavior (already shared via the scroll-phase machinery).
- Pull-to-refresh refetches messages.

**5d — Composer** (~half day)
- Bottom-anchored `TextField` with model chip + Send button.
- `.submitLabel(.send)`, keyboard "Done" toolbar accessory.
- Send button morphs to Stop while streaming.
- Composer focus on view appear / conversation switch.
- Verify keyboard avoidance: scroll content shifts, send button stays above keyboard.

**5e — Streaming + ScenePhase** (~half day)
- Implement `ConversationViewModel.suspendStreamIfActive()` / `resumeStreamIfPaused()` in ReeveKit.
- Wire `ScenePhase` observer in `ReeveiOSApp`.
- Test: start a long-running stream, background the app, foreground — stream resumes from missed sequence.

**5f — Per-message actions** (~1 day)
- Extract `MessageBubble` to `ReeveUI/Composite/MessageBubble.swift`. Per-platform `MessageRow` becomes a thin wrapper.
- Long-press `.contextMenu` on bubbles: Edit, Reload (assistant only), Copy, Delete.
- Edit-in-place: TextField + Save/Cancel inline (replaces bubble while editing).
- Branch switcher: always-visible chevrons on assistant siblings.
- Message Usage Sheet: tap info chip → sheet (`.medium` detent).

**5g — Page-replace screens (Contexts / Compact / Conversation Settings / Model Picker)** (~1 day)
- Extract `ContextRow` to `ReeveUI/Composite/`.
- Push `ContextListView` from conversation; pop-on-select.
- Sheet `CompactView` (`.large` detent) from conversation toolbar Menu; nav-bar Cancel / Compact buttons.
- Push `ConversationSettingsView`; auto-save on `.onDisappear`.
- Sheet `ModelPickerSheet` (`.medium` + `.large` detents) from composer chip; auto-close on select.

**5h — New Conversation sheet** (~half day)
- Sheet (`.large` detent) presented from `ChatsRoot`'s "+".
- Form sections: title, profile picker, model override, chat settings.
- Cancel / Start nav-bar buttons.
- "Open Profile in Settings" callback dismisses sheet + switches to Settings tab + pushes Profiles + selects.

**5i — Polish + accessibility audit** (~1 day)
- VoiceOver labels on every icon-only button.
- Haptics on send / delete / login success.
- `.refreshable` everywhere applicable.
- Snapshot tests for iOS (extend the existing harness with iPhone sizes — Phase 5 plan-table item #6 from `ios-plan.md`).

**Phase 5 total: ~7 days**.

### Phase 7 — iOS settings (iPhone)

**7a — Settings tab shell + categories list** (~half day)
- `SettingsRoot` = `List` of categories (Providers / Profiles / Plugins / Appearance / Notifications) with section header for SETTINGS subdivision.

**7b — Providers screen** (~1.5 days)
- Push `ProvidersListView` (configured + available sections).
- Push `ProviderDetailView` with segmented picker (Models / Discover / Settings).
- Sheet `AddProviderForm` from "+" toolbar.
- `Picker(.segmented)` for the three detail tabs.

**7c — Profiles screen** (~2 days)
- Push `ProfilesListView`.
- Push `ProfileViewer` with Edit toolbar button.
- Push `ProfileForm` (from Edit OR sheet from "+").
- DisclosureGroup-based collapsible sections inside the form.
- Sub-screens for each model picker section (default / compression / title).

**7d — Plugins screen** (~1 day)
- Push `PluginsListView`.
- Push `PluginSettingsView` (`PluginConfigForm` + per-profile note).
- Auto-save on field change.

**7e — Appearance screen** (~half day)
- Extract `ThemeCard` to ReeveUI.
- Push `AppearanceDetailView` (theme grid, adaptive columns).

**7f — Notifications screen** (~half day)
- Push `NotificationsDetailView` (Form with single toggle).
- Toggle-on prompts permission.

**Phase 7 total: ~5.5 days**.

### Phase 8 — Background + reconnect

**8a — ScenePhase wiring** (~half day) — covered in Phase 5e.

**8b — iOS Notifier impl** (~half day)
- `ReeveiOS/Platform/iOSNotifier.swift`.
- Wire into `ReeveiOSApp` env injection.
- Tap-to-focus routes through iOSNavigator's `pendingConversationSelection`.

**8c — `iOSNavigator`** (~half day)
- Mirror `Mac/Navigator` shape: `pendingConversationSelection`, `pendingProfileSelection`, plus iOS-specific `selectedTab` (Chats / Settings) + tab-stack `NavigationPath`s.
- Wire into the TabView roots so cross-tab jumps work (e.g. notification tap → Chats tab → push conversation; "Open in Settings" from sheet → dismiss sheet → Settings tab → push Profiles → select profile).

**Phase 8 total: ~1.5 days**.

### Phase 6 — iPad fork

**6a — `horizontalSizeClass` switching** (~1 day)
- Wrap `RootView`'s authed branch in a `horizontalSizeClass` switch.
- iPad regular → `NavigationSplitView` with sidebar = ConversationList, detail = ConversationView (or Welcome).
- iPad compact → existing iPhone TabView shape.

**6b — iPad Welcome resurrection** (~half day)
- Restore `WelcomeView` (or its descendant) from Mac for the iPad detail-pane "no selection" state.

**6c — Settings as sheet on iPad regular** (~half day)
- Settings tab still exists in compact; in regular, swap the tab for a toolbar button that presents Settings as a sheet.

**Phase 6 total: ~2 days**.

### Cumulative

Phase 5 + 7 + 8 + 6 = **~16 days** of focused iOS work. Front-loaded: Phase 5 is the bulk; subsequent phases are smaller because they reuse the patterns established in Phase 5.

---

## 7. Open threads + deferrals

Things this plan deliberately doesn't decide. Listed here so they're not forgotten when their phase lands.

### 7.1 Watch companion (post-1.0)

Read-only conversation list + mic-to-reply. Reeves directly onto `ConversationViewModel` (already shared). Watch app is its own scene tree but data flow is shared. Defer until iOS app is stable.

### 7.2 Share Extension

"Send to Reeve" from Safari / Mail / Messages. Bundles the existing Repository for "create conversation, send this text." Extension shell is iOS-only; the action is shared. Phase 9+.

### 7.3 Spotlight + SiriKit + Shortcuts

Surface conversations + send-message intents. All hangs off existing ReeveKit RPCs. App Intents framework is the path. Defer.

### 7.4 Push notifications (server-side)

Out of scope. Data model already supports it (`stream_runs.status` flips terminal at materialization, per-user push-token table + a server hook on terminal status fires the push). iOS app handles APN delivery + routes via existing notifier flow. Distinct project.

### 7.5 STT / TTS / multi-modal

Per `multimodal-plan.md`. Phase 0 of multi-modal (local TTS + STT) shares ~70% with Mac. Composer mic button is the iOS entry point — already noted in §2.23. Implement after Phase 5 ships.

### 7.6 Live Activities + Dynamic Island

iOS-only. Stream progress in the Dynamic Island would be a great fit ("Claude is responding… 47s elapsed"). Defer until the app exists; explore as polish.

### 7.7 iCloud sync of preferences

Theme + notification toggle + (if added later) the multi-server list. NSUbiquitousKeyValueStore is the right primitive. Defer.

### 7.8 Background streaming continuation via BGTaskScheduler

The §1.8 ScenePhase approach handles foreground/background with chunk replay. A more aggressive approach: register a `BGProcessingTask` that polls for stream completion + delivers a notification *while the app is suspended*. Useful for very long agentic-harness turns. Defer to Phase 8+1.

### 7.9 Per-message swipe actions

Today: long-press → context menu only. iOS users may expect leading swipe → Reply or trailing swipe → Delete on bubbles. Defer; gather feedback after first ship.

### 7.10 NavigationSplitView scrolling-during-stream pin

Mac's auto-follow during stream relies on ScrollView's auto-scroll-to-bottom. On iPhone the keyboard interacts with this — when the keyboard opens, content shifts; need to verify auto-follow still tracks correctly. Test during Phase 5e.

### 7.11 In-app rating prompt

Standard iOS app courtesy. After N successful conversations, request a rating. Defer; unrelated to core function.

### 7.12 The "log out → change server → log in" friction

§1.1's decision to skip multi-server config means switching servers is "log out, change server URL, log back in." If users complain, revisit. Tracked in `ios-plan.md` "Server connection" section.

### 7.13 Tablet vs iPad regular boundary

iPad mini in portrait is the borderline case — `horizontalSizeClass` reports compact in portrait, regular in landscape. The shape will switch on rotation. Acceptable behavior; document so users aren't surprised.

### 7.14 Snapshot test sizes

iOS snapshot harness needs at minimum: iPhone SE (smallest), iPhone Pro, iPhone Pro Max, iPad Pro 13" (regular layout), iPad Mini portrait (compact in iPad form). Five sizes per visual; manageable. Phase 5i sets up the harness; subsequent phases add per-screen snapshots.

---

## How to use this doc

This plan is the playbook for Phase 5 onward. When a phase begins:

1. Open this doc to the relevant §2 entry for the screen being built.
2. Cross-check the §3 ReeveUI usage table for any extractions needed first.
3. Implement the iOS screen, following the per-screen treatment.
4. Add snapshot tests per §7.14.
5. Ship the sub-phase; mark off in §6 sequencing.

When divergences from this plan arise during implementation (and they will), update this doc rather than diverging silently. The plan's value is being the single source of truth for "this is the iOS UX as of today" — let it drift from reality and it becomes worse than no plan.

When new Mac surfaces are added (between now and Phase 5 shipping), treat them as additions to §2 and decide their iOS treatment before shipping the Mac version. The Mac → iOS porting cost is much lower when both are designed together than when one is bolted on after the fact.
