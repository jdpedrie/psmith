# Reeve — iOS app plan (preliminary)

A first pass at the technical architecture for an iOS Reeve client. Deliberately scoped to **how the code is organised** and **what changes the existing desktop client needs to absorb** to stay shareable — UX details (per-screen layout, navigation flows, gesture choices) come in a later, deeper plan that uses the desktop app as the reference design.

Reads as a sibling to `architecture.md`, `multimodal-plan.md`, `harness-plan.md`, `todo.md`.

---

## Goals

- Ship a native iOS (iPhone + iPad) Reeve client backed by the same `reeved` server every Mac client talks to.
- Maximise code share: the iOS app is a thin SwiftUI shell over the same `ReeveKit` + `ReeveUI` modules the Mac app uses today. Anything that ISN'T pure scene/window plumbing or platform-specific glue should live in a shared module.
- Preserve the design taste of the Mac client. The same Liquid Glass material vocabulary works on iOS 26+; what changes is chrome shape (sidebar split → tab bar / navigation stack) not the visual language.
- The desktop app stays first-class. Anything we extract during the iOS work should leave the Mac app's behaviour byte-identical.

## Non-goals (this plan)

- Per-screen iOS UX design. That's the next, deeper plan — once the architecture decisions land here.
- iPadOS-specific multi-pane UX beyond "iPad uses NavigationSplitView when it's a regular size class." We ship something that runs on both form factors before we polish either.
- Watch / Vision / CarPlay companions.
- Background sync / sync-without-server architecture (still a single-server-of-truth model — `reeved` is the source).
- Local LLM inference on-device.

---

## Existing package layout (reality check)

```
clients/
  ReeveSwift/                    Swift Package — shared
    Sources/
      ReeveKit/                  non-UI: domain, RPC, view models, auth, stream
        Auth/
        Domain/
        Generated/               (proto-generated)
        LocalCache/
        Plugins/
        Repository/
        StreamSubscriber/
        ViewModels/
        ServerURLStore.swift
      ReeveUI/                   shared SwiftUI views
        Atomic/                  MarkdownText, Placeholder
        Composite/               (currently empty — see §"Migration audit")
    Tests/                       (Layer 1 + harness + snapshot infra)

  reeved-mac/                    Xcode project — Mac app
    ReeveMac/                    SwiftUI views + Mac scene config
    Tests/                       (Layer 2 snapshot tests)
```

The split is right. `ReeveKit` already has zero AppKit imports (verified by a `grep -l "import AppKit"` — clean). `ReeveUI` exists but is barely populated — most shared-shaped views still live in `ReeveMac`. That's the main migration to do.

---

## Add a fourth target

```
clients/
  ReeveSwift/                    (unchanged)
  reeved-mac/                    (unchanged)
  reeved-ios/                    NEW Xcode project — iOS app
    ReeveiOS/
      ReeveiOSApp.swift
      RootView.swift
      iOS-specific scenes / nav containers / sheets
    Tests/
      ReeveiOSSnapshotTests/     UIKit/SwiftUI snapshot harness, iPhone + iPad sizes
```

ReeveiOS depends on `ReeveSwift` (`ReeveKit` + `ReeveUI`). Same Connect-Swift / SwiftProtobuf / MarkdownUI dependency tree.

---

## Migration audit — what should leave `ReeveMac` for `ReeveUI`

The "non-UI code lives in ReeveSwift" feedback rule is in force; the iOS effort is the forcing function to act on it for view code. The candidates fall into three buckets.

### Move outright (pure SwiftUI, no AppKit, useful on both platforms)

| Currently at | Why it's portable |
|---|---|
| `ReeveMac/ThinkingDisclosure.swift` | Pure SwiftUI; uses TimelineView, no platform APIs |
| `ReeveMac/ToolCallDisclosure.swift` | Same |
| `ReeveMac/PluginConfigForm.swift` | Pure SwiftUI form rendering |
| `ReeveMac/CallSettingsForm.swift` | Pure SwiftUI form rendering |
| `ReeveMac/ProfileCardPicker.swift` | Pure SwiftUI cards + pickers |
| `ReeveMac/ConversationModelPicker.swift` | Pure SwiftUI; expandable picker pattern |
| `ReeveMac/ProviderLogo.swift` | Asset bundle — needs platform-aware resource loading; see "Bundled assets" below |
| `ReeveMac/Theme.swift` | Pure colour / shape vocabulary; AppKit-clean despite living in ReeveMac |
| `ReeveMac/AppNavigation.swift` (the value types: `paneHeaderHeight`, `GlassCircleButton`, `EmptyStateView`, `WindowState`, `Navigator`, `SettingsCategory`, `PaneFooter`) | Mostly pure SwiftUI; `WindowState` is Mac-only and should stay |

