> Snapshot of the Mac Settings window as built on 2026-11-06, taken before the no-modal redesign. The redesign's boards are on the Settings page of the "Psmith Mac redesign concepts" canvas. The companion inventory is [inventory-app-panes.md](inventory-app-panes.md).

# Settings data surfaces: functional inventory (Mac)

Scope: Settings window panes **Models** (providers + models), **Profiles**, **Plugins**, **Servers** (MCP). Source of truth as of the current working tree. Everything below is what the UI does today, not what comments claim.

Sources read:
- `clients/psmithd-mac/PsmithMac/ProvidersView.swift`
- `clients/PsmithSwift/Sources/PsmithKit/ViewModels/ProvidersViewModel.swift`
- `clients/PsmithSwift/Sources/PsmithUI/Composite/CallSettingsForm.swift`
- `clients/PsmithSwift/Sources/PsmithUI/Composite/CapabilityProbeView.swift`, `ModelMetaStrip.swift`, `ModelPickerList.swift`, `ProfileCardPicker.swift`, `ProfileImportReview.swift`, `PluginConfigEditor.swift`, `PluginConfigForm.swift`, `ListFieldEditor.swift`
- `clients/psmithd-mac/PsmithMac/ProfilesView.swift`, `PluginSettingsView.swift`, `MCPServersView.swift`, `SettingsView.swift`
- `clients/PsmithSwift/Sources/PsmithKit/ViewModels/ProfilesViewModel.swift`, `MCPServersViewModel.swift`
- `clients/psmithd-mac/Tests/SnapshotHarness/Fixtures.swift`

---

## 0. Shell context

The Settings window is a `TabView` toolbar with panes: General, Appearance, **Models** (cpu icon), **Profiles** (person.crop.circle), **Plugins** (puzzlepiece.extension), **Servers** (server.rack), Usage, Integrations. Window min 900x560, ideal 1050x640, same size for every pane.

Each of the four record panes uses `SettingsSplit`: a fixed 240pt list column on the left (sidebar style, `SidebarWell` background), a divider, and a detail column on the right. No draggable divider.

Shared list affordance `SettingsAddRow`: last row of a list, dashed 16x16 rounded square + secondary text (e.g. "Add profile…"). Plain button.

Shared `EmptyStateView(title, systemImage, description)`: centered icon + title + caption.

Cross-pane deep link: a `ProfileCard`'s gear button (in the profile parent picker, and elsewhere in the app) calls `navigator.openProfileSettings(id:)`, which switches to the Profiles pane and selects that profile.

---

## 1. Models pane (providers and models)

### 1.1 Entities and fields

