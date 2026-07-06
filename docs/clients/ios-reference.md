# iOS reference client

The iOS app is the reference implementation of the [client spec](client-spec.md). It dogfoods the whole contract, so when the spec and the iOS code disagree, the iOS code is what actually ships and the spec is the thing to fix. This document maps the spec's concepts to concrete Swift types and explains the layering, so you can read the spec and then find the code that implements each part. The Mac app shares the same `PsmithKit` and `PsmithUI` packages but is knowingly behind on parity; treat iOS as the reference.

To build and run the app (prerequisites, the simulator loop, running on a device), see [building-ios.md](building-ios.md). This document is about how it works internally.

## Package layout

The Swift code is three targets:

- **PsmithKit** (`clients/PsmithSwift/Sources/PsmithKit/`) is the shared, non-UI layer: the generated RPC stubs, repositories, view models, streaming, accounts, offline, device-tool dispatch, and domain types. Almost everything load-bearing lives here so iOS and Mac share it. The project convention is that non-UI code belongs in PsmithKit, not in an app target.
- **PsmithUI** (`clients/PsmithSwift/Sources/PsmithUI/`) is shared SwiftUI atoms (for example `MarkdownText`).
- **psmithd-ios** (`clients/psmithd-ios/PsmithiOS/`) is the iOS app: the screens, and the iOS-specific device-tool implementations that touch EventKit, HealthKit, and the file system.

## Layering

The stack is four layers, top to bottom:

1. **SwiftUI views** (psmithd-ios) read `@Observable` view models from the environment.
2. **View models** (`PsmithKit/ViewModels/`), all `@Observable @MainActor`, own UI state and call repositories.
3. **Repositories** (`PsmithKit/Repository/`) wrap the generated RPC clients, integrate the cache, map errors, and own pagination and timeouts.
4. **Generated RPC clients** (`PsmithKit/Generated/`), the Connect-Swift `Psmith_V1_*ServiceClient` stubs.

Dependency injection is constructor-based and hangs off `PsmithClient` and `AppModel`. `PsmithClient` (`Repository/PsmithClient.swift`) is built per account from a host URL, a token store, an auth-state object, and an optional cache, and it holds every repository instance. `AppModel` is the per-account top-level state holder; it owns the `PsmithClient`, the shared view models (`ProvidersViewModel`, `ProfilesViewModel`), the `StreamHub`, the `OutboundQueue`, connectivity, and device-tool dispatch.

## Networking and auth

`PsmithClient` configures a Connect `ProtocolClient` with the proto codec and an `AuthInterceptor`, over a `URLSession` whose request timeout is deliberately long (about ten minutes) so the server's own idle timeout fires first and delivers a clean terminal event rather than the client tearing down a slow-thinking turn.

`AuthInterceptor` (`Auth/AuthInterceptor.swift`) reads the bearer token from a `TokenStore` and stamps `Authorization: Bearer <token>` on every unary call and stream start, and it flags the auth state for re-login on a 401. `TokenStore` is a protocol with a keychain-backed implementation for the app and an in-memory one for tests, namespaced per account.

## Streaming

Two types implement the spec's streaming and reconnection contract:

- **StreamSubscriber** (`StreamSubscriber/StreamSubscriber.swift`) wraps one `SubscribeStream` call as an `AsyncStream` of events. It implements the resume contract: on a transport drop it reconnects with exponential backoff and resubscribes from `lastSeenSequence + 1`, dedupes by tracking the next expected sequence, and surfaces a typed failure if retries are exhausted. It yields chunk events, then exactly one terminal event, then finishes. `PsmithChunk` is the Swift form of the chunk vocabulary, with cases for every chunk type.
- **StreamHub** (`StreamSubscriber/StreamHub.swift`) is the app-lifetime owner of active subscriptions, keyed by conversation id (one stream per conversation). Each active stream accumulates the live assistant text, the live thinking with start and finish timestamps, the in-flight tool calls, the last sequence (the resume cursor), and any pending elicitations. Because it is `@Observable` and view models read through it, streamed chunks drive SwiftUI updates automatically. The hub also tracks unseen conversations (persisted so "new message" markers survive a restart) and forwards `DEVICE_TOOL_USE` chunks to the device-tool dispatcher.

The key design point: the hub holds streaming state, not the view. A `ConversationViewModel` reads the live text through the hub, so the stream survives the view being torn down and rebuilt, and reattaching to a conversation is just reading the hub entry.

## Repositories

In `PsmithKit/Repository/`, one facade per service:

- **ConversationsRepository** — list (paginated, filterable), get, create, delete, and `sendMessage`, which initiates a streaming run.
- **ProfilesRepository** — profile CRUD with the resolve option and the sparse update / clear-fields pattern.
- **ModelProvidersRepository** — providers and models, templates for onboarding.
- **FilesRepository** — client-streaming upload, signed-URL fetch (grafting the host onto a path-only URL), list.
- **AuthRepository** — login, who-am-I, logout.
- **EmbedderRepository** and **LangfuseRepository** — settings panels.
- **DeviceToolsRepository** — `registerCapabilities` and the respond POST.
- **ElicitationsRepository** — the elicitation respond POST (plain HTTP, not Connect).
- **EventsSubscriber** — the account-events stream.