After moving these, `ReeveUI/Composite/` actually has things in it.

### Wrap behind a protocol (uses AppKit; both platforms need an analogue)

| Concern | Mac (today) | iOS analogue | Protocol design |
|---|---|---|---|
| Clipboard write | `NSPasteboard.general.setString(...)` | `UIPasteboard.general.string = ...` | `Clipboard.write(_ text: String)` / `Clipboard.read() -> String?` in ReeveKit; per-platform impl in each app |
| Open external URL | `NSWorkspace.shared.open(url)` | `UIApplication.shared.open(url)` | `URLOpener.open(_ url: URL)` |
| Pick a directory | `NSOpenPanel(canChooseDirectories: true)` | `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` + scoped bookmark | `DirectoryPicker.pick() async -> URL?` |
| Pick a file | `NSOpenPanel` | `UIDocumentPickerViewController` | `FilePicker.pick(allowedTypes: [...])` |
| Speech recognition | `SFSpeechRecognizer` (or `SpeechAnalyzer` on macOS 26) | Same APIs on iOS | Mostly portable; permission-prompt UX differs |
| Speech synthesis | `AVSpeechSynthesizer` | Same on iOS | Portable as-is |
| Drag-drop receive | `NSItemProvider` via SwiftUI `.onDrop` | Same SwiftUI API works on iOS | Portable as-is |
| Show in Finder / Files | `NSWorkspace.activateFileViewerSelecting` | iOS has no analogue — typically just open URL | `RevealInFiles.reveal(_ url: URL?)` returns no-op on iOS |
| Save credentials | `Keychain` (existing path) | `Keychain` (same code, different access groups) | Already shared via `ReeveKit/Auth` |
| Notification scheduling | `NSUserNotificationCenter` (legacy) / `UNUserNotificationCenter` | `UNUserNotificationCenter` | Same on both; route through a thin shared wrapper for the "stream finished while app backgrounded" use case |

The protocols live in `ReeveKit` (or `ReeveUI` if SwiftUI-shaped); each app injects its platform-specific implementation at scene-construction time, the same way `ServerURLStore` is injected today.

### Stay platform-specific (no point sharing)

| File / pattern | Why it stays |
|---|---|
| `ReeveMacApp.swift` | NSApplicationDelegate, AppKit window config |
| `AppNavigation.swift::AppDelegate` (titlebar transparent, fullSizeContentView) | macOS-specific window chrome behaviour |
| `HSplitView`-based layouts (`HomeView`, `ProvidersView`, `SettingsView`) | iOS has no `HSplitView`; uses `NavigationSplitView` (works on iPad) or `TabView` + `NavigationStack` (iPhone). The iOS app builds its own scene hierarchy from the same building blocks. |
| `NSDraggingDestination`-shaped affordances | iOS uses `.dropDestination` on SwiftUI directly; the per-platform composer wraps the shared chip strip differently |
| `.onHover` patterns (hover-trash on rows, etc.) | iOS has no hover; the iOS row uses swipe actions. Per-platform `View.swipe(...)` modifier in the iOS shell instead |
| `Liquid Glass`'s glass-on-toolbar specifics | The materials API is the same on iOS 26+; what differs is which container the glass goes on (NavigationStack vs window toolbar). Use shared atomic chips; let the platform shell place them. |

---

## Refactors the desktop app needs (to make the share work)

None of these change Mac behaviour; they're "extract for share" rather than "rebuild." Best done incrementally as we touch each area, but documented here as a list so we don't lose track.

1. **Hoist atomic + composite views to `ReeveUI`.** Per the migration table above. ~15 files; each is a `git mv` plus an import update in `ReeveMac`. Bench each via Layer-2 snapshot tests so we know the move was a no-op visually.
2. **Extract platform-glue protocols into `ReeveKit`.** Define `Clipboard`, `URLOpener`, `DirectoryPicker`, `FilePicker`, `Notifier` interfaces. Move every direct `NSPasteboard.general` / `NSWorkspace.shared` / `NSOpenPanel()` call site in `ReeveMac` to dispatch through the shared protocol; provide the AppKit-backed implementations in `ReeveMac/Platform/`. The iOS app provides UIKit-backed implementations in `ReeveiOS/Platform/`. Inject via the existing `@Environment` pattern (or a Resolver type owned by the shell).
3. **Extract `ConversationViewModel`'s remaining Mac-coupled bits.** Today it's already in `ReeveKit/ViewModels` — verified clean. Keep it that way. Anything iOS-specific that VMs need (e.g., scene-phase observation for backgrounded streams) lands as protocol injection, not as a Mac-flavoured method.
4. **Settle on resource-loading for bundled assets.** `ProviderLogo` reads from a bundle. SwiftPM resource handling differs slightly between targets; the cleanest move is to declare logo assets on `ReeveUI` via `.process("Resources")` and ship them through the package. Pre-iOS work, this is just "make sure the same path works" — straight-line.
5. **`AppleFoundationTitler` lives in `ReeveMac`, but Apple Foundation Models is iOS 26+ too.** Move to `ReeveKit` (with a pure-Swift API, no AppKit), or to a new `ReeveAI` module if more on-device-AI features land later.
6. **Snapshot harness needs to grow per-platform sizes.** `ReeveMacSnapshotTests` records at Mac column widths. Add iPhone + iPad presets. The snapshot config (`SnapshotConfig.swift`) likely already has a `sizes:` parameter — extend it.

