# Reeve client-side testing plan — Layer 1 + Layer 2

This plan brings the macOS client (and the shared ReeveKit Swift package) up
to the same coverage standard as the Go backend. It defines two test layers,
the harness for each, and the full enumeration of cases to write.

The backend already has the test contract covered (`make test`, pgtestdb
integration tests on every Postgres-touching path, unit tests on pure
functions). Today the Swift / SwiftUI side has zero automated coverage. Every
regression we've eaten in this codebase has been on the client side, so we're
investing here.

## Goals

1. **Behavior coverage** — every public ViewModel and Repository method gets
   an integration test that drives it against a live local reeved. Catches
   contract regressions, RPC plumbing breakage, ViewModel state-machine bugs,
   the "save doesn't actually save" class of failure that bit us this week.
2. **Layout coverage** — every view that has burned us (or could) gets a
   snapshot test exercising at least its empty / loading / loaded states.
   Catches "the sidebar tray vanished," "the form clipped at min width," and
   the rest of the SwiftUI-quirk failure mode.
3. **CI gate** — neither layer is meaningful unless it runs on every change.
   `make swift-test` invokes both; `make test` (the backend gate) gains it as
   a dependency for the all-in-one check.

Out of scope for this pass: full XCUITest end-to-end (requires a parallel
Xcode project; deferred until project stabilizes), iOS — ReeveSwift is
designed to be reusable but no iOS app exists yet.

## Layer 1: integration tests against a live reeved

### Harness

- New target `ReeveKitTests` in `clients/ReeveSwift/Package.swift`. Depends on
  `ReeveKit`. Uses Swift Testing (`@Test`) where possible, falls back to
  `XCTest` only where that's needed (e.g., async streaming).
- New helper module `clients/ReeveSwift/Tests/Harness/` with:
  - `TestReevedServer` — boots a local reeved against a fresh
    `pgtestdb`-style isolated Postgres database. Implementation:
    - On first call per test process, fork `go run ./cmd/reeved` with
      `REEVE_DSN` pointing at a fresh template-cloned database (mirror the
      Go side's `testutil` package's pgtestdb config).
    - Bind to an ephemeral port (`:0`), parse the actual port from the
      stdout startup log, expose as `baseURL`.
    - On test-process exit, send SIGTERM, wait, drop the test database.
  - `TestSession` — a per-test helper that:
    - Registers a fresh user with a UUID-suffix username, logs in, returns
      a fully-authenticated `ReeveClient`.
    - Optionally seeds common fixtures (a profile, a fake provider, an
      enabled model) via convenience helpers.
  - `FakeProvider` — a fake `openai-compatible` provider whose base_url
    points at a httptest-style mock embedded in the test process. Used for
    tests that need to exercise the message path without paying for real
    LLM calls. Returns canned chunk streams shaped like real provider
    responses. (For tests that legitimately need a live model, gate with
    `@available(skipUnlessLiveProviderEnv: true)`.)
- One `Tests/ReeveKitTests/` test file per ViewModel/Repository, mirroring
  the source layout:
  - `AuthRepositoryTests.swift`
  - `ConversationsRepositoryTests.swift`
  - `ProfilesRepositoryTests.swift`
  - `ModelProvidersRepositoryTests.swift`
  - `AppModelTests.swift`
  - `ConversationsModelTests.swift`
  - `ConversationViewModelTests.swift`
  - `ProfilesViewModelTests.swift`
  - `ProvidersViewModelTests.swift`
  - `IntegrationFlowTests.swift` (cross-ViewModel flows)

### Coverage matrix

For each method below: at minimum a happy-path test plus an error-path test
where the server can return a typed error (NotFound, InvalidArgument,
PermissionDenied, etc.). Where multiple optional parameters change behavior
materially, each variant gets its own test.

#### AuthRepository (`AuthRepositoryTests.swift`)

| # | Test |
|---|---|
| 1 | `login` — happy path, returns user, sets session cookie |
| 2 | `login` — bad password → InvalidArgument |
| 3 | `login` — unknown username → InvalidArgument |
| 4 | `login` — `clientLabel` is recorded on the session |
| 5 | `whoAmI` — after login, returns the same user |
| 6 | `whoAmI` — without session → Unauthenticated |
| 7 | `logout` — happy path, subsequent `whoAmI` is Unauthenticated |
| 8 | `restoreSession` — keychain-restored session returns user |
| 9 | `restoreSession` — no keychain entry → nil |
| 10 | `restoreSession` — expired/invalid cookie → nil, keychain cleared |

