# Conformance & Test Coverage Audit

Snapshot taken 2026-05-17, after a stretch of iOS-focused feature work.
This is a triage list — not a plan. Pick from it.

Context: john dogfoods iOS daily; Mac has lagged in usability, layout,
and design conformance. Swift test coverage (both L1 integration and L2
snapshot) has also drifted as recent work prioritized iOS shipping
velocity. See `~/.claude/projects/-Users-jdp-dev-clark/memory/project_ios_primary_mac_behind.md`
for the standing context.

**Update 2026-05-17 (post walk-through)**: I built the Mac app from
current source and walked the major surfaces (Chats, Settings →
Providers / Profiles / Plugins / Appearance, in-conversation Settings,
account chip popover). Findings below replace the original static-only
audit. Net assessment: Mac is in better shape than "well out of
conformance" suggested — the architectural patterns hold up (3-column
NSplitView, page-replaces-pane settings, Liquid Glass buttons, theme
picker is genuinely polished). The real gaps are missing settings
panes, missing affordances iOS has shipped recently, and a couple of
visible drift items.

---

## Mac vs iOS — Parity Gaps (walk-through verified)

### P0 — broken / unusable
*None observed in the walk-through.* Every major surface renders,
the data layer round-trips, and the recent fixes (red trash, splash
gate, plugin-config decrypt) are live.

### P1 — real gaps the user will notice

1. **Three Settings panes missing on Mac**: General, Cost, Privacy.
   Settings sidebar currently has: Providers / Profiles / Plugins /
   --- / Appearance / Notifications / Langfuse. iOS surfaces General,
   Cost, Privacy under SETTINGS. Adding them requires new
   `*DetailView.swift` files mirroring the iOS shape.

2. **No refresh button on Discover Models (Mac)**. iOS shipped one
   at `f351dfe7`. On Mac the Discover Models tab loads once and has
   "+ Add custom model" but no way to re-probe — stale list requires
   tab-switching away and back. Walk-through confirmed.

3. **Model display names truncated in Provider detail header**
   ("Claude Haik...", "Claude Opu...", "Claude Sonn..."). The
   Enabled Models list right-column width is too tight for the full
   names; trailing ellipsis kicks in. Either widen the column, wrap
   to two lines, or use a tooltip-only truncation pattern.

4. **Legacy account label shows as "imported"** in the account chip
   popover (with host `reeve.secure.pedrie.com`). This is a one-time
   migration leftover — backfill the displayLabel from the live
   username on next auth restore, or surface the username instead of
   the displayLabel when the latter is the literal string "imported".

### P2 — design taste / conformance drift (visible in walk-through)

5. **Account chip popover doesn't show username + server URL header**.
   iOS shows username + URL at the top of the account menu; Mac
   account row only shows the displayLabel + host (and only for the
   active account — current host isn't restated separately). Less
   "you're signed in as X on Y" reinforcement.

6. **Settings flow modality**. Mac `HomeView.swift:106–126` opens
   LoginView + account-removal as sheets. iOS uses inline navigation.
   Per `feedback_no_popup_settings.md` routine flows should be inline.
   Lower priority on Mac because sheets are a stronger native idiom
   here than on iOS — but auditable.

### P3 — small polish

7. **Conversation header title duplicates as subtitle** — title bar
   shows "Optimizing Character Voice — $0.2069" with subtitle
   "Optimizing Character Voice". The subtitle should be something
   else (profile? context label?) or hidden when it matches the title.

8. **Settings → Providers sidebar shows providers in a flat list with
   a long Available section** (Mistral, Together AI, Ollama, ...
   continuing). The list grows long and the user has to scroll
   past Configured to reach Available. Section headers + collapse
   would help once the list crosses ~10 entries (currently ~12).

9. **Search field on `ConversationListView` (Mac) hand-rolls a
   TextField**; iOS uses `.searchable`. Less native feel on Mac.

10. **Liquid Glass conformance** (need targeted re-check, not blocking):
    title-bar inset on detail panes, secondary button styles, footer
    band materials. The walk-through didn't surface obvious offenders
    but a focused sweep with `project_liquid_glass.md` checklist would
    confirm.

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

### ✅ A. Mac visual walk-through — DONE 2026-05-17
Built Mac app from current source, walked every major surface,
replaced the static-audit P0–P3 with verified observations. Findings
above.

### B. Knock out the verified Mac parity items (~2–3 hrs)
In rough priority order:
- (P1) Three missing Settings panes: General, Cost, Privacy.
  Mirror iOS shape. L2 snapshot each.
- (P1) Refresh button on Discover Models (Mac).
- (P1) Model name truncation in provider detail header.
- (P1) Backfill / normalize the "imported" legacy account label.
- (P2/P3) Account popover header, title duplicate, search field native.

### C. Test-debt sprint (~2 hrs)
Add L1 tests for the highest-risk recent ViewModel methods. Then L2
snapshots for the load-bearing views without coverage.

Prerequisite for L2 work: **fix
`clients/reeved-mac/Tests/SnapshotHarness/Stubs.swift`** — it assigns
to ConversationViewModel properties that became hub-derived
(get-only), so the entire snapshot test target fails to compile.
That's why `make mac-app` failed until I changed `mac-build` to
target only the app (commit `969f4c6b`). Until the stubs are
updated, every L2 snapshot will block.

**Recommendation**: B → C now (A is done). The Phase B items are
visible improvements the user actually wants; the snapshot harness
fix in C should be the first task in C so subsequent L2 work isn't
blocked.

---

## Update protocol

When picking items off this list:
1. Strike them through in this file (or remove and note in commit).
2. If new gaps surface during the walk-through, append under the
   appropriate section.
3. Re-snapshot the test-coverage section when L1/L2 counts shift
   meaningfully.