These are all additive-or-inert from the Mac side. We don't need to do them all up-front — but the iOS plan SHOULD start by doing #1 + #2, because everything else compounds on those.

---

## iOS-specific architecture decisions

### Scene + navigation shape

- **iPhone:** root `TabView` with three tabs (Conversations / Settings / Profile-or-Account). Inside each tab, `NavigationStack` with push-based navigation. New conversation is a sheet OR a full-screen cover from the conversations tab. Compose / message screen is the deepest push.
- **iPad regular:** `NavigationSplitView(sidebar: ConversationListView, detail: ConversationView)` — same shape as the Mac. The existing `HomeView::chatsShell` is mostly portable; the conversion is replacing `HSplitView` with `NavigationSplitView` and the sidebar tray with a row in the conversation list.
- **iPad compact:** falls back to the iPhone `TabView` layout via `horizontalSizeClass` switch.

### Server connection

iOS introduces something the Mac app didn't really need: **multi-server config**. Mac defaulted to localhost; iOS users will have a remote VPS, a homelab, maybe both. ServerURLStore already exists in ReeveKit; extend its shape from `ServerURL?` → `[ServerEntry]` with a `selected` field. Mac UI to manage the list lands as part of this — same surface both platforms will use.

Onboarding flow on iOS:
1. App launch → no server configured → "Add server" screen → enter URL + skip-cert-verify toggle (for self-signed cases) + label
2. Probe via `AuthService.Probe` to confirm the URL points at a reeved
3. Login screen with the existing flow
4. Conversations tab populated

### Backgrounding behaviour

iOS aggressively suspends backgrounded apps. Mid-stream backgrounding loses the `URLSession` mid-flight. Two paths:

1. **Server keeps streaming** (as designed) — when the app foregrounds, re-subscribe to the run via `streamRunID + fromSequence` and replay missed chunks from `stream_chunks`. The supervisor's "broker only ever sends what's already in DB" invariant makes this trivial; no new code on the server side. The iOS app needs a `ScenePhase` observer that drops the live subscription on background and re-establishes it on foreground.
2. **Background completion notification** — register `BGTaskScheduler` to wake on stream completion; deliver a `UNUserNotification` ("your reply is ready"). Optional polish; nice for long agentic-harness turns.

### Push notifications

Out of scope for this plan but worth noting the data model already supports it:
- `stream_runs.status` flips to terminal at materialization time
- A per-user push-token table + a server hook on terminal status fires the push
- iOS app handles APN delivery → routes to the conversation
- Defer until the app exists.

### Distribution

- **Apple Developer Program** ($99/year) required.
- **TestFlight** for personal use during development. Public App Store optional later — given Reeve's design ("self-hosted, single user") an unlisted distribution channel like a personal TestFlight or even an enterprise-style sideload is more in keeping with the vibe.
- Code signing + entitlements: pretty standard SwiftUI app entitlements. Network access (obvious), microphone (for STT), notification (for push). No iCloud, no HealthKit, etc.

---

## Bundled assets

`ProviderLogo` ships per-provider SVG/PNG assets. For SwiftPM-distributed across both apps:

- Move the assets to `Sources/ReeveUI/Resources/Logos/`
- Declare in `Package.swift`: `.target(name: "ReeveUI", resources: [.process("Resources")], ...)`
- `ProviderLogo` resolves via `Bundle.module` (the SwiftPM-magic bundle) — same code on both platforms.

Verify this works for the Mac app's existing rendering before moving on; resource bundles are the kind of thing that's silently fine until a test catches the missing file.

---

## Phasing

