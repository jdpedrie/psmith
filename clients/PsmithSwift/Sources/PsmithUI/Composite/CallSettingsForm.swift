import SwiftUI
import PsmithKit

/// Shared editor for `PsmithCallSettings`. Reused by every entry point (provider
/// settings tab, model gear popover, profile form, new-conversation form,
/// in-conversation settings page) so the field set + validation lives once.
///
/// Layout:
///   - Universal "Common" section (always visible; includes Top K with a
///     note that only Anthropic/Google honour it).
///   - "Thinking" section (always visible; annotated when the selected
///     model doesn't support thinking).
///   - "Caching" section (always visible).
///   - Provider extras: by default ALL THREE provider sections are
///     reachable through a tab control (Anthropic | OpenAI | Google) with
///     the tab pre-selected from `driverType` — settings persist for every
///     provider regardless of what's currently selected, so hiding the
///     other providers' knobs just made them impossible to see or clear.
///     Provider-scoped entry points (a provider's own defaults page, a
///     model gear) pass `showAllProviderSections: false` to render only
///     their own section — the other providers' extras can never apply
///     at those layers.
///
/// Each field renders an "Inherit (X)" mute hint when unset and the resolved
/// snapshot has a value for that field. A small ↺ button next to set fields
/// resets the override back to the inherited value.
///
/// We deliberately avoid SwiftUI's `Menu` for selections — single-item Menus
/// render with zero-height rows on macOS (see
/// `feedback_swiftui_menu_macos_bug.md`). Segmented `Picker`s and inline
/// glass cards are used instead — except on iOS where iPhone widths
/// can't hold 3-4 option segmented controls; iOS swaps to `.menu`
/// which renders correctly there (the macOS Menu bug is single-item
/// only; 2+ item iPhone Pickers work fine).

private extension View {
    /// Compact-width-friendly picker style. iOS gets a popup menu so
    /// the form stays inside the narrow phone width; Mac keeps the
    /// segmented control.
    @ViewBuilder
    func adaptivePickerStyle() -> some View {
        #if os(iOS)
        self.pickerStyle(.menu)
        #else
        self.pickerStyle(.segmented)
        #endif
    }
}

public struct CallSettingsForm: View {
    @Binding var settings: PsmithCallSettings
    let inheritedSettings: PsmithCallSettings?
    let driverType: String
    let modelCapabilities: PsmithModelCapabilities?
    /// Server-supplied per-model constraints (clamped temperature
    /// ranges, locked-at values, hidden field paths). nil = no
    /// known constraints; the form falls back to driver-type
    /// heuristics. Source-of-truth lives in
    /// `internal/modelmeta/constraints.go`.
    let modelConstraints: PsmithModelConstraints?
    /// When true (default), every provider's extras section is reachable
    /// through the tab control below, pre-selected by `driverType`.
    /// Provider-scoped entry points pass false to show only their own.
    let showAllProviderSections: Bool

    /// Provider-extras tab. Stable identity across driverType changes —
    /// seeded once at init so a mid-edit model switch doesn't yank the
    /// user off the tab they're reading.
    @State private var extrasTab: ProviderExtrasTab

    enum ProviderExtrasTab: String, CaseIterable, Identifiable {
        case anthropic = "Anthropic"
        case openai    = "OpenAI"
        case google    = "Google"
        var id: String { rawValue }

        init(driverType: String) {
            switch driverType {
            case "openai-compatible": self = .openai
            case "google":            self = .google
            default:                  self = .anthropic
            }
        }
    }

