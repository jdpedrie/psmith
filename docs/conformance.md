# Conformance & Test Coverage Audit

Snapshot taken 2026-05-17, after a stretch of iOS-focused feature work.
This is a triage list — not a plan. Pick from it.

Context: john dogfoods iOS daily; Mac has lagged in usability, layout,
and design conformance. Swift test coverage (both L1 integration and L2
snapshot) has also drifted as recent work prioritized iOS shipping
velocity. See `~/.claude/projects/-Users-jdp-dev-clark/memory/project_ios_primary_mac_behind.md`
for the standing context.

**Caveat**: parity findings come from a static-code pass — visual /
layout regressions that only show up by running the Mac app are likely
underrepresented. A real walk-through is recommended before committing
scope.

---

## Mac vs iOS — Parity Gaps

### P0 — broken / unusable
*None identified by static audit.*

### P1 — present but materially worse than iOS

- **Three Settings panes missing on Mac**: General, Cost, Privacy.
  iOS has them at `clients/reeved-ios/ReeveiOS/Settings/SettingsRoot.swift:35–65`;
  Mac `clients/reeved-mac/ReeveMac/AppNavigation.swift:45–86` doesn't.
  Users can't configure data retention, cost tracking, or privacy
  policies on Mac.

- **No refresh button on Discover Models (Mac)**. iOS shipped one at
  commit `f351dfe7`. Mac `DiscoverModelsInline.swift:1110–1162` loads
  once on entry; stale discovery requires leaving + re-entering.

- **Conversation row hover trash isn't red on Mac**. iOS got the
  `.red`/`.destructive` fix at commit `d7e5db48`. Verify Mac uses the
  same treatment across all delete affordances.

- **Account menu placement**. iOS keeps the account avatar in the
  chats toolbar (top-leading, very discoverable). Mac hides it in a
  sidebar chip popover at the bottom (`HomeView.swift:79–105`).
  First-use discoverability is worse on Mac.

### P2 — design taste / Liquid Glass conformance drift