#### ConversationsRepository (`ConversationsRepositoryTests.swift`)

| # | Method | Test |
|---|---|---|
| 1 | `list` | empty for new user |
| 2 | `list` | returns ordered by `recentlyUsed` (default) |
| 3 | `list` | `order: .recentlyCreated` reverses correctly when activity ≠ creation |
| 4 | `list` | `titleQuery` ILIKE-matches partials |
| 5 | `list` | `titleQuery` excludes conversations with nil title |
| 6 | `list` | `profileID` filter narrows |
| 7 | `list` | `pageSize` clamps |
| 8 | `get` | happy path, returns conversation + active context |
| 9 | `get` | NotFound for unknown id |
| 10 | `get` | NotFound (don't leak existence) for another user's id |
| 11 | `create` | with title only |
| 12 | `create` | with settings (per-conversation overrides) |
| 13 | `create` | InvalidArgument when profile doesn't exist |
| 14 | `delete` | happy path, subsequent `get` → NotFound |
| 15 | `delete` | NotFound for another user's conversation |
| 16 | `updateTitle` | bumps title, returns updated row |
| 17 | `updateTitle` | empty string clears |
| 18 | `updateSettings` | replace semantics; previous settings overwritten |
| 19 | `sendMessage` | creates user message, returns stream run |
| 20 | `sendMessage` | with explicit `parentMessageID` (forking) |
| 21 | `sendMessage` | with `providerID/modelID` overrides |
| 22 | `sendMessage` | InvalidArgument when conversation NotFound |
| 23 | `listMessages` | returns ordered by depth+created_at |
| 24 | `listMessages` | with `leafMessageID` returns ancestor chain |
| 25 | `countContextTokens` | returns count + window |
| 26 | `countContextTokens` | Unimplemented for drivers without TokenCounter |
| 27 | `compact` | happy path, returns stream run |
| 28 | `compact` | `guide`/`providerID`/`modelID` overrides apply for the call only |
| 29 | `promoteCompactionToNewContext` | creates new context with compression message as seed |
| 30 | `editMessage` | content updates |
| 31 | `editMessage` | NotFound across users |
| 32 | `deleteMessage` | non-cascading: only the message |
| 33 | `deleteMessage` | cascading: descendants removed |
| 34 | `listContexts` | returns ordered, includes cumulative cost |
| 35 | `activateContext` | switches active_context_id |

#### ProfilesRepository (`ProfilesRepositoryTests.swift`)

| # | Method | Test |
|---|---|---|
| 1 | `list` | empty / single profile / multiple ordered |
| 2 | `get` | with `resolve: false` returns raw row |
| 3 | `get` | with `resolve: true` returns `(raw, resolved)` with parent fields applied |
| 4 | `get` | NotFound across users |
| 5 | `create` | minimum (just name) |
| 6 | `create` | with full ReeveProfilePatch (parent, system message, defaults, compression, title settings) |
| 7 | `create` | with `parentOnly: true` |
| 8 | `create` | with `favorite: true` |
| 9 | `create` | InvalidArgument when name empty |
| 10 | `update` | partial patch only updates provided fields |
| 11 | `update` | `clearFields` reverts to inherited |
| 12 | `update` | NotFound across users |
| 13 | `delete` | happy path |
| 14 | `delete` | NotFound across users |
| 15 | `delete` | refuses if profile has children (or cascades — confirm contract) |
| 16 | `listPluginTypes` | returns at least `lettered_choices` |
| 17 | `listPluginTypes` | `lettered_choices` has 4 ConfigFields with correct types |
| 18 | `getProfilePlugins` | empty for new profile |
| 19 | `getProfilePlugins` | returns ordered after a set |
| 20 | `setProfilePlugins` | replace semantics: previous list deleted |
| 21 | `setProfilePlugins` | InvalidArgument for unknown plugin name |
| 22 | `setProfilePlugins` | InvalidArgument for malformed config |

#### ModelProvidersRepository (`ModelProvidersRepositoryTests.swift`)

| # | Method | Test |
|---|---|---|
| 1 | `listProviderTypes` | returns built-in driver types (anthropic, openai-compatible, google) |
| 2 | `listTemplates` | catalog templates load |
| 3 | `list` | empty / multiple ordered |
| 4 | `get` | returns provider + enabled models |
| 5 | `get` | NotFound across users |
| 6 | `create` | openai-compatible with API key + base URL config |
| 7 | `create` | anthropic with just API key |
| 8 | `create` | InvalidArgument for unknown type |
| 9 | `update` | label only |
| 10 | `update` | config replaces |
| 11 | `delete` | cascades to enabled models |
| 12 | `discoverModels` | returns models from fake provider |
| 13 | `discoverModels` | network error surfaces |
| 14 | `enableModels` | adds rows |
| 15 | `enableModels` | deduplicates re-enables |
| 16 | `disableModels` | removes rows |
| 17 | `listModels` | enabled models for a provider |
| 18 | `toggleModelFavorite` | flips and persists |
| 19 | `updateProviderDefaultSettings` | replace semantics |
| 20 | `updateModel` | default_settings only path |
| 21 | `updateModelFull` | display_name change persists |
| 22 | `updateModelFull` | context_window change persists |
| 23 | `updateModelFull` | pricing change persists |
| 24 | `updateModelFull` | modalities replace via flag |
| 25 | `updateModelFull` | capabilities update |
| 26 | `updateModelFull` | knowledge_cutoff set / clear |
| 27 | `updateModelFull` | sparse merge — unset fields preserved |
| 28 | `updateModelFull` | empty display_name rejected |
| 29 | `addManualModel` | full metadata set persists |
| 30 | `addManualModel` | duplicate (provider_id, model_id) → AlreadyExists |
| 31 | `testProvider` | success result against fake provider |
| 32 | `testProvider` | failure result for bad credentials |
| 33 | `testModel` | success against fake provider |
| 34 | `testModel` | failure (model 404) |

#### AppModel (`AppModelTests.swift`)

| # | Test |
|---|---|
| 1 | `bootstrap` — loads providers + profiles in parallel |
| 2 | `bootstrap` — surfaces error from either |
| 3 | `bootstrap` — idempotent on repeat call |

#### ConversationsModel (`ConversationsModelTests.swift`)

| # | Test |
|---|---|
| 1 | `refresh` (default) — populates `conversations` |
| 2 | `refresh` (allChats + recentlyCreated) — different order |
| 3 | `refresh` (search mode + query) — server-filtered list |
| 4 | `refresh` (search mode + empty query) — does NOT filter (passes nil) |
| 5 | `refresh` (byProfile mode) — uses recentlyUsed order |
| 6 | `refresh` — clears `selectedID` if filtered out of result |
| 7 | `refresh` — preserves `selectedID` if still present |
| 8 | `refresh` — does NOT auto-select anything (Welcome page contract) |
| 9 | `newConversation` — appends to `conversations`, sets `selectedID` |
| 10 | `newConversation` — with settings round-trips |
| 11 | `newConversation` — error path leaves state unchanged |
| 12 | `delete` — removes from list, clears `selectedID` if matched |
| 13 | `delete` — error path doesn't mutate list |

#### ConversationViewModel (`ConversationViewModelTests.swift`)

The most complex VM. Pair with `FakeProvider` so streaming works without
real LLM cost.

| # | Test |
|---|---|
| 1 | `load` — populates context + messages on first call |
| 2 | `load` — idempotent across re-calls |
| 3 | `contextNumber(for:)` — first context = 1, subsequent contexts increment |
| 4 | `loadAvailableModels` — populates the model picker |
| 5 | `refreshTokenCount` — populates `tokenCount` from server |
| 6 | `refreshTokenCount` — `Unimplemented` driver leaves count nil |
| 7 | `send` — appends user message, starts stream, materializes assistant message |
| 8 | `send` — empty input is no-op |
| 9 | `send` — with provider/model override picks the override |
| 10 | `send` — with errored stream surfaces error message |
| 11 | `cancelStream` — terminates the in-flight subscription |
| 12 | `prepareCompactView` — populates compact-view state |
| 13 | `prepareSettingsView` — populates settings draft |
| 14 | `saveCallSettings` — persists conversation-level overrides |
| 15 | `compact` — replace mode produces new context with summary |
| 16 | `compact` — append mode preserves old context |
| 17 | `promoteCompaction` — promotes a compression-summary message |
| 18 | `loadContexts` — populates `contexts` list |
| 19 | `activateContext` — switches active_context_id |
| 20 | `editMessage` — content updates locally + server |
| 21 | `deleteMessage` — non-cascading removes one row |
| 22 | `deleteMessage` — cascading removes descendants |
| 23 | `maybeGenerateLocalTitle` — apple_foundation kind triggers local titler |
| 24 | `maybeGenerateLocalTitle` — non-apple kind is no-op |

#### ProfilesViewModel (`ProfilesViewModelTests.swift`)

| # | Test |
|---|---|
| 1 | `load` — populates profiles + providers + models |
| 2 | `select` / `selected` — round-trip |
| 3 | `loadAvailableModels` — populates the picker store |
| 4 | `toggleModelFavorite` — flips and persists |
| 5 | `create` — full patch round-trips |
| 6 | `create` — error path leaves list unchanged |
| 7 | `update` — partial patch + clearFields |
| 8 | `conciseName(for:)` — formatting |
| 9 | `parentChainName(for:)` — walks parent chain |
| 10 | `toggleFavorite` — flips and persists |
| 11 | `hasChildren` — false for leaf, true for parent-of |
| 12 | `loadPluginTypes` — populates list, sorted |
| 13 | `loadPlugins(forProfileID:)` — populates dict |
| 14 | `savePlugins` — persists, re-loads, dict reflects |
| 15 | `savePlugins` — invalid plugin name surfaces error |
| 16 | `deleteSelected` — happy path |

#### ProvidersViewModel (`ProvidersViewModelTests.swift`)

| # | Test |
|---|---|
| 1 | `load` — populates providers list |
| 2 | `selectProvider` — switches `selectedID`, fetches enabled models, resets detailMode |
| 3 | `deleteSelected` — removes provider, clears selection |
| 4 | `disableModel` — removes from `enabledModels` |
| 5 | `toggleModelFavorite` — flips and persists |
| 6 | `loadTemplates` — populates `templates`, sets `templatesLoaded` |
| 7 | `createProvider` — appends to list, becomes selected |
| 8 | `updateProvider` — label + config update |
| 9 | `updateProviderDefaultSettings` — replace semantics |
| 10 | `updateModelDefaultSettings` — round-trips |
| 11 | `updateModelFull` — full metadata persists |
| 12 | `discoverModels` — returns list against fake provider |
| 13 | `enableModels` — appends to enabledModels |
| 14 | `addManualModel` — appends to enabledModels with metadata_source=manual |
| 15 | `testProvider` — sets `providerTestStatus` to .testing then .success/.failure |
| 16 | `testModel` — same shape on `modelTestStatus` |

#### Cross-cutting integration flows (`IntegrationFlowTests.swift`)

These test that the ViewModel surface composes correctly across the app's
real user flows. Higher signal per test than per-method coverage.

| # | Flow |
|---|---|
| 1 | New user end-to-end: register → login → create provider → enable model → create profile → create conversation → send message → expect assistant turn |
| 2 | Edit a model fully: AddManualModel then UpdateModelFull on every metadata field, reload, assert all changes persist |
| 3 | Per-conversation override layers: provider default + profile default + conversation override → SendMessage uses the overridden temperature |
| 4 | Plugin pipeline: attach lettered_choices to profile, send a message expecting `<choices>` block, verify history rewrite on next send strips old block |
| 5 | Compact replace: send 5 messages, compact, verify new context exists with summary message |
| 6 | Compact append: same starting state, append-mode, verify both contexts coexist |
| 7 | Search → select conversation: list with title query → select returned id → loads correctly |
| 8 | By-profile grouping: 2 profiles × 2 conversations each, byProfile mode returns both groups with correct counts |
| 9 | Branch navigation: send msg, edit user msg → resends as fork → set leaf to original branch → send proceeds from original |
| 10 | Compaction promotion: compact replace → promote summary message to new context → assert new context root |

### Run mode

```sh
make swift-test                  # both layers
make swift-test-l1               # behavior only
make swift-test-l1 FILTER=Auth   # filter to a class
```

Test process responsibilities:
- Boots its own reeved subprocess on test start, tears down on exit.
- Each `@Test` runs against an isolated database (or at minimum an isolated
  user account; full DB isolation is preferred).
- No shared global state across tests.

## Layer 2: snapshot tests

### Harness

- Add `https://github.com/pointfreeco/swift-snapshot-testing` to
  `clients/reeved-mac/Package.swift` as a test-only dependency. (ReeveSwift
  package itself doesn't need it — snapshots cover ReeveMac SwiftUI views.)
- New target `ReeveMacSnapshotTests` in reeved-mac.
- New helper module `Tests/SnapshotHarness/`:
  - `Fixtures` — pre-built ReeveConversation, ReeveProfile, ReevePluginType,
    ReeveUserModelProvider, ReeveUserModel, etc. Hand-rolled, no server.
  - `Stubs` — minimal stub view models that satisfy the `@Environment` /
    `@Bindable` requirements without hitting reeved. ConversationsModel
    pre-loaded with fixtures, etc.
  - Helper for "render this view at column width X with WindowState=.normal"
    so we can also snapshot at the minimum supported column width and
    catch clipping bugs.
- Snapshots committed to `Tests/__Snapshots__/`. PRs that change UI re-baseline
  with `RECORD_SNAPSHOTS=1 swift test`.

### Coverage matrix

For each view: snapshot at `(column-min-width, default-width)`, in
`(empty, loaded)` states where applicable, and any error/loading state that
matters. The matrix is dimension × view count, shown collapsed below.

#### Login + Root

| View | States to snapshot |
|---|---|
| `LoginView` | empty / typing / submitting / error |
| `RootView` | logged-out → LoginView visible / logged-in → HomeView visible |

#### Conversation list sidebar (`ConversationListView`)

| State | Variants |
|---|---|
| `.allChats` | empty / 1 conversation / multiple / multiple with subtitles / loading / error |
| `.allChats` order | recentlyUsed / recentlyCreated (header label changes) |
| `.byProfile` | 1 profile with 0 chats / 1 profile with 3 chats / 2 profiles / profile with no chats inline |
| `.search` | empty query / typed query with matches / typed query no matches |
| Sort menu | popover open with checkmark on current selection |

#### Home shell (`HomeView`)

| Variant | Snapshot |
|---|---|
| chats mode, nothing selected | sidebar + WelcomeView |
| chats mode, conversation selected | sidebar + ConversationView |
| chats mode, composing new | sidebar + NewConversationView |
| settings mode | full SettingsView |
| sidebarVisibility = .doubleColumn vs .all | both |

#### Welcome (`WelcomeView`)

| State | Snapshot |
|---|---|
| can create (profile exists) | renders New Conversation button |
| cannot create (no profile) | button disabled, alt copy |

#### New conversation (`NewConversationView`)

| State | Snapshot |
|---|---|
| no profile selected | profile picker visible, send disabled |
| profile selected, default model | composer + model badge |
| profile selected, model overridden | composer + override chip |
| Chat Settings expanded | reveals CallSettingsForm inline |

#### Conversation view (`ConversationView`)

| State | Snapshot |
|---|---|
| empty (just system) | system row only |
| user + assistant pair | both rows + cost chip |
| with thinking enabled | thinking disclosure visible |
| with tool-use stub | tool-call message styling |
| streaming | "•••" indicator + cancel button |
| errored stream | inline error message |
| user message edit mode | textarea inline |
| compact mode page | CompactView replacement |
| settings mode page | ConversationSettingsView replacement |
| contexts mode page | ContextListView replacement |
| usage popover | open with cache-read split |

#### Compact (`CompactView`)

| State | Snapshot |
|---|---|
| default | replace + base model + default guide |
| append mode selected | mode toggle reflects |
| custom model picked | model badge updated |
| running | progress indicator |

#### Contexts (`ContextListView`)

| State | Snapshot |
|---|---|
| single context | one row |
| multiple contexts with parent chain | rows + parent links |
| with cumulative costs | cost chips |
| activated context highlighted | selection state |

#### Conversation settings (`ConversationSettingsView`)

| State | Snapshot |
|---|---|
| no overrides | inherit chips throughout |
| temp override | slider value, reset button |
| thinking override | toggle on |
| anthropic provider | AnthropicExtras section |
| openai provider | OpenAIExtras section |
| google provider | GoogleExtras section |

#### Settings shell (`SettingsView`)

| State | Snapshot |
|---|---|
| Providers category empty | center-pane "no providers" empty state |
| Providers category with providers | three-column layout |
| Profiles category | three-column layout |
| Window size at minimum (1080×520) | column rendering correct |

#### Providers (`ProvidersView` family)

| Sub-view | States |
|---|---|
| `ProvidersDetail` viewing | provider header + tabs |
| `AddProviderForm` | template list / template selected / custom |
| `EditProviderForm` | populated with existing |
| `ProviderDefaultSettingsTab` | empty / populated CallSettingsForm |
| `DiscoverModelsInline` | list / search / "Add custom model" popover |
| `ModelEditForm` adding | blank fields with placeholders |
| `ModelEditForm` editing | pre-populated, save dirty |
| Models list | enabled models with badges (context window, vision, etc.) |
| Min column width | form does not clip leading edge |

#### Profiles (`ProfilesView` family)

| Sub-view | States |
|---|---|
| `ProfileViewer` | full populated profile |
| `ProfileForm` adding | empty fields |
| `ProfileForm` editing | pre-populated |
| `ProfileForm` plugins section | empty inherits / one plugin attached / dirty Save |
| `ProfilePickerRow` | with parent chain text |
| `ProfileCardPicker` | horizontal scroll, multiple cards, selected highlight |
| Min column width | form does not clip leading edge |

#### CallSettingsForm

| Driver | Snapshot |
|---|---|
| anthropic | Anthropic-only fields shown, OpenAI/Google hidden |
| openai-compatible | OpenAI extras section |
| google | Google extras section |
| With inherited chips | unset fields show "Inherit" pill |
| Capability-gated | thinking-incapable model hides thinking section |

#### PluginConfigForm

| Field type | Snapshot |
|---|---|
| Number | TextField with default |
| Text | TextField with default |
| Textarea | bordered TextEditor |
| Boolean | Toggle |
| Select (≤4 opts) | popover-with-buttons |
| Select (>4 opts) | Picker(.menu) |

### Snapshot run mode

```sh
make swift-test-l2          # snapshot tests only
make swift-test-l2-record   # re-baseline on intentional UI changes
```

Reference images live in `clients/reeved-mac/Tests/__Snapshots__/`. PRs that
change UI must include a re-baseline commit; CI fails if a snapshot drifts
without one.

## CI integration

- `Makefile` adds:
  ```make
  swift-test:        swift-test-l1 swift-test-l2
  swift-test-l1:     ## Run ReeveKit integration tests against a local reeved
      cd clients/ReeveSwift && swift test --filter ReeveKitTests
  swift-test-l2:     ## Run ReeveMac snapshot tests
      cd clients/reeved-mac && swift test --filter ReeveMacSnapshotTests
  test:              swift-test
      go test ./...
  ```
- A test run boots a private reeved, owns it for the test process,
  tears down on exit. No shared dev reeved interference.
- Snapshot diffs render to PR artifacts on CI when run there.

## Estimated effort

- Layer 1 harness (server bootstrap, test session, fake provider): **~1 day**
- Layer 1 cases (~190 tests across 9 files): **~2-3 days** of focused work
- Layer 2 harness (snapshot package + fixtures + stubs): **~half day**
- Layer 2 cases (~100 snapshot variants across 12 view groups): **~1-2 days**

Total: **~5-7 working days** for full coverage. Implementation can ship
incrementally — Auth + Conversations repos first, then Profiles + Providers,
then ViewModels, then snapshots, gating each on green tests.

## Appendix: deferred to Layer 3 (XCUITest)

These cases need real AppKit rendering and aren't reachable from Layer 1 or
Layer 2. Capture them here so they're not lost when XCUITest finally lands.

- Two-item SwiftUI Menu rendering empty (the macOS 26 bug we hit)
- Sidebar tray actually clickable / sidebar list actually scrollable
- Window resize honoring contentMinSize at the AppKit level
- Title-bar overlay coverage when zoomed
- Glass effect rendering correctness
- Real keyboard shortcut routing
- Context-menu (right-click) behavior

When Layer 3 lands, the parallel Xcode project gets these as XCUITest cases
plus a happy-path "smoke" suite covering the 5 most common user flows.