    public init(
        settings: Binding<PsmithCallSettings>,
        inheritedSettings: PsmithCallSettings?,
        driverType: String,
        modelCapabilities: PsmithModelCapabilities?,
        modelConstraints: PsmithModelConstraints? = nil,
        showAllProviderSections: Bool = true
    ) {
        self._settings = settings
        self.inheritedSettings = inheritedSettings
        self.driverType = driverType
        self.modelCapabilities = modelCapabilities
        self.modelConstraints = modelConstraints
        self.showAllProviderSections = showAllProviderSections
        self._extrasTab = State(initialValue: ProviderExtrasTab(driverType: driverType))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            commonSection
            thinkingSection
            cachingSection
            if showAllProviderSections {
                tabbedProviderExtras
            } else {
                switch driverType {
                case "anthropic":         anthropicSection
                case "openai-compatible": openaiSection
                case "google":            googleSection
                default:                  EmptyView()
                }
            }
        }
    }

    // MARK: - Provider extras tabs

    @ViewBuilder
    private var tabbedProviderExtras: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PROVIDER EXTRAS")
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            Picker("Provider extras", selection: $extrasTab) {
                ForEach(ProviderExtrasTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(extrasTabCaption)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            switch extrasTab {
            case .anthropic: anthropicSectionBody
            case .openai:    openaiSectionBody
            case .google:    googleSectionBody
            }
        }
    }

    /// Whether the visible extras tab matches the provider the next
    /// send will actually use — drives the "these don't apply" hint.
    private var extrasTabIsActiveProvider: Bool {
        ProviderExtrasTab(driverType: driverType) == extrasTab
    }

    private var extrasTabCaption: String {
        if extrasTabIsActiveProvider {
            return "Applies to the currently selected model's provider."
        }
        return "Saved, but only used when running on \(extrasTab.rawValue)."
    }

    // MARK: - Caching (cross-cutting)

    /// Provider-agnostic caching toggles. Today only `explicit_cache`
    /// lives here. Whichever active driver implements
    /// providers.ExplicitCacheProvider on the server side picks it up
    /// (Google + Anthropic today). Drivers that don't implement the
    /// interface no-op silently.
    private var cachingSection: some View {
        formSection("Caching") {
            boolToggleRow(
                title: "Explicit caching",
                description: "Server-managed explicit cache. On Google: cachedContents auto-placement (per-hour storage cost). On Anthropic: bumps the cache_control TTL from 5 minutes to 1 hour for stable conversations. On providers without an explicit-cache implementation: no-op.",
                value: optBoolBinding(\.explicitCache),
                inherited: inheritedSettings?.explicitCache
            )
        }
    }

    // MARK: - Common

    private var commonSection: some View {
        formSection("Common") {
            // Temperature
            sliderRow(
                title: "Temperature",
                description: temperatureDescription,
                value: $settings.temperature,
                inherited: inheritedSettings?.temperature,
                range: temperatureRange,
                step: 0.05,
                format: { String(format: "%.2f", $0) },
                disabled: temperatureLocked
            )

            // Top P
            sliderRow(
                title: "Top P",
                description: "Nucleus sampling cutoff. Lower values keep generation focused on the most likely tokens.",
                value: $settings.topP,
                inherited: inheritedSettings?.topP,
                range: 0...1,
                step: 0.05,
                format: { String(format: "%.2f", $0) }
            )

            // Max output tokens
            int32StepperRow(
                title: "Max output tokens",
                description: "Hard cap on tokens the model can generate in one turn.",
                value: $settings.maxOutputTokens,
                inherited: inheritedSettings?.maxOutputTokens,
                step: 256,
                lowerBound: 1,
                upperBound: 200_000
            )

            // Top K — always visible. Only Anthropic + Google honour
            // it, but the value persists across model switches, so
            // hiding it on OpenAI made an inherited/overridden value
            // invisible and impossible to clear.
            int32StepperRow(
                title: "Top K",
                description: "Limit sampling to the top K tokens. Honoured by Anthropic and Google; other providers ignore it.",
                value: $settings.topK,
                inherited: inheritedSettings?.topK,
                step: 1,
                lowerBound: 1,
                upperBound: 500
            )

            // Stop sequences
            stopSequencesRow
        }
    }

    private var temperatureDescription: String {
        // Constraint-aware first: if the server published a locked-at
        // value or a tighter range than the driver-type default, the
        // description should reflect that exact rule rather than the
        // generic guidance.
        if let r = modelConstraints?.temperature {
            if let l = r.lockedAt {
                return "This model locks temperature at \(String(format: "%.2f", l)). The slider is disabled."
            }
            if r.min != nil || r.max != nil {
                let lo = r.min.map { String(format: "%.2f", $0) } ?? "0"
                let hi = r.max.map { String(format: "%.2f", $0) } ?? "∞"
                return "Sampling temperature. This model accepts [\(lo), \(hi)]."
            }
        }
        switch driverType {
        case "anthropic":
            return "Sampling temperature. Anthropic clamps to [0, 1]."
        case "google", "openai-compatible":
            return "Sampling temperature. Range [0, 2]; higher = more creative."
        default:
            return "Sampling temperature."
        }
    }

    private var temperatureRange: ClosedRange<Double> {
        // If the server published a constraint, honour its tighter
        // bounds. lockedAt collapses the range to a single value so
        // the slider clamps; the row also disables interaction below.
        if let r = modelConstraints?.temperature {
            if let l = r.lockedAt {
                return l...l
            }
            let lo = r.min ?? 0
            let hi = r.max ?? (driverType == "anthropic" ? 1 : 2)
            if lo <= hi { return lo...hi }
        }
        return driverType == "anthropic" ? 0...1 : 0...2
    }

    /// True when the model's temperature is fixed at a single value
    /// — collapses the slider to a static read-out.
    private var temperatureLocked: Bool {
        modelConstraints?.temperature?.lockedAt != nil
    }

    @ViewBuilder
    private var stopSequencesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Stop sequences")
                Spacer()
                resetButton(
                    isOverridden: !settings.stopSequences.isEmpty,
                    inheritedSummary: inheritedListSummary(inheritedSettings?.stopSequences),
                    onReset: { settings.stopSequences = [] }
                )
            }
            Text("Strings that, when generated, end the response.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(settings.stopSequences.enumerated()), id: \.offset) { idx, _ in
                    HStack(spacing: 6) {
                        TextField(
                            "Stop sequence",
                            text: Binding(
                                get: { settings.stopSequences[idx] },
                                set: { settings.stopSequences[idx] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Button {
                            settings.stopSequences.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                }
                Button {
                    settings.stopSequences.append("")
                } label: {
                    Label("Add stop sequence", systemImage: "plus.circle")
                        .scaledFont(.caption)
                }
                .buttonStyle(.plain)
            }
            if settings.stopSequences.isEmpty,
               let inherited = inheritedSettings?.stopSequences,
               !inherited.isEmpty {
                Text("Inherits \(inheritedListSummary(inherited))")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Thinking

    @ViewBuilder
    private var thinkingSection: some View {
        formSection("Thinking") {
            // Always visible — the values persist across model
            // switches, so hiding the section on a non-thinking model
            // hid live settings. Annotate inapplicability instead.
            if modelCapabilities?.thinking == false {
                Label(
                    "The selected model doesn't support thinking — these are saved but ignored until you switch to one that does.",
                    systemImage: "info.circle"
                )
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
            }
            // Enabled toggle
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    fieldLabel("Enabled")
                    Spacer()
                    Picker("Enabled", selection: thinkingEnabledBinding) {
                        Text(inheritPickerLabel(inheritedSettings?.thinking?.enabled) { $0 ? "On" : "Off" })
                            .tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .adaptivePickerStyle()
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // Budget tokens
            int32StepperRow(
                title: "Budget tokens",
                description: "How many tokens the model may spend on hidden reasoning.",
                value: thinkingBudgetBinding,
                inherited: inheritedSettings?.thinking?.budgetTokens,
                step: 512,
                lowerBound: 0,
                upperBound: 64_000,
                disabled: settings.thinking?.enabled == false
            )
        }
    }

    private var thinkingEnabledBinding: Binding<Bool?> {
        Binding(
            get: { settings.thinking?.enabled },
            set: { newValue in
                var t = settings.thinking ?? PsmithThinkingSettings()
                t.enabled = newValue
                settings.thinking = t.isEmpty ? nil : t
            }
        )
    }

    private var thinkingBudgetBinding: Binding<Int32?> {
        Binding(
            get: { settings.thinking?.budgetTokens },
            set: { newValue in
                var t = settings.thinking ?? PsmithThinkingSettings()
                t.budgetTokens = newValue
                settings.thinking = t.isEmpty ? nil : t
            }
        )
    }

    // MARK: - Anthropic extras

    private var anthropicSection: some View {
        formSection("Anthropic extras") {
            anthropicSectionBody
        }
    }

    @ViewBuilder
    private var anthropicSectionBody: some View {
        cachingControls
    }

    /// Picks `Inherit / On / Off` for prompt caching, plus the TTL segmented
    /// picker (5 minutes / 1 hour). The TTL row is disabled when caching
    /// is explicitly off; inheriting still allows TTL editing because the
    /// caller may override the upstream "off" with their own TTL choice.
    @ViewBuilder
    private var cachingControls: some View {
        // Cache enabled
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel("Prompt caching")
                Spacer()
                Picker("Prompt caching", selection: cacheEnabledBinding) {
                    // Caching defaults to On when nothing is inherited.
                    Text("Inherit (\(inheritedSettings?.anthropic?.cacheEnabled.map { $0 ? "On" : "Off" } ?? "On, default"))")
                        .tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
                .adaptivePickerStyle()
                .labelsHidden()
                .fixedSize()
            }
            Text("When off, no cache_control marker is sent — useful for one-off conversations or privacy.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
        }

        // Cache TTL
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel("Cache TTL")
                Spacer()
                Picker("Cache TTL", selection: cacheTTLBinding) {
                    // TTL defaults to 5 min when nothing is inherited.
                    Text("Inherit (\(inheritedSettings?.anthropic?.cacheTTL.map(cacheTTLShort) ?? "5 min, default"))")
                        .tag(PsmithCacheTTL?.none)
                    Text("5 min").tag(PsmithCacheTTL?.some(.fiveMinutes))
                    Text("1 hour").tag(PsmithCacheTTL?.some(.oneHour))
                }
                .adaptivePickerStyle()
                .labelsHidden()
                .fixedSize()
            }
            Text("1 hour costs more to write but survives stop-and-resume workflows.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .opacity(cacheTTLDisabled ? 0.45 : 1.0)
        .allowsHitTesting(!cacheTTLDisabled)
    }

    /// Whether the TTL row should appear disabled. We disable it only when
    /// caching is explicitly off at this layer — when inheriting, the user
    /// could still override the parent's "off" by picking a TTL here, so we
    /// leave it interactive.
    private var cacheTTLDisabled: Bool {
        settings.anthropic?.cacheEnabled == false
    }

    private var cacheEnabledBinding: Binding<Bool?> {
        Binding(
            get: { settings.anthropic?.cacheEnabled },
            set: { newValue in
                var a = settings.anthropic ?? PsmithAnthropicExtras()
                a.cacheEnabled = newValue
                settings.anthropic = a.isEmpty ? nil : a
            }
        )
    }

    private var cacheTTLBinding: Binding<PsmithCacheTTL?> {
        Binding(
            get: { settings.anthropic?.cacheTTL },
            set: { newValue in
                var a = settings.anthropic ?? PsmithAnthropicExtras()
                a.cacheTTL = newValue
                settings.anthropic = a.isEmpty ? nil : a
            }
        )
    }

    private func cacheTTLShort(_ v: PsmithCacheTTL) -> String {
        switch v {
        case .fiveMinutes: return "5 min"
        case .oneHour:     return "1 hour"
        }
    }

    /// Label for a Picker's "Inherit" option that surfaces what
    /// inheriting currently resolves to — e.g. "Inherit (On)" — so the
    /// collapsed control shows the effective value instead of a bare
    /// "Inherit". A nil inherited value (nothing set below) → plain
    /// "Inherit", since there's nothing concrete to preview.
    private func inheritPickerLabel<T>(_ inherited: T?, _ format: (T) -> String) -> String {
        inherited.map { "Inherit (\(format($0)))" } ?? "Inherit"
    }

    // MARK: - OpenAI extras

    @ViewBuilder
    private var openaiSection: some View {
        formSection("OpenAI extras") {
            openaiSectionBody
        }
    }

    @ViewBuilder
    private var openaiSectionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            int32StepperRow(
                title: "Seed",
                description: "Reproducibility seed. Set to make outputs deterministic across calls.",
                value: openaiBinding(\.seed),
                inherited: inheritedSettings?.openai?.seed,
                step: 1,
                lowerBound: -1_000_000,
                upperBound: 1_000_000
            )

            sliderRow(
                title: "Frequency penalty",
                description: "Penalize tokens by how often they've already appeared. Range [-2, 2].",
                value: openaiBinding(\.frequencyPenalty),
                inherited: inheritedSettings?.openai?.frequencyPenalty,
                range: -2...2,
                step: 0.1,
                format: { String(format: "%.2f", $0) }
            )

            sliderRow(
                title: "Presence penalty",
                description: "Penalize tokens that appeared at all. Range [-2, 2].",
                value: openaiBinding(\.presencePenalty),
                inherited: inheritedSettings?.openai?.presencePenalty,
                range: -2...2,
                step: 0.1,
                format: { String(format: "%.2f", $0) }
            )

            int32StepperRow(
                title: "Top logprobs",
                description: "How many top alternatives to surface for each output token (also enables logprobs). Range [0, 5].",
                value: openaiBinding(\.topLogprobs),
                inherited: inheritedSettings?.openai?.topLogprobs,
                step: 1,
                lowerBound: 0,
                upperBound: 5
            )

            // Parallel tool calls toggle
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    fieldLabel("Parallel tool calls")
                    Spacer()
                    Picker("Parallel tool calls", selection: openaiBinding(\.parallelToolCalls)) {
                        Text(inheritPickerLabel(inheritedSettings?.openai?.parallelToolCalls) { $0 ? "On" : "Off" })
                            .tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .adaptivePickerStyle()
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // Service tier
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    fieldLabel("Service tier")
                    Spacer()
                    Picker("Service tier", selection: serviceTierBinding) {
                        Text(inheritPickerLabel(inheritedSettings?.openai?.serviceTier, serviceTierLabel))
                            .tag(PsmithServiceTier?.none)
                        Text("Auto").tag(PsmithServiceTier?.some(.auto))
                        Text("Standard").tag(PsmithServiceTier?.some(.standard))
                        Text("Priority").tag(PsmithServiceTier?.some(.priority))
                    }
                    .adaptivePickerStyle()
                    .labelsHidden()
                    .fixedSize()
                }
            }

            responseFormatRow
            logitBiasRow
        }
    }

    private func openaiBinding<T>(_ keyPath: WritableKeyPath<PsmithOpenAIExtras, T>) -> Binding<T> where T: Sendable {
        Binding(
            get: { (settings.openai ?? PsmithOpenAIExtras())[keyPath: keyPath] },
            set: { newValue in
                var o = settings.openai ?? PsmithOpenAIExtras()
                o[keyPath: keyPath] = newValue
                settings.openai = o.isEmpty ? nil : o
            }
        )
    }

    private var serviceTierBinding: Binding<PsmithServiceTier?> {
        Binding(
            get: { settings.openai?.serviceTier },
            set: { newValue in
                var o = settings.openai ?? PsmithOpenAIExtras()
                o.serviceTier = newValue
                settings.openai = o.isEmpty ? nil : o
            }
        )
    }

    private func serviceTierLabel(_ t: PsmithServiceTier) -> String {
        switch t {
        case .auto:     return "Auto"
        case .standard: return "Standard"
        case .priority: return "Priority"
        }
    }

    @ViewBuilder
    private var responseFormatRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel("Response format")
                Spacer()
                Picker("Response format", selection: responseFormatKindBinding) {
                    Text(inheritPickerLabel(inheritedSettings?.openai?.responseFormat, responseFormatLabel))
                        .tag(ResponseFormatKind.inherit)
                    Text("Text").tag(ResponseFormatKind.text)
                    Text("JSON object").tag(ResponseFormatKind.jsonObject)
                    Text("JSON schema").tag(ResponseFormatKind.jsonSchema)
                }
                .adaptivePickerStyle()
                .labelsHidden()
                .fixedSize()
            }
            if case .jsonSchema = settings.openai?.responseFormat {
                jsonSchemaEditor
            }
        }
    }

    private enum ResponseFormatKind: String, Hashable {
        case inherit, text, jsonObject, jsonSchema
    }

    private var responseFormatKindBinding: Binding<ResponseFormatKind> {
        Binding(
            get: {
                switch settings.openai?.responseFormat {
                case nil:                  return .inherit
                case .text:                return .text
                case .jsonObject:          return .jsonObject
                case .jsonSchema:          return .jsonSchema
                }
            },
            set: { newValue in
                var o = settings.openai ?? PsmithOpenAIExtras()
                switch newValue {
                case .inherit:    o.responseFormat = nil
                case .text:       o.responseFormat = .text
                case .jsonObject: o.responseFormat = .jsonObject
                case .jsonSchema:
                    // Preserve any existing schema fields if we're already in
                    // jsonSchema mode; otherwise seed with empty values.
                    if case .jsonSchema = o.responseFormat {
                        // keep existing
                    } else {
                        o.responseFormat = .jsonSchema(name: "", description: nil, schema: Data(), strict: nil)
                    }
                }
                settings.openai = o.isEmpty ? nil : o
            }
        )
    }

    private func responseFormatLabel(_ rf: PsmithResponseFormat) -> String {
        switch rf {
        case .text:        return "Text"
        case .jsonObject:  return "JSON object"
        case .jsonSchema:  return "JSON schema"
        }
    }

    @ViewBuilder
    private var jsonSchemaEditor: some View {
        if case .jsonSchema(let name, let description, let schema, let strict) = settings.openai?.responseFormat {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Schema name", text: Binding(
                    get: { name },
                    set: { newName in
                        if case .jsonSchema(_, let d, let s, let st) = settings.openai?.responseFormat {
                            updateOpenAIResponseFormat(.jsonSchema(name: newName, description: d, schema: s, strict: st))
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                TextField("Description (optional)", text: Binding(
                    get: { description ?? "" },
                    set: { newDesc in
                        if case .jsonSchema(let n, _, let s, let st) = settings.openai?.responseFormat {
                            let d = newDesc.isEmpty ? nil : newDesc
                            updateOpenAIResponseFormat(.jsonSchema(name: n, description: d, schema: s, strict: st))
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                Toggle("Strict", isOn: Binding(
                    get: { strict ?? false },
                    set: { newStrict in
                        if case .jsonSchema(let n, let d, let s, _) = settings.openai?.responseFormat {
                            updateOpenAIResponseFormat(.jsonSchema(name: n, description: d, schema: s, strict: newStrict))
                        }
                    }
                ))
                jsonEditor(
                    title: "Schema (JSON)",
                    data: schema,
                    onChange: { newSchema in
                        if case .jsonSchema(let n, let d, _, let st) = settings.openai?.responseFormat {
                            updateOpenAIResponseFormat(.jsonSchema(name: n, description: d, schema: newSchema, strict: st))
                        }
                    }
                )
            }
            .padding(.leading, 4)
        }
    }

    private func updateOpenAIResponseFormat(_ rf: PsmithResponseFormat) {
        var o = settings.openai ?? PsmithOpenAIExtras()
        o.responseFormat = rf
        settings.openai = o.isEmpty ? nil : o
    }

    @ViewBuilder
    private var logitBiasRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel("Logit bias")
                Spacer()
                resetButton(
                    isOverridden: !(settings.openai?.logitBias.isEmpty ?? true),
                    inheritedSummary: inheritedSettings?.openai?.logitBias.isEmpty == false
                        ? "(\(inheritedSettings?.openai?.logitBias.count ?? 0) entries)"
                        : nil,
                    onReset: {
                        var o = settings.openai ?? PsmithOpenAIExtras()
                        o.logitBias = [:]
                        settings.openai = o.isEmpty ? nil : o
                    }
                )
            }
            Text("JSON object mapping token IDs (integers) to bias values (doubles, [-100, 100]).")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
            jsonEditor(
                title: "Logit bias JSON",
                text: logitBiasJSONString,
                onChange: { newJSON in
                    let map = parseLogitBiasJSON(newJSON)
                    var o = settings.openai ?? PsmithOpenAIExtras()
                    o.logitBias = map
                    settings.openai = o.isEmpty ? nil : o
                }
            )
        }
    }

    private var logitBiasJSONString: String {
        guard let map = settings.openai?.logitBias, !map.isEmpty else { return "" }
        let stringKeyed: [String: Double] = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: stringKeyed, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    private func parseLogitBiasJSON(_ s: String) -> [Int32: Double] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [Int32: Double] = [:]
        for (k, v) in obj {
            guard let key = Int32(k) else { continue }
            if let d = v as? Double { out[key] = d }
            else if let i = v as? Int { out[key] = Double(i) }
        }
        return out
    }

    // MARK: - Google extras

    @ViewBuilder
    private var googleSection: some View {
        formSection("Google extras") {
            googleSectionBody
        }
    }

    @ViewBuilder
    private var googleSectionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            safetyThresholdRow(
                title: "Harassment",
                value: googleSafetyBinding(\.harassment),
                inherited: inheritedSettings?.google?.safetySettings?.harassment
            )
            safetyThresholdRow(
                title: "Hate speech",
                value: googleSafetyBinding(\.hateSpeech),
                inherited: inheritedSettings?.google?.safetySettings?.hateSpeech
            )
            safetyThresholdRow(
                title: "Sexually explicit",
                value: googleSafetyBinding(\.sexuallyExplicit),
                inherited: inheritedSettings?.google?.safetySettings?.sexuallyExplicit
            )
            safetyThresholdRow(
                title: "Dangerous content",
                value: googleSafetyBinding(\.dangerousContent),
                inherited: inheritedSettings?.google?.safetySettings?.dangerousContent
            )

            // Response MIME type
            stringRow(
                title: "Response MIME type",
                description: "e.g. \"application/json\".",
                value: googleStringBinding(\.responseMimeType),
                inherited: inheritedSettings?.google?.responseMimeType
            )

            // Response schema
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    fieldLabel("Response schema")
                    Spacer()
                    resetButton(
                        isOverridden: settings.google?.responseSchema != nil,
                        inheritedSummary: inheritedSettings?.google?.responseSchema != nil ? "(set)" : nil,
                        onReset: { updateGoogle(\.responseSchema, nil) }
                    )
                }
                Text("JSON schema bytes; constrains the response shape.")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                jsonEditor(
                    title: "Response schema (JSON)",
                    data: settings.google?.responseSchema ?? Data(),
                    onChange: { newData in
                        updateGoogle(\.responseSchema, newData.isEmpty ? nil : newData)
                    }
                )
            }

            int32StepperRow(
                title: "Candidate count",
                description: "How many candidate completions to request. Range [1, 8].",
                value: googleBinding(\.candidateCount),
                inherited: inheritedSettings?.google?.candidateCount,
                step: 1,
                lowerBound: 1,
                upperBound: 8
            )
        }
    }

    /// Toggle row variant for Bool? (tri-state: nil = inherit, true =
    /// override-on, false = override-off). Mirrors the existing
    /// stringRow / int32StepperRow patterns: shows an "Override"
    /// switch + actual toggle when overriding, otherwise displays the
    /// inherited value as a mute preview.
    @ViewBuilder
    private func boolToggleRow(
        title: String,
        description: String,
        value: Binding<Bool?>,
        inherited: Bool?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel(title)
                Spacer()
                resetButton(
                    isOverridden: value.wrappedValue != nil,
                    inheritedSummary: inherited.map { $0 ? "On" : "Off" },
                    onReset: { value.wrappedValue = nil }
                )
            }
            Text(description)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
            Toggle(isOn: Binding(
                get: { value.wrappedValue ?? inherited ?? false },
                set: { value.wrappedValue = $0 }
            )) {
                Text(boolToggleLabel(value: value.wrappedValue, inherited: inherited))
                    .scaledFont(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    /// Switch label: an explicit override reads as its plain state; an
    /// inheriting field surfaces the resolved value with an "(Inherited)"
    /// marker ("Enabled (Inherited)") so the effective value is visible,
    /// not hidden behind a bare "Inherit".
    private func boolToggleLabel(value: Bool?, inherited: Bool?) -> String {
        if let v = value { return v ? "Enabled" : "Disabled" }
        if let i = inherited { return i ? "Enabled (Inherited)" : "Disabled (Inherited)" }
        return "Inherit"
    }

    /// Binding for a top-level Bool? setting — used by the
    /// cross-cutting cachingSection (and any future similar surfaces).
    private func optBoolBinding(_ keyPath: WritableKeyPath<PsmithCallSettings, Bool?>) -> Binding<Bool?> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }

    private func updateGoogle<T>(_ keyPath: WritableKeyPath<PsmithGoogleExtras, T>, _ value: T) {
        var g = settings.google ?? PsmithGoogleExtras()
        g[keyPath: keyPath] = value
        settings.google = g.isEmpty ? nil : g
    }

    private func googleBinding<T>(_ keyPath: WritableKeyPath<PsmithGoogleExtras, T>) -> Binding<T> where T: Sendable {
        Binding(
            get: { (settings.google ?? PsmithGoogleExtras())[keyPath: keyPath] },
            set: { updateGoogle(keyPath, $0) }
        )
    }

    private func googleStringBinding(_ keyPath: WritableKeyPath<PsmithGoogleExtras, String?>) -> Binding<String> {
        Binding(
            get: { settings.google?[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.isEmpty ? nil : newValue
                updateGoogle(keyPath, trimmed)
            }
        )
    }

    private func googleSafetyBinding(_ keyPath: WritableKeyPath<PsmithSafetySettings, PsmithHarmThreshold?>) -> Binding<PsmithHarmThreshold?> {
        Binding(
            get: { settings.google?.safetySettings?[keyPath: keyPath] },
            set: { newValue in
                var g = settings.google ?? PsmithGoogleExtras()
                var s = g.safetySettings ?? PsmithSafetySettings()
                s[keyPath: keyPath] = newValue
                g.safetySettings = s.isEmpty ? nil : s
                settings.google = g.isEmpty ? nil : g
            }
        )
    }

    private func safetyThresholdRow(
        title: String,
        value: Binding<PsmithHarmThreshold?>,
        inherited: PsmithHarmThreshold?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel(title)
                Spacer()
                Picker(title, selection: value) {
                    Text(inheritPickerLabel(inherited, harmLabel)).tag(PsmithHarmThreshold?.none)
                    Text("None").tag(PsmithHarmThreshold?.some(.blockNone))
                    Text("Low+").tag(PsmithHarmThreshold?.some(.blockLowAndAbove))
                    Text("Med+").tag(PsmithHarmThreshold?.some(.blockMediumAndAbove))
                    Text("High").tag(PsmithHarmThreshold?.some(.blockOnlyHigh))
                }
                .adaptivePickerStyle()
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func harmLabel(_ t: PsmithHarmThreshold) -> String {
        switch t {
        case .blockNone:           return "None"
        case .blockLowAndAbove:    return "Low+"
        case .blockMediumAndAbove: return "Med+"
        case .blockOnlyHigh:       return "High"
        }
    }

    // MARK: - Generic field helpers

    private func sliderRow(
        title: String,
        description: String,
        value: Binding<Double?>,
        inherited: Double?,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel(title)
                Spacer()
                if let v = value.wrappedValue {
                    Text(format(v))
                        .scaledFont(.callout, monospacedDigit: true)
                        .foregroundStyle(.primary)
                } else if let inherited {
                    Text("\(format(inherited)) (Inherited)")
                        .scaledFont(.callout, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .scaledFont(.callout, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
                resetButton(
                    isOverridden: value.wrappedValue != nil,
                    inheritedSummary: inherited.map { format($0) },
                    onReset: { value.wrappedValue = nil }
                )
            }
            Text(description)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
            // A SwiftUI Slider FATAL-ERRORS when its bounds aren't
            // strictly increasing (zero-width range). That happens for
            // a locked-at constraint (range collapses to value...value
            // — e.g. OpenAI reasoning models lock temperature at 1.0),
            // which crashed the conversation settings sheet whenever a
            // gpt-5 / o-series model was selected. Render the locked
            // value as a static read-out instead of a degenerate
            // slider; the value + description above already convey it.
            if range.upperBound > range.lowerBound {
                Slider(
                    value: Binding(
                        get: { value.wrappedValue ?? inherited ?? range.lowerBound },
                        set: { value.wrappedValue = $0 }
                    ),
                    in: range,
                    step: step
                )
                .disabled(disabled)
            } else {
                HStack {
                    Text(format(range.lowerBound))
                        .scaledFont(.callout, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                    Text("locked")
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    private func int32StepperRow(
        title: String,
        description: String,
        value: Binding<Int32?>,
        inherited: Int32?,
        step: Int,
        lowerBound: Int,
        upperBound: Int,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel(title)
                Spacer()
                if let v = value.wrappedValue {
                    Text(v.formatted())
                        .scaledFont(.callout, monospacedDigit: true)
                        .foregroundStyle(.primary)
                } else if let inherited {
                    Text("\(inherited.formatted()) (Inherited)")
                        .scaledFont(.callout, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .scaledFont(.callout, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
                Stepper(
                    "",
                    value: Binding(
                        get: { Int(value.wrappedValue ?? inherited ?? Int32(lowerBound)) },
                        set: { value.wrappedValue = Int32(clamping: $0) }
                    ),
                    in: lowerBound...upperBound,
                    step: step
                )
                .labelsHidden()
                .fixedSize()
                resetButton(
                    isOverridden: value.wrappedValue != nil,
                    inheritedSummary: inherited.map { $0.formatted() },
                    onReset: { value.wrappedValue = nil }
                )
            }
            Text(description)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .opacity(disabled ? 0.45 : 1.0)
        .allowsHitTesting(!disabled)
    }

    private func stringRow(
        title: String,
        description: String,
        value: Binding<String>,
        inherited: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel(title)
                Spacer()
                resetButton(
                    isOverridden: !value.wrappedValue.isEmpty,
                    inheritedSummary: inherited,
                    onReset: { value.wrappedValue = "" }
                )
            }
            Text(description)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
            TextField(inherited.map { "Inherits \($0)" } ?? "(unset)", text: value)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// JSON editor backed by raw `Data`. Used for response_format.json_schema
    /// + google.response_schema.
    private func jsonEditor(title: String, data: Data, onChange: @escaping (Data) -> Void) -> some View {
        let initial = String(data: data, encoding: .utf8) ?? ""
        return jsonEditor(title: title, text: initial, onChange: { str in
            onChange(str.data(using: .utf8) ?? Data())
        })
    }

    /// JSON editor backed by a String (for logit_bias). Validates that the
    /// pasted text parses; renders a small red hint when not.
    private func jsonEditor(title: String, text initial: String, onChange: @escaping (String) -> Void) -> some View {
        JSONTextEditor(title: title, initial: initial, onChange: onChange)
    }

    // MARK: - Reset / inheritance helpers

    private func resetButton(
        isOverridden: Bool,
        inheritedSummary: String?,
        onReset: @escaping () -> Void
    ) -> some View {
        Group {
            if isOverridden {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(inheritedSummary.map { "Reset to inherited (\($0))" } ?? "Reset to inherited")
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
        }
    }

    private func inheritedListSummary(_ list: [String]?) -> String {
        guard let list, !list.isEmpty else { return "(none)" }
        return "(\(list.count))"
    }

    // MARK: - Layout primitives

    private func formSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .scaledFont(.callout)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Internal text editor used for JSON blobs. Lives as a separate `@State`
/// container so typing doesn't fight the parent's binding round-trip; we
/// only push the text upward on every keystroke through `onChange`.
private struct JSONTextEditor: View {
    let title: String
    let initial: String
    let onChange: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .scaledFont(.callout, design: .monospaced)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 80, maxHeight: 240)
                .focused($focused)
                .onChange(of: text) { _, newValue in onChange(newValue) }
            if !text.isEmpty, !isValidJSON(text) {
                Label("Doesn't parse as JSON.", systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { text = initial }
        // External changes (e.g. the field's ↺ reset clearing the value)
        // must reflect in the editor — but only while it isn't focused,
        // so typing never fights the parent's re-serialized round-trip.
        .onChange(of: initial) { _, newValue in
            if !focused, text != newValue { text = newValue }
        }
    }

    private func isValidJSON(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