(All flagged by static audit but **need visual verification** before
acting — agent couldn't see the actual rendering.)

- Title-bar inset (`.padding(.top, 28)`) — confirm applied
  consistently on all detail panes (`ProvidersView`, `PluginSettingsView`,
  `LangfuseSettingsView`, etc.) per `feedback_titlebar_overlay.md`.

- Secondary button style — audit all "Edit", "Delete", "Disable"
  buttons across Mac to ensure `.buttonStyle(.glass)` not `.bordered`,
  per `project_liquid_glass.md`.

- Footer band material — verify status strips on `LangfuseSettingsView`,
  `NotificationsSettingsView`, `AppearanceSettingsView` use
  `.thinMaterial` / `.regularMaterial`.

- Settings flow modality — Mac `HomeView.swift:106–126` opens
  LoginView + account-removal as sheets. iOS uses inline navigation.
  Per `feedback_no_popup_settings.md`, routine flows should be inline.

### P3 — smaller polish

- Search field on `ConversationListView` (Mac) hand-rolls a TextField;
  iOS uses `.searchable`. Less native feel on Mac.
- Empty-state verb standardization ("Tap +" vs "Add").
- Verify model-picker chip uses `.menuIndicator(.hidden)` + manual
  chevron to avoid double-chevron rendering.

---

## Swift Test Coverage — Gaps

Reference: `docs/testing-plan.md`, two-layer plan.
- **L1**: `clients/ReeveSwift/Tests/ReeveKitTests/` — integration
  against fresh local reeved.
- **L2**: `clients/reeved-mac/Tests/ReeveMacSnapshotTests/` — SwiftUI
  snapshot tests.

CLAUDE.md rule: every new public Repository/ViewModel method gets an
L1; every new load-bearing SwiftUI view gets an L2.

### L1 — public methods without integration tests (~40)

Heaviest clusters:

**`ConversationViewModel` (12 untested)**
- `sendForking` *(recent — fork-on-old-message)*
- `selectModel` + `loadAvailableModels`
- `regenerateAssistant`
- `compact` / `prepareCompactView` / `promoteCompaction`
- `loadContexts` / `activateContext` / `createContextManual`
- `saveCallSettings`
- `refreshTokenCount`
- `maybeGenerateLocalTitle` *(on-device title)*

**`AccountManager` (4 untested)**
- `addAccount` dedup *(recent — re-auth vs new-account routing)*
- `otherSignedInAccounts`
- `switchAccount`
- `removeAccount`

**`ProvidersViewModel` (9 untested)**
- `selectProvider` / `loadTemplates`
- `startAddingWithPreset` / `startAddingCustom`
- `testProvider` / `testModel`
- `discoverModels`
- `addManualModel`
- `hasLoadedOnce` *(recent — splash gate)*

**`AppModel`**
- `bootstrap` *(recent — once-only guard for account switching)*
- `adoptActiveRunsFromServer`

**`ProfilesViewModel`** — `create`, `update`, `toggleFavorite`,
`hasChildren`, `loadPluginTypes`, `upsertUserPluginSettings`

**`ConversationsRepository`** — `updateTitle`, `updateSettings`,
`promoteCompactionToNewContext`, `createContextManual`

### L2 — load-bearing views without snapshots (~16)

- `AppShell` — top-level auth gate
- `RootView.authed` — splash/onboarding gate
- `LoginView` (consolidated form) — recent (`b24bd7fc`)
- `ConversationModelPicker` — page-replaces-pane
- `ConversationSettingsView` — call-settings form
- `CompactView` — compression editor
- `ContextListView` — context switcher
- `WelcomeView` — first-login welcome
- `LangfuseSettingsView` / `NotificationsSettingsView` /
  `AppearanceSettingsView` / `PluginSettingsView` — settings subtabs
- `ConversationView` choice fragment rendering — `MessageRow.choice`
  with the confirm-+-fork interaction state (recent, `1fc0a610`)
- `ConversationListView` (current state — multi-account aware)

### Highest-risk recent ships with zero tests

These shipped this week and touch core state:

| Item | Commit | Risk |
|---|---|---|
| `AccountManager.addAccount` dedup | `b24bd7fc` | Three flows route through one path; silent failure of dedup duplicates accounts |
| `AppModel.bootstrap` once-only guard | `4bf1ab0c` | Double-firing would re-register the connectivity drain hook → duplicate outbound drains |
| `ProvidersViewModel.hasLoadedOnce` | `291783dd` | Wrong gate → onboarding screen flash returns |
| `ConversationViewModel.sendForking` | `1fc0a610` | Fork-on-old-message UX silently appends to wrong branch if parent override drops |
| Consolidated `LoginView` (iOS + Mac) | `b24bd7fc` | Auth routing across three contexts in one form |
| Choice tap → confirm → fork flow | `1fc0a610` | iOS MessageRow + Mac ConversationView; alert state + parent threading |

---

## Suggested attack order

Three reasonable cuts:

### A. Mac visual walk-through first (~30 min, no code)
Open the Mac app, navigate every surface, and produce a real-eyes
punchlist. The static parity audit is probably undercounting. Output:
revised P0–P3 with actual observations.

### B. Knock out obvious Mac parity items (~2–3 hrs)
Ship the three missing Settings panes (General / Cost / Privacy) +
refresh button on Discover Models + red trash audit. L2 snapshot for
each new pane.

### C. Test-debt sprint (~2 hrs)
Add L1 tests for the four highest-risk recent ViewModel methods
(`addAccount` dedup, `bootstrap` guard, `sendForking`, splash gate
behavior via `hasLoadedOnce`). Then L2 snapshots for `LoginView` +
`AppShell` + splash states.

**Recommendation**: A → B → C in order. Get a real list before
committing to scope, ship visible Mac improvements next, catch tests
up last.

---

## Update protocol

When picking items off this list:
1. Strike them through in this file (or remove and note in commit).
2. If new gaps surface during the walk-through, append under the
   appropriate section.
3. Re-snapshot the test-coverage section when L1/L2 counts shift
   meaningfully.