**Provider (`PsmithUserModelProvider`)**
| Field | Notes |
|---|---|
| `id` | uuid |
| `type` | driver: `anthropic`, `google`, `openai-compatible` (server also has `claudecode`, `codex` drivers; the Mac Add form can't create them) |
| `label` | display name |
| `presetID` | for openai-compatible presets (e.g. `groq`, `openrouter`); doubles as logo slug |
| `baseURL` | only for openai-compatible; read back for the edit form |
| `defaultSettings` | `PsmithCallSettings?`, bottom layer of the call-settings chain |
| `createdAt`, `updatedAt` | not displayed |
| api key | write-only; never returned to the client |

**Provider template (`PsmithProviderTemplate`)**, from `ListTemplates`: `catalogProviderID` (models.dev id, e.g. "groq"), `name`, `driverType`, `apiBase`, `envKey` (e.g. `GROQ_API_KEY`), `docURL` (unused in UI), `presetID`, `logoSlug`. Server presets for openai-compatible include OpenAI, xAI Grok, DeepSeek, Groq, OpenRouter, Mistral, Together AI, Cerebras, Qwen, Ollama (local), Perplexity; plus native Anthropic and Google.

**Enabled model (`PsmithUserModel`)**: `providerID`, `modelID` (wire id, the row key), `displayName`, `contextWindow` (Int32?), `maxOutputTokens` (Int32?), `pricing` (input/output/cacheRead/cacheWrite per million USD, plus `tiers` for context-size price breaks), `knowledgeCutoff` ("yyyy-MM-dd"), `modalities` ([text,image,audio,pdf,video]), `capabilities` (streaming, thinking, toolUse, vision, promptCaching, generatesImages), `favorite`, `defaultSettings` (CallSettings?), `constraints` (server-published: temperature range / lockedAt, `unsupported` field paths).

**Discovered model (`PsmithDiscoveredModel`)**: `modelID`, `displayName`, `contextWindow`, `pricing`, `capabilities`, `alreadyEnabled`.

Fixture examples: providers "Anthropic" (anthropic), "Groq" (openai-compatible), "Google AI" (google). Models: Claude Opus 4.7 `claude-opus-4-7` 200K ctx $15/$75 (cache $1.50/$18.75); Claude Haiku 4.7 $1/$5; Llama 3.3 70B Versatile `llama-3.3-70b-versatile` 128K $0.59; Gemini 2.5 Pro `gemini-2.5-pro` 2M $1.25; Gemini 2.5 Flash 1M $0.10. Templates: Anthropic `https://api.anthropic.com` `ANTHROPIC_API_KEY`; Groq `https://api.groq.com/openai/v1` `GROQ_API_KEY`; OpenRouter `https://openrouter.ai/api/v1`; OpenAI `https://api.openai.com/v1`; DeepSeek `https://api.deepseek.com`.

### 1.2 Detail modes (`ProvidersDetailMode`)

`viewing` | `adding` | `editing` | `discovering` | `settings` | `editingModel(modelID)` | `addingManualModel`.

What renders in the detail column:
- `adding` → AddProviderForm (full pane).
- `addingManualModel` → ModelEditForm in add mode (full pane).
- `editingModel(id)` → ModelEditForm in edit mode (full pane).
- `viewing` / `editing` / `discovering` / `settings` → ProviderDetailPanel, with `editing`, `discovering`, `settings` each presented as a **sheet** over it.
- No selection: loading spinner, or empty state "No providers configured / Add a provider from the sidebar to start enabling models." (server.rack), or "No provider selected / Pick one from the sidebar."

Selecting any provider resets `detailMode` to `viewing`. Switching provider clears `enabledModels` before fetch; re-selecting the same provider keeps the list while refreshing.

Load: on first `load()` providers are fetched (cache fallback on failure, error set), first provider auto-selected, templates fetched eagerly.

### 1.3 List column

Section header "Providers".
- One row per provider: provider logo 16pt (slug: `anthropic`/`google` by type, `presetID` for openai-compatible, generic globe for custom), label (1 line), right-aligned 7pt status dot: green "Configured", orange "The last test failed" (when the last in-memory test result failed). Status is per-session memory only.
- Spinner row while loading with no providers.
- **"Add provider…" row is a Menu** (dashed-square label): items = each *unconfigured* template by name, divider, "Custom OpenAI-compatible…". Disabled while `detailMode == .adding`.
  - Unconfigured rule: openai-compatible templates hidden once a provider with that `presetID` exists; native templates (anthropic, google) hidden once a provider of that driver type with no presetID exists.
- Selection: list highlights `selectedID`, but shows no selection while adding.
- **Row context menu**: "Edit Provider…" (select + editing sheet), "Discover Models…" (select + discovery sheet), divider, "Delete Provider…" (destructive; select + delete confirmation).

### 1.4 Provider detail panel (viewing)

Vertical stack, padding 24/18/20: header, models table, provider defaults summary.

**Header**
- Title: provider label (title3 bold, 1 line truncating).
- Subtitle: `"<type> · <n> model(s) enabled"` e.g. "anthropic · 2 models enabled".
- Right side, in order: **ProviderTestControl**, "Edit Provider…" button (→ editing sheet), "Discover Models…" button (→ discovery sheet), `…` menu containing "Delete Provider…" (destructive; disabled while deleting).

**ProviderTestControl** (one button, states):
| State | Label | Tint | Tooltip |
|---|---|---|---|
| idle | bolt icon "Test" | primary | "Verify provider auth + reachability" |
| testing | spinner "Testing…" (disabled) | accent | "Testing…" |
| success ok | check "`<n> models · <ms>ms`" e.g. "38 models · 212ms" | green | "Reachable · n models discovered in Xms. Click to re-test." |
| success not ok / failure | warning triangle + error text (or "Failed"), 1 line | orange | "Test failed: … Click to retry." |
Clicking in any non-testing state re-runs the test. Result is memory-only, per provider, and also drives the list dot.

**Models table** (`Table`, multi-select backing but actions use first selected)
- Loading (no models yet): spinner. Empty: "No models enabled / Use Discover Models… to find and enable some." (cpu).
- Height = rows x 56 + 32, capped at 420; rounded border.
- Columns:
  1. (22pt) favorite star button: filled yellow / outline secondary. Tooltip "Unfavorite" / "Mark as favorite". Optimistic toggle, rolls back on error.
  2. "Model": displayName (semibold) / modelID (caption secondary) / inline **ModelTestResultChip** (hidden idle/testing; green capsule "`<ms>ms · <n> tokens · <sample text>`"; orange capsule with error).
  3. "Context": compact `200K`, `2M`, or "—".
  4. "Price in / out": "`$15 / $75`" (whole numbers without decimals, else 2dp), plus orange "tiered" tag (tooltip "The price changes past a context size") when pricing tiers exist; "—" when no price.
  5. "Can": accent text joining `think · see · tools · draw` from capabilities.
  6. "On" (40pt): mini switch, always on; turning off asks to disable.
- Row context menu: "Edit Model…" (→ editingModel), "Test Model" (runs model test, updates chip), divider, "Disable…" (destructive → confirm).
- Double-click (primaryAction) a row → Edit Model.
- Sorted by displayName.

**Provider defaults summary** (card under the table)
- Caption header "Provider defaults".
- Rows: Temperature (`%.2g`), Max output tokens (formatted), Thinking (effort capitalized). Unset shows secondary "Model default".
- Footer: caption "Every model here starts from these; a model's own settings win." + button "Edit Defaults…" (→ settings sheet).

### 1.5 Edit provider (sheet, width 540)

Header "Edit provider", Cancel (glass, Esc) and Save (prominent, Return; spinner while saving).
Fields (90pt label column, hint below in tertiary):
| Label | Control | Prefill | Hint / rule |
|---|---|---|---|
| Label | text field, placeholder "Display name" | current label | required (Save disabled when blank) |
| New API key | secure field, "Paste to replace" | empty | "Leave blank to keep current key" |
| Base URL (openai-compatible only) | text field "https://..." | current baseURL | "Leave blank to keep current URL" |
| Catalog (openai-compatible only) | menu: "(unchanged)", "(no catalog)", divider, every openai-compatible template name | "(unchanged)" | "Used to enrich models with pricing & metadata from models.dev. Leave unchanged to preserve." |
Save sends only non-blank key/url and the catalog choice if changed (empty string clears). Error shown inline red. Success returns to viewing.

### 1.6 Discover models (sheet, 640x560)

- Title "Discover models".
- Row: search field "Search models…" (filters by id or display name, case-insensitive) + button "Add Custom Model…" (tooltip "Describe a model by hand, for private fine-tunes or models the provider doesn't list.") → closes sheet, opens ModelEditForm add mode.
- Body states: loading spinner; error: orange "Couldn't list this provider's models" + selectable error text; empty: "No models found"; no search match: "No results / Try a different search term."; list.
- List row (whole row is a toggle button): checkbox circle (accent when selected), displayName, green "enabled" capsule if already enabled, **ModelMetaStrip** below.
- Initial selection = all `alreadyEnabled` models.
- Footer: "`<selected> of <total> selected`", Cancel (Esc), "Enable Selected" (Return; disabled when nothing selected or while enabling; spinner).
- Commit calls EnableModels with the selected ids. Deselecting an already-enabled model here does **not** disable it (enable-only). Error lands inline.

**ModelMetaStrip** (shared): chips for context ("200K"), cost bucket by output price ($ <3, $$ 3–15, $$$ 15–50, $$$$ ≥50, orange), knowledge cutoff, then icons brain (thinking, purple), eye (vision, blue), wrench (tools, teal), tray (caching, green). Each chip has a tooltip. Clicking the strip opens a **popover** (`ModelDetailPopover`) with sections Model (Name, ID, Provider), Limits (context, max output), Pricing (USD per 1M: input/output/cache read/write), Capabilities, Modalities, Knowledge (cutoff).

### 1.7 Provider defaults (sheet, 600x620)

- Header "`<label> defaults`" + "Done" (Return) which returns to viewing.
- Body `ProviderDefaultSettingsTab`: headline "Provider defaults", caption "Bottom layer of the resolution chain — any field set here is used unless a per-model, profile, or conversation override is set. Changes auto-save when you leave this tab."
- Then **CallSettingsForm** with `inheritedSettings: nil`, `driverType: provider.type`, no model capabilities, `showAllProviderSections: false` (only that driver's extras section).
- Saves on disappear (closing the sheet by Done or Esc), only if the draft differs from what was seeded on open. Failure surfaces in the pane alert as "Provider defaults weren't saved: …".

### 1.8 Model edit form (full pane; add and edit)

Header: "Add custom model" / "Edit model"; Cancel (Esc) and "Add model" / "Save" (Return; spinner). Save disabled when saving, when display name blank, or (add mode) when Model ID blank.

Intro caption:
- Edit: "Edit any field. The model ID is the wire identifier and is locked — change it by removing the row and adding a new one."
- Add: "Manually describe a model on "<provider>" — for private fine-tunes, renamed-but-real models, or anything the provider doesn't list via discovery."

Sections (uppercase caption headers):
1. **Identity**
   - Model ID: text field placeholder "gpt-mystery"; disabled in edit. Hint add: "Wire identifier sent to the provider — e.g. gpt-mystery"; edit: "Locked — wire identifier; …".
   - Display name: text field "GPT Mystery". Required.
2. **Limits** (side by side): Context window (placeholder 128000, hint "Tokens (optional)"), Max output (8192, "Tokens (optional)"). Free text parsed as Int32; non-numeric silently becomes unset. In edit, blank clears.
3. **Pricing — USD per million tokens (all optional)**: Input, Output, Cache read, Cache write, each text field "0.00", parsed as Double. All blank = no pricing. Pricing tiers are not editable; existing tiers are carried through on save.
4. **Modalities**: toggle chips Text (default on in add), Image, Audio, PDF, Video. Multi-select.
5. **Capabilities**: checkboxes Streaming (default on), Thinking, Tool use, Vision, Prompt caching. `generatesImages` has no control; carried through from the existing model.
   - Edit mode only: **CapabilityProbeView** under a divider.
     - Header "Capabilities" + borderless "Probe" button (disabled while probing). Probe = dry run.
     - idle caption: "Runs a handful of tiny requests to see what this model actually supports. Costs a few tokens."
     - probing: spinner "Probing…". failure: orange message.
     - done: one row per probed capability (icon by outcome: supported check in accent, unsupported slash, inconclusive question, skipped minus; name; detail caption; latency ms). Then either "Would enable: a, b" + "Apply" button (re-runs probe with apply, which turns those capabilities on server-side and refreshes the checkboxes) or "Nothing new to enable." Then, if any were contradicted: "This model refused: x. Left switched on — clear it yourself if that is wrong."
     - Footnote: "A probe can switch a capability on. It never switches one off."
6. **Knowledge cutoff**: checkbox "Set"; when on, a date picker (date only). Stored as UTC yyyy-MM-dd. Unchecked in edit clears.
7. **Default call settings**:
   - Edit caption: "Resolves above the provider defaults but below profile and conversation overrides. Leave fields unset to inherit." Then CallSettingsForm inline.
   - Add caption: "Optional — sets the per-model defaults layer of the call-settings chain. Leave collapsed to inherit normally." Then a DisclosureGroup "Configure defaults…" / "Hide defaults" containing CallSettingsForm. Settings only sent if the disclosure is expanded at save time.
   - CallSettingsForm params here: `inheritedSettings: nil` (so no inherited hints, even though the provider layer sits below), driverType = provider type, modelCapabilities = the current checkbox state, modelConstraints = existing model's constraints, `showAllProviderSections: false`.

Errors: inline red under the sections. Success → viewing (table re-sorted).

Unused VM capability (no Mac UI today): `refreshModelMetadata` (re-snapshot a model from the catalog), `updateModelDefaultSettings`, `updateProviderPartial`.

### 1.9 Add provider form (full pane)

Entry: Add provider menu. A preset item sets `pendingAddPreset`; "Custom OpenAI-compatible…" clears it. Switching preset while the form is open resets fields (including API key). Leaving the form clears the preset.

Header "Add provider", Cancel (Esc), "Create" (Return; spinner). Create disabled when label blank, API key empty, openai-compatible with blank base URL, or creating.

Body:
- Section "Provider" (or "Custom"): accent-tinted card with 28pt logo, name + driver type (e.g. "Groq / openai-compatible") or "Custom provider / Pick a driver type and configure manually". Not changeable in-form.
- Section "Credentials" (90pt labels):
  | Label | Control | Default | Hint |
  |---|---|---|---|
  | Driver type (custom only) | segmented: Anthropic, OpenAI-compatible | OpenAI-compatible | — |
  | Label | text "Display name" | template name, or "Custom provider" | required |
  | API key | secure "Paste key here" | empty | template: "env: GROQ_API_KEY" |
  | Base URL (when openai-compatible) | text "https://api.example.com/v1" | template apiBase | custom: "Required for OpenAI-compatible drivers (e.g. http://localhost:9999/v1)" |
- Inline red error.
- On create: config blob `{api_key, base_url?, catalog_provider_id? (templates), preset_id? (openai-compatible templates)}`. New provider appended and selected (→ viewing).

### 1.10 Modals and confirmations in the Models pane (all must go)

1. Sheet: Edit provider (540 wide).
2. Sheet: Discover models (640x560).
3. Sheet: Provider defaults (600x620).
4. Confirmation dialog: "Delete "<label>"?" message "All enabled models for this provider will also be removed. Historical messages are unaffected." button Delete (destructive).
5. Confirmation dialog: "Disable "<model>"?" message "You can enable it again from Discover Models." button Disable (destructive). Triggered by the On switch or context menu.
6. Alert "Provider error" with `model.error` text, OK. Fires for any VM error (load, select, delete FK failure, favorite rollback, templates, defaults save).
7. Popover: ModelDetailPopover from any ModelMetaStrip (discovery rows).
8. Menus (not modal, but transient): Add provider menu; header `…` menu; row and table context menus; Catalog menu in edit provider.

### 1.11 Keyboard

Esc = Cancel, Return = primary on Add/Edit provider, Discover (Enable Selected), Model form, Defaults sheet (Done). Double-click table row = edit model.

---

## 2. CallSettingsForm (shared; embedded at provider, model, profile, and conversation layers)

### 2.1 Resolution chain and semantics

Order, lowest to highest: **provider defaults → model defaults → profile defaults → conversation overrides**. Every field is optional; unset at a layer means "inherit from below". The form edits one sparse layer. It shows inherited values only when the host passes `inheritedSettings`:
- Provider defaults: nil (bottom).
- Model defaults: nil (the provider layer is *not* previewed today).
- Profile: the selected default model's `defaultSettings` only (not merged with provider defaults).
Display rules:
- Set value: primary text + ↺ reset button (tooltip "Reset to inherited (X)").
- Unset with inherited: "`X (Inherited)`" secondary.
- Unset, nothing inherited: "—" tertiary.
- Moving a slider/stepper while unset starts from the inherited value (or range minimum) and sets an override.
- Enum pickers have an "Inherit" option, labelled "Inherit (X)" when something is inherited.

Sections are always shown (even if they don't apply) so stored values stay visible and clearable.

`showAllProviderSections`:
- true (profile, conversation): "PROVIDER EXTRAS" header + segmented tabs Anthropic | OpenAI | Google, pre-selected from `driverType` (openai-compatible → OpenAI, google → Google, else Anthropic). Caption: "Applies to the currently selected model's provider." or "Saved, but only used when running on <tab>."
- false (provider defaults, model defaults): only the driver's own section titled "Anthropic extras" / "OpenAI extras" / "Google extras" (nothing for other drivers).

Pickers are segmented on Mac, menu on iOS.

### 2.2 Fields

**COMMON**
| Field | Control | Range / step | Description shown |
|---|---|---|---|
| Temperature | slider + value + reset | anthropic 0–1, google/openai 0–2, step 0.05; narrowed by model constraint min/max; if constraint `lockedAt`, slider replaced by static value + "locked" | "Sampling temperature. Anthropic clamps to [0, 1]." / "Range [0, 2]; higher = more creative." / constraint: "This model accepts [lo, hi]." / "This model locks temperature at 1.00. The slider is disabled." |
| Top P | slider | 0–1 step 0.05 | "Nucleus sampling cutoff. Lower values keep generation focused on the most likely tokens." |
| Max output tokens | stepper + value | 1–200,000 step 256 | "Hard cap on tokens the model can generate in one turn." |
| Top K | stepper | 1–500 step 1 | "Limit sampling to the top K tokens. Honoured by Anthropic and Google; other providers ignore it." |
| Stop sequences | list of text fields, each with minus to remove; "Add stop sequence" button; reset clears list | strings | "Strings that, when generated, end the response." Inherited: "Inherits (n)" |

**THINKING**
- Info label when the model lacks thinking: "The selected model doesn't support thinking — these are saved but ignored until you switch to one that does."
- Effort: picker Inherit / Off / Low / Medium / High / Extra high. Caption "How hard the model reasons before answering. Off is honoured where the model can stop; elsewhere it means the lowest level."

**CACHING**
- Explicit caching: tri-state (switch + reset). Label reads "Enabled"/"Disabled" when set, "Enabled (Inherited)"/"Disabled (Inherited)" or "Inherit" when unset. Description: Google cachedContents auto-placement (per-hour storage cost); Anthropic bumps cache_control TTL from 5 min to 1 hour; elsewhere no-op.

**Anthropic extras**
- Prompt caching: Inherit (On, default) / On / Off. "When off, no cache_control marker is sent — useful for one-off conversations or privacy."
- Cache TTL: Inherit (5 min, default) / 5 min / 1 hour. "1 hour costs more to write but survives stop-and-resume workflows." Dimmed and non-interactive when Prompt caching is explicitly Off at this layer.

**OpenAI extras**
| Field | Control | Range |
|---|---|---|
| Seed | stepper | −1,000,000 to 1,000,000 |
| Frequency penalty | slider | −2 to 2 step 0.1 |
| Presence penalty | slider | −2 to 2 step 0.1 |
| Top logprobs | stepper | 0–5 |
| Parallel tool calls | Inherit / On / Off | — |
| Service tier | Inherit / Auto / Standard / Priority | — |
| Response format | Inherit / Text / JSON object / JSON schema | JSON schema reveals: Schema name (text), Description (optional, text), Strict (toggle), Schema (JSON editor) |
| Logit bias | JSON editor + reset | object of token id (int) to bias (−100..100); "(n entries)" inherited summary |

**Google extras**
- Safety thresholds, each Inherit / None / Low+ / Med+ / High: Harassment, Hate speech, Sexually explicit, Dangerous content.
- Response MIME type: text field, placeholder "Inherits X" or "(unset)", e.g. "application/json".
- Response schema: JSON editor + reset ("(set)" when inherited).
- Candidate count: stepper 1–8.

JSON editor: monospaced TextEditor 80–240pt tall; red "Doesn't parse as JSON." when invalid (value still stored).

Not honoured by the form today: `modelConstraints.unsupported` field paths (declared, never read). `includeThinkingInHistory` (profile-level) is not editable on Mac; it's carried through on profile save.

---

## 3. Profiles pane

### 3.1 Entity (`PsmithProfile`)

`id`, `name`, `description`, `parentOnly` (template, hidden from new-conversation picker), `favorite`, `isDefault` (one per user), `parentProfileID`, `systemMessage`, `defaultUserMessage`, `welcomeMessage`, `defaultSettings` (`defaultProviderID`, `defaultModelID`, `includeThinkingInHistory`, `callSettings`), `compressionMode` (replace/append), `compressionProviderID/ModelID`, `compressionGuide`, `titleProviderID/ModelID`, `titleGuide`, `titleProviderKind` (`apple_foundation` sentinel), `requiredModelCapabilities` (derived from plugins), timestamps. Plugins are a separate list (`PsmithProfilePlugin`: `pluginName`, `ordinal`, `config` JSON) saved via SetProfilePlugins (atomic replace).

Inheritance: any unset field falls back to the parent chain, at send time on the server. Plugin config fields with merge `appendString` concatenate root-to-leaf instead of replacing.

Fixture examples: "Shared Defaults" (parent only, "Inheritable settings only."), "Coding" ("Concise, code-first answers."), "Coding · Rust" ("Rust-flavoured coding profile."); system message "You are a helpful assistant."

### 3.2 Detail modes

`viewing` | `adding` | `editing` | `importing`. The detail pane reloads profiles and available models every time it appears.

States: loading spinner; empty "No profiles configured / Add a profile from the sidebar." (person.crop.rectangle); none selected "No profile selected / Pick one from the sidebar."

### 3.3 List column

Section "Profiles".
- Row: name; under it, ancestor chain in caption joined with " ‹ " (nearest parent first, up to 8 levels, cycle-safe), e.g. "Coding ‹ Shared Defaults".
- Spinner while loading with no profiles.
- "Add profile…" (disabled while adding) → adding.
- "Import from a file…" (disabled while an export/import call is in flight) → system open panel.
- No context menu. No favorite/default indicators in this list.

### 3.4 Viewer

Header: name (title3 bold) + gray "PARENT ONLY" capsule when parentOnly; subtitle "Inherits from <parent>" or "Standalone profile". Buttons: "Export…" (disabled while sharing; tooltip "Export the profile to a file you can share"), "Edit Profile…" (→ editing), `…` menu with "Delete Profile…" (destructive; disabled while deleting or when the profile has children), and when it has children a disabled text item "Delete its N child profile(s) first".

Body (each section only when set), uppercase caption headers, values in light gray boxes:
- Description
- System message
- Default user message
- Default model: "<display name> · <provider label>" (or "(partial)" when only one half set)
- Compression: "Mode: Replace|Append", "Model: …", guide text
- Auto-titling: Apple Foundation Models with apple logo + "ON DEVICE" accent capsule, or "Model: …"; guide text
- If nothing overridden: "This profile inherits everything from <parent or "the default">."

Not shown in the viewer: welcome message, call settings overrides, attached plugins, favorite, default-profile status, required capabilities.

Footer: red error line when `model.error` is set.

### 3.5 Add/Edit form

Header "Add profile"/"Edit profile", Cancel (Esc) → viewing (discards), "Create"/"Save" (Return; spinner). Save disabled while saving, when name blank, or when any attached plugin has an unsatisfied required **profile-scoped** field.

Segmented tab bar (state survives the plugin drill-down): **General | Model | Plugins | Automation**. Labels in a 130pt left column, control + tertiary description on the right.

**General → Basic**
| Label | Control | Description |
|---|---|---|
| Name | text, "e.g. Default, Coding, Brainstorm" | "Short, memorable. Shown in the conversation list." Required. |
| Description | text, "e.g. "Concise, code-first answers"" | "Optional. A sentence about when to reach for this profile." |
| Inherits from | **ProfilePickerRow** (see 3.6) with "Standalone" option, parent-only profiles allowed, self excluded | "Any field left blank below falls back to this parent. Templates (parent-only profiles) are eligible." |
| Parent only | switch | "When on, this profile is hidden from the new-conversation picker — only usable as a parent for inheritance." |

Cycle prevention: only self is excluded; descendants can be picked (server presumably rejects).

**General → Prompt**
| Label | Control | Description |
|---|---|---|
| System message | multiline, min 80 | "Sent as the system prompt at the top of every request." |
| Default user message | multiline, min 60 | "Pre-filled into the composer when a new conversation is started." |
| Welcome message | multiline, min 60 | "Shown as the assistant's first message in every new conversation — a greeting, not a prompt; it isn't sent to the model as an instruction." |

**Model → Default model**
- Model: inline model picker chip (see 3.7). "Used for normal turns when the conversation doesn't override." Unset row: "Use parent profile's default model."

**Model → Default call settings**
- Caption "Per-profile generation knobs (temperature, max tokens, thinking, …). Any unset field inherits from the model and provider layers below at send time."
- CallSettingsForm: inherited = selected default model's defaults; driverType = selected default model's provider type (falls back to "anthropic" when no model chosen); capabilities from that model; all provider extras tabs shown.

**Plugins** (see 3.8)

**Automation → Compression**
| Label | Control | Values | Description |
|---|---|---|---|
| Mode | picker (menu, max 200 wide) | (inherit) / Replace / Append | "Replace replaces the context with a summary; Append keeps both." |
| Model | inline model picker | unset = "Use parent profile's compression model (or skip compression)." | "Model used to write the summary." |
| Guide | multiline min 60 | free text | "Optional extra instruction for the summariser." |

**Automation → Auto-titling**
- Generator: three selectable cards (radio behaviour, check on selected):
  1. "Apple Foundation Models" + "ON DEVICE" badge, subtitle "On-device · free · macOS 26+" or the unavailability reason; disabled (45% opacity, tooltip reason) when unavailable. Selecting clears the cloud model.
  2. "Cloud model" (cloud icon), subtitle = chosen model name or "Pick a model below." Selected when not Apple and both title provider+model set. Selecting it clears the Apple kind but keeps the model.
  3. "Inherit / disabled" (arrow.up.right), "Use parent profile's setting (or skip auto-titling)." Clears everything.
  Description: "Apple Foundation Models runs locally on macOS 26+ — free, fast, private. Pick a cloud model below to use a paid LLM instead."
- Cloud model (hidden when Apple selected): inline model picker; "Used when the local generator is unavailable or you want a specific model." Unset: "Use parent profile's setting (or skip auto-titling)."
- Guide: multiline min 50, "Optional extra instruction for the titler — e.g. "prefer technical phrasing"."

Save semantics:
- Text fields trimmed; blank = nil. On edit, every nil field is sent in `clearFields` so it reverts to inherit (system_message, default_user_message, welcome_message, default_settings, parent_profile_id, compression_*, title_*).
- defaultSettings blob is sent only if any of default provider/model, non-empty call settings, or existing includeThinkingInHistory is present (the server replaces the whole blob).
- Apple titler and cloud title model are mutually exclusive on save.
- Then, if plugins changed (by name order or config) and the load didn't fail, SetProfilePlugins with ordinals = list order.
- Create selects the new profile. Success → viewing. Errors inline red.
- Form is seeded once per profile; returning from the plugin drill-down keeps in-flight edits.

### 3.6 ProfilePickerRow (parent picker)

Horizontal scrolling row of cards. Filter field "Filter profiles…" (max 260 wide) appears when more than 4 pickable profiles; matches name or description. Order: favorites first, then alphabetical.
- "Standalone" card (200x116, dashed border when unselected): "No parent profile."
- Profile cards (260x116): name, "PARENT" capsule if parentOnly, star toggle (favorite, saves immediately to server), gear button (opens that profile in Settings, navigating away), parent chain "A / B" in caption, 2-line description. Selected = accent border 2pt + tinted fill.
- Empty filter result (no none option): "No profiles match."

### 3.7 Inline model picker (default, compression, title slots)

- Chip button: provider logo 14pt (or cpu glyph) + model display name (or raw id, or "(unset — inherit)") + chevron. Tooltip "Choose model". One slot open at a time.
- Expanded inline below the row, max 360 tall, scrolling: **ModelPickerList**
  - "Unset — inherit" row at top with slot-specific caption; check when nothing selected.
  - Grouped by provider (logo 18pt + label header, sorted by label), models sorted by name. Each row: name (semibold + accent check when selected), ModelMetaStrip (clickable to popover). Rows for models lacking `requiredCapabilities` render disabled with orange "Needs: tool_use, vision" (not wired by the profile form today; it passes no requirements).
  - No models: "No models available / Configure a provider in Settings to enable models."
  - Selecting sets provider+model and collapses.

### 3.8 Plugins tab

States: "Loading plugins…" spinner; load failed (edit): "Couldn't load this profile's plugins. Saving won't change them." + Retry; else list.
- Empty: edit "No plugins. Inherits from parent profile."; add "No plugins yet. Add one below."
- Plugin card (button, rounded, orange border when anything is missing):
  - Title = plugin display name (falls back to machine name).
  - Orange warning chips: "N required" (unsatisfied profile-scoped required fields); "global setup needed" (tooltip: "This plugin's global settings have unsatisfied required fields. Open Plugin Settings to configure.").
  - Description (2 lines).
  - Capability mini-chips: Tool, System, Outgoing, Assistant, History, Chunks, Display, Lifecycle.
  - Red minus circle button "Remove plugin" (immediate, no confirm).
  - Chevron when drillable (has profile-scoped fields); tapping opens the per-plugin sub-screen. Non-drillable known plugins are disabled buttons.
- "Add plugin" glass button (plus icon; becomes "Cancel" with chevron.up when open; disabled when no plugin types). Expands inline (max 240 tall) a list of unattached plugin types as cards (name, plus-circle, description, capability chips). Empty: "Every available plugin is already attached." Clicking attaches with each field's default value and, if it has profile-scoped fields, drills straight into its settings.
- Order of attached plugins = ordinal; there is no reorder control.
- MCP servers registered in the Servers pane appear here as plugin types (one per server).

**Per-plugin sub-screen** (replaces the whole form pane):
- Header: "‹ Back" (Esc) + plugin name + right caption "Edits flow into the parent profile draft. Save on the profile screen to persist."
- Plugin description.
- No fields: "This plugin has no settings." Only global fields: "All of this plugin's settings live at user scope." + "Open Plugin Settings (in the app's main settings) to configure them once across every profile that uses this plugin." (text only, no link).
- Otherwise PluginConfigEditor with profile-scoped fields (models and profiles lists passed for picker fields), then, if globals exist, a note that credentials etc. live in Plugin Settings.

### 3.9 Export / import

Export (viewer "Export…"):
1. Calls ExportProfile (preserveChain false; no UI to choose chain export).
2. **NSSavePanel** with suggested filename, message "Anyone with this file can recreate the profile." or the server's notices (what was withheld, e.g. secrets) joined by blank lines.
3. Writes the payload. Write error → `model.error` "Could not save the profile: …".
(`ProfileExportNotices` view exists in PsmithUI, "Not included" + lock icon, but the Mac shows notices only inside the save panel message.)

Import:
1. "Import from a file…" opens **NSOpenPanel** "Choose a .psmithprofile file" (no type filter set).
2. Dry-run ImportProfile; on success detail switches to `importing`. Read error → "Could not read that file: …".
3. **ProfileImportPane** (inline in detail): header "Import profile" / "Nothing is created until you confirm."; body ProfileImportReview: names of profiles (currently fed from the `renamed` list), then either "Everything resolved. Nothing else to configure." or warnings sorted by severity with icons: provider missing (cpu), MCP server missing (server.rack), plugin unknown (puzzlepiece), renamed (textformat, gray, informational), other (triangle). Non-rename warnings are orange.
4. Footer: Cancel (clears, back to viewing), Import (disabled while sharing) → real import, reload list, select first imported profile.
5. Post-import warnings are stored in `importWarnings` but no Mac UI displays them.

### 3.10 Delete rules

- Only from the viewer's `…` menu. Disabled when any profile lists this one as parent, with the inline reason "Delete its N child profile(s) first".
- Confirmation dialog: "Delete "<name>"?" message "Conversations using this profile will keep working but lose its inheritance source." Delete (destructive).
- After delete the first remaining profile is selected.

### 3.11 Modals in the Profiles pane

1. Confirmation dialog: delete profile.
2. NSSavePanel (export). 3. NSOpenPanel (import). These are system file panels.
4. Popover: ModelDetailPopover from meta strips inside the inline model picker.
5. Menu: viewer `…`. Compression mode picker (menu style).
6. Inside plugin config fields: model picker **sheet**, select-field **popover** (see 4.3).
Already inline (no modal): model pickers, parent picker, add-plugin picker, plugin drill-down, import review.

---

## 4. Plugins pane (global plugin settings)

### 4.1 Entity

`PsmithPluginType`: `name` (machine), `displayName`, `description`, `capabilities` (configurable, systemPrompter, outgoingUserTransformer, historyTransformer, chunkTransformer, displayTransformer, toolProvider, assistantContentTransformer, messageLifecycleHook, panelProvider, actionHandler), `configFields`. Fields split into `globalConfigFields` (`global == true`, per user, stored once) and `profileScopedConfigFields` (per attached profile).

`PsmithUserPluginSettings`: `pluginName`, `config` (JSON blob).

`PsmithConfigField`: `name`, `display`, `description`, `type` (number, text, textarea, boolean, select, modelPicker, list, autoID, profilePicker), `defaultJSON`, `options` (value/label), `required`, `global`, `modelPickerFilter` (requires streaming/thinking/toolUse/vision/promptCaching/generatesImages), `itemFields` (for list), `merge` (replace / appendString), `category` (grouping header).

Fixture example (lettered_choices): Keep last N (number, default 1), Open tag (text, `<choices>`), Close tag (text, `</choices>`), System instruction override (textarea). Select examples: Style preset Compact/Verbose/Academic; Reply tone Neutral/Playful/Formal/Academic/Concise/Elaborate.

### 4.2 Layout and states

List column "Plugins": spinner until loaded; "No plugins compiled in" when none. Rows: puzzle icon, display name, orange triangle when a required global is unset (tooltip "Required global settings missing."), row tooltip = description. Auto-selects the first plugin on load. Includes MCP pseudo-plugins.

Detail:
- No selection: "Select a plugin / Plugins listed here have settings that apply across every profile that uses them — credentials and other shared values."
- Header: display name (title3 bold), machine name (callout secondary), "Saving…" mini spinner while a write is in flight.
- Description.
- If globals exist but saved settings failed to load: "Couldn't load this plugin's saved settings." + error + Retry.
- No globals: "This plugin has no global settings."
- Else caption "Shared settings — apply to every profile that attaches <name>." + PluginConfigEditor bound to the draft (no model or profile lists are passed here, so model-picker fields show "No models configured" and profile pickers show the raw id).
- If profile-scoped fields exist: divider, "PER-PROFILE SETTINGS", "<name> also exposes N field(s) that live on each profile that attaches this plugin. Edit those from the profile editor."
- Save error in red.

Save: **auto-save**, debounced 400ms after the draft changes from its seeded baseline, writes serialized in order, skipped if equal to stored. No Save button, no undo. First-time drafts seed from field defaults.

### 4.3 PluginConfigForm (generic, used here and in profiles)

Fields grouped by `category`: uncategorized first, then each category (uppercase header, tinted rounded box) in first-appearance order.

Per field: label (display or name) + red/gray "*" for required + accent "Appends" tag when merge is appendString (tooltip: concatenates across the profile chain and conversation override); control; red "Required." when unsatisfied; tertiary description.

| Type | Control | Value semantics |
|---|---|---|
| number | text field max 200 wide | blank removes key (reverts to default); integers stored as Int, else Double, else raw string |
| text | text field | string |
| textarea | multiline min 80 | string |
| boolean | switch | default from defaultJSON, else false; required false counts as set |
| select | button showing current label + chevron → **popover** list of options with checkmark (max 320 tall) | default from defaultJSON or first option |
| modelPicker | button "(choose model)" / model name → **sheet** "Model" with "N models across M providers" + ModelPickerList filtered by the field's capability filter; Done button; stored as `{provider_id, model_id}`. Empty filter result: "No models configured. Add one under Providers." or the image-model hint. |
| profilePicker | menu picker "Choose a profile" + profiles; raw id text when no list | profile uuid |
| list | ListFieldEditor (below) | array of objects |
| autoID | hidden | machine-filled uuid per row |

Required check: text-like must be non-blank; number/boolean must be present; list needs ≥1 row; modelPicker needs both ids.

**ListFieldEditor**: "None yet." when empty. Each row is a collapsible card (one open at a time): chevron + summary (first non-empty text value) + trash button (immediate delete). Open row shows each item field (except autoID) with label, control (textarea, toggle, menu picker for select/profilePicker, text field for everything else), description. Footer buttons "Add" (plus) and "Paste JSON" (toggles an inline paste box: caption "Paste a JSON array of rows. Replaces everything above.", text editor, error text, Apply (disabled when blank) / Cancel). Paste accepts a bare array or `{"<field>": [...]}`, backfills auto ids, replaces all rows.

### 4.4 Modals in Plugins

1. Popover: select field options.
2. Sheet: model picker field.
3. Menu: profile picker field and list-item selects.

---

## 5. Servers pane (MCP servers)

### 5.1 Entity (`PsmithMCPServer`)

`id`, `name`, `transport` (`http` | `stdio` | `inproc`), `command`, `args` (newline separated), `url`, `toolPrefix`, `hasEnv`, `hasHeaders` (secrets are write-only; only presence is returned). Derived `summary`: "http · <url>", "stdio · <command>", "in-process". Test result: `ok`, `errorMessage`, `toolNames`.

Registered servers appear as plugin types in every plugin picker (profiles, conversations). This pane is registry CRUD only.

### 5.2 List column

Section "MCP servers": spinner while loading with none; rows (server.rack icon + name, tooltip = summary); "Add server…" (disabled while adding). Sorted by name. Loads on appear.

### 5.3 Detail

- Nothing selected: icon + "Select a server, or register a new one" + "Registered servers appear as plugins you can attach to any profile or conversation. Credentials stay here, encrypted."
- Form (same for add and edit, re-created per server; max width 720, scrolls):
  - Header: "Register MCP server" or server name (title2); "One entry per server. Attach it from any profile's or conversation's plugin picker; the credentials below never leave this page."
  - **SERVER** card:
    - Name: text "Server name". "Shown as the plugin's name in every picker." Required.
    - Transport: segmented "HTTP (remote URL)" / "Stdio (subprocess)" / "In-process". Default http. "How psmithd reaches the server."
  - Transport-specific card:
    - http → **ENDPOINT**: URL ("https://example.com/mcp", "JSON-RPC endpoint (Streamable HTTP transport)."); HTTP headers (monospaced multiline 48–90 tall, "KEY: VALUE per line — usually the auth header." + "A value is stored; leave blank to keep it." or "Stored encrypted.").
    - stdio → **SUBPROCESS**: Command ("npx", "Executable, resolved against PATH."); Arguments (multiline, "One CLI argument per line."); Environment variables (multiline, "KEY=VALUE per line; the subprocess inherits nothing else." + secret hint).
    - inproc → **IN-PROCESS**: "Dispatches to this Psmith instance's own MCP surface. No configuration needed."
    - Switching transport keeps the other transport's typed values in memory; all are sent on save.
  - **TOOLS** card: Tool name prefix ("Optional", "Optional. Prepended to every tool name so two servers with identical tools don't collide. Overridable per attachment.").
  - Error box (red tint) from `model.error`.
  - Action bar: test banner on the left (edit only), then "Test" (edit only; glass; spinner; disabled while saving or testing; tooltip "Dial the server, run the MCP handshake, and list its tools"), then "Register"/"Save" (prominent; disabled when name blank or saving). No keyboard shortcuts.
    - Banner: "Probing…"; ok "Connected — no tools advertised" or "Connected — N tools: a, b, c" (2 lines) with green check; failure red x + error.
  - Edit only, after a divider, danger zone: "Delete this server" / "Profiles referencing it keep their attachment but stop exposing its tools." + "Delete…" (destructive).
- Save: blank env/headers = keep stored secret (the VM supports empty string = clear, but the form can't express clearing). After save, secret fields reset to blank and the saved server is selected. Test status is per-session memory.

### 5.4 Modals in Servers

1. Confirmation dialog "Delete <name>?" with Delete (destructive). No message body. Success deselects.

---

## 6. Consolidated modal inventory (for the no-modal redesign)

| # | Surface | Kind | Trigger | Content |
|---|---|---|---|---|
| 1 | Models | Sheet | Edit Provider… (header, row menu) | Label, new key, base URL, catalog |
| 2 | Models | Sheet | Discover Models… | search, multi-select list, Add Custom Model…, Enable Selected |
| 3 | Models | Sheet | Edit Defaults… | Provider CallSettingsForm, Done, save on close |
| 4 | Models | Confirmation | Delete Provider… | removes enabled models too |
| 5 | Models | Confirmation | model On switch off / Disable… | re-enable from Discover |
| 6 | Models | Alert | any VM error | "Provider error" + OK |
| 7 | Models, Profiles | Popover | click ModelMetaStrip | full model metadata |
| 8 | Profiles | Confirmation | Delete Profile… | conversations lose inheritance source |
| 9 | Profiles | System save panel | Export… | notices in panel message |
| 10 | Profiles | System open panel | Import from a file… | choose .psmithprofile |
| 11 | Plugins, Profiles | Sheet | plugin modelPicker field | filtered ModelPickerList + Done |
| 12 | Plugins, Profiles | Popover | plugin select field | option list |
| 13 | Servers | Confirmation | Delete… | none |
| — | various | Menus | Add provider, `…` menus, context menus, catalog picker, compression mode, profile pickers | transient |

Destructive actions with no confirmation today: removing a plugin from a profile, deleting a list-field row, deselecting in Discover (no-op), toggling favorites.

## 7. Gaps and inconsistencies worth knowing before redrawing

- Inherited-value previews are partial: the model layer doesn't show provider defaults; the profile layer shows only the chosen model's defaults, not the merged provider+model result, and nothing from the parent profile's call settings.
- Profile viewer omits welcome message, call settings, plugins, favorite/default status. Mac has no UI to set the default profile (`setDefault` exists in the VM) except favorites via the parent picker cards.
- Profile plugin order can't be changed. Plugin removal has no confirm.
- Plugin Settings' editor gets no model or profile lists, so model/profile picker globals are effectively uneditable there.
- Discover can't disable; disabling is a separate per-row action.
- `refreshModelMetadata` (catalog re-snapshot) has no UI. Pricing tiers are display-only.
- Provider defaults and plugin globals auto-save; profiles, models, providers, MCP servers use explicit Save. Two save models coexist.
- MCP secrets can be replaced but not cleared from the form.
- Import post-result warnings (`importWarnings`) are never shown.
- `modelConstraints.unsupported` is ignored by CallSettingsForm.
- Custom provider driver choice offers only Anthropic and OpenAI-compatible (no Google, Claude Code, Codex).