| Phase | Scope | Estimate | Independent? |
|---|---|---|---|
| **0 — Migration prep** | Move atomic SwiftUI views from ReeveMac → ReeveUI (per migration table). Verify visually via existing snapshot tests. Keep Mac behaviour unchanged. | ~3 days | Yes — no iOS code yet |
| **1 — Platform-glue protocols** | Define `Clipboard`, `URLOpener`, `DirectoryPicker`, `FilePicker`, `Notifier` in ReeveKit. Refactor every Mac call site to dispatch through them. AppKit-backed impls land in `ReeveMac/Platform/`. | ~3 days | Yes — Mac-only refactor; preps for iOS |
| **2 — Server config: multi-server** | Extend ServerURLStore from one URL to a list. Add Mac UI to manage entries. Foundation for iOS onboarding. | ~3 days | Yes |
| **3 — iOS scaffolding** | New Xcode project `clients/reeved-ios/`, depend on ReeveSwift, smoke "hello world" wired to AuthService. Establish the snapshot test harness for iPhone + iPad sizes. | ~3 days | Foundation for the rest |
| **4 — iOS onboarding + auth** | Add-server flow, Probe + Login, KeychainTokenStore (iOS access group). | ~3 days | Phase 3 |
| **5 — iOS conversations (phone)** | TabView root, NavigationStack-based conversation list + view + composer. Reuses every ReeveUI atomic / composite view from Phase 0. Per-platform glue from Phase 1. | ~1 week | Phase 0/1/3/4 |
| **6 — iOS conversations (iPad)** | NavigationSplitView wrapper that swaps in for regular size class. Same conversation views inside. | ~3 days | Phase 5 |
| **7 — iOS providers + profiles + plugins screens** | Same view trees as Mac for these surfaces, ported through ReeveUI extractions. | ~1 week | Phase 5 |
| **8 — Background + reconnect** | ScenePhase-driven re-subscribe; "your reply is ready" UNUserNotification when stream completes while backgrounded. | ~3 days | Phase 5 |
| **9 — Polish** | Snapshot test coverage, iOS-specific gestures (swipe-to-delete on conversations, etc), keyboard handling on the composer, accessibility audit. | ~1 week | Phase 5+ |

**0 + 1 ship before any iOS scaffolding** — they're pure refactors that pay back as the iOS work progresses. 2 is also a Mac-side win independently. 3 onward is the iOS path proper.

End-to-end "iOS app exists and chats work" lands roughly at Phase 5 (~3 weeks from starting Phase 0). Polish (6 onward) is incremental.

---

## What we'll learn that this plan can't predict

- **Snapshot test parity.** Layout regressions between platforms will surface real differences in shared views — `Spacer` and `frame(maxWidth: .infinity)` interact subtly with iOS dynamic type + accessibility scaling. Some "shared" views may need `.iosOnly { ... }` tweaks. We'll find out.
- **Liquid Glass on iOS chrome.** WWDC patterns work the same on iOS 26+, but the natural containers differ (no NSToolbar; UINavigationBar instead). Some glass usages may need a per-platform wrapper.
- **`ConversationViewModel` lifecycle.** Mac assumes the VM lives as long as the conversation pane. iOS may need to release or hibernate VMs more aggressively under memory pressure. Likely fine — `@Observable` retain semantics are sane — but monitor with Instruments early.
- **Stream subscription resumption** under flaky cellular. The supervisor's replay-from-DB is robust on paper; we'll see if the iOS app surfaces edge cases (cellular handoff mid-stream → SSE socket dies → re-subscribe gap larger than expected).

---

## Open threads (revisit when their phase lands)

- **Watch companion** — read-only conversation list + reply via dictation. Reeves naturally onto the iOS app's repository layer; doesn't change shared code. Defer until the iOS app is stable.
- **Share Extension** — "Send to Reeve" from Safari / Mail / Messages. Bundles a tiny extension app that uses the same ReeveKit Repository to create a conversation and inject the shared text. Designed-once-shared-everywhere works in our favour here.
- **Spotlight / SiriKit / Shortcuts** — surface conversations + send-message intents. All of this hangs off the same ReeveKit RPCs.
- **Push notifications.** Server-side (a `push_subscriptions` table + a stream-terminal hook + APN HTTP/2 client) plus iOS-side registration. Designed as a follow-on; data model survey lives in this plan, the actual delivery work is its own design.
- **Multi-tenant story.** Reeve is per-user-only today. Multi-server config on the iOS side is functionally adjacent — the app just talks to N reeveds, each of which is single-user. If Reeve grows real multi-tenant, the iOS app already has the server-list UI to surface that distinction.
- **iCloud sync of server-list config.** Convenient but not essential. NSUbiquitousKeyValueStore is the right primitive when we want it.
- **Backwards compat with the existing single-server Mac config.** ServerURLStore migration: detect the old single-URL key, write it as the first entry of the new list, mark it selected. One-shot. Done in Phase 2.

---

## How to use this doc

This is the architecture skeleton. The next plan (post-Phase-0/1) walks through every Mac screen with a side-by-side iOS treatment — what lives in shared `ReeveUI`, what's per-platform, what's a deliberate divergence. That doc will reference this one for the protocol shapes + module boundaries; this doc captures the durable architecture decisions that don't change per-screen.