Repositories write successful list and get responses into the cache and fall back to it on network failure, so the relevant lists are available offline.

## View models

In `PsmithKit/ViewModels/`, all `@Observable @MainActor`:

- **AppModel** — per-account root; owns the client, shared view models, stream hub, outbound queue, connectivity monitor, and device-tool dispatcher. Lives longer than any view.
- **ConversationViewModel** — per-conversation: the conversation snapshot, active context, messages, draft, pending attachments, and the read-through to the hub for streaming state. Recreated per conversation-view appearance.
- **ConversationsModel** — the sidebar: conversations and profiles, list mode (all, by profile, search), order, and search query.
- **ProvidersViewModel** / **ProfilesViewModel** — the provider and profile lists, held on `AppModel` for the session.
- **EmbedderViewModel** / **LangfuseViewModel** — the settings panels.
- **ConnectivityMonitor** — polls health to track reachability and drives the offline affordances.

## Multi-account

Three types in `PsmithKit/Accounts/`: `Account` (a client-generated id, host, username, optional label, created-at), `AccountStore` (persists the account list and active id, thread-safe), and `AccountManager` (`@Observable @MainActor`, holds one `AppModel` per account and switches the active one instantly without re-login). The manager migrates a legacy single-account install into the first account on first run.

## Offline

- **OutboundQueue** (`OutboundQueue.swift`) persists queued `SendMessage` args and drains them in order when connectivity returns, stopping at the first failure to preserve ordering. `ConversationViewModel.send` routes to the queue when offline instead of firing the RPC.
- **PsmithCache** (`Cache/Cache.swift`) is a SwiftData actor, one store per account, with a size cap and oldest-first eviction. Repositories read through it. If SwiftData fails to initialize, the app runs cacheless rather than crashing.

## Device tools

`DeviceToolRegistry` and `DeviceToolDispatcher` (`PsmithKit/DeviceTools/`) implement the client side of the device-tool contract. The registry maps a tool name to a handler closure (`async throws (Data) -> Data`); the dispatcher registers the supported set with the server (`registerCapabilities` with device attributes), receives forwarded `DEVICE_TOOL_USE` chunks from the hub, runs the handler off the main actor, and posts the result back through `DeviceToolsRepository.respond`.

The iOS-specific handlers live in `psmithd-ios/PsmithiOS/DeviceTools/`: `CalendarTools` and `RemindersTools` over EventKit, `HealthTools` over HealthKit (a no-op on iPads without Health, permissions requested on first use), and `ObsidianTools` over a security-scoped vault bookmark (registered only when a vault is bookmarked). They register at app launch.

## Elicitation

`PsmithChunk` carries an elicit case (id, message, JSON schema). The hub queues it as a pending elicitation on the conversation's stream; the conversation view renders a sheet from the schema (a password-format field becomes a secure field); and `ElicitationsRepository.respond` posts the answer (accept / decline / cancel, with content on accept) to the elicitation respond endpoint. On success the hub clears the pending entry.

## File upload and images

`FilesRepository.upload` streams a header then chunked bytes and returns the file metadata. The conversation view model holds pending attachments and passes their ids to `sendMessage`. For display, a message carries attachment metadata only; the view fetches a signed URL and renders the image with a thumbnail and lightbox.

## Screens

The app is a two-tab shell behind an auth gate (`RootView`): a Chats tab and a Settings tab.

- **Chats** (`Chats/ChatsRoot.swift`): the conversation list with search, a mode picker, sort, an account menu, and a new-conversation affordance, pushing into **ConversationView** (`Chats/ConversationView.swift`), which renders the message list, the composer with attachment previews, the live stream, the elicit sheet, and pushes to compact, contexts, conversation settings, and the model picker.
- **Settings** (`Settings/SettingsRoot.swift`): a data section (providers, profiles, plugins) and a settings section (general, appearance, notifications, privacy, cost, Langfuse, embedder, Obsidian vault, device-tool activity).
- **Auth** (`LoginView.swift`): server-URL entry then credentials, deduplicating accounts by host and username.

`ConversationView` is also where the hard-won scroll behavior lives (content-width clamping, cold-entry tail, expand-on-settle, the scroll-to-bottom pill); that is iOS-specific layout tuning rather than protocol, and the project memory tracks the gotchas.

## Tests

Two layers, run by `make swift-test` ([building-and-codegen.md](../operations/building-and-codegen.md)). Layer 1 drives every public repository and view-model method against a freshly spawned local `psmithd` with its own database, a real client-to-server integration test. Layer 2 renders load-bearing SwiftUI views against committed PNG baselines. The project rule is that a Swift change ships with the matching L1 or L2 coverage; the full plan is in `testing-plan.md`.

## What is not built

Worth knowing if you read the code expecting it: there is no local draft persistence beyond the in-memory composer draft, push notifications are plumbed but not backed end to end, and deep call-settings tuning lives in the profile and conversation settings screens rather than on the composer. The Mac app trails iOS on parity generally.
