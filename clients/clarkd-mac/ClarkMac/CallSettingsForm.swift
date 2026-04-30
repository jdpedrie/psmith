import SwiftUI
import ClarkKit

/// Shared editor for `ClarkCallSettings`. Reused by every entry point (provider
/// settings tab, model gear popover, profile form, new-conversation form,
/// in-conversation settings page) so the field set + validation lives once.
///
/// Layout:
///   - Universal "Common" section (always visible).
///   - Top K row visible only for anthropic / google drivers.
///   - Thinking section visible only when `modelCapabilities?.thinking == true`.
///   - One driver-specific extras section based on `driverType`:
///       "anthropic" → empty placeholder (none in v1).
///       "openai-compatible" → seed / penalties / logprobs / response format /
///                              service tier / parallel tools / logit bias.
///       "google" → safety thresholds / response MIME / response schema /
///                  candidate count.
///
/// Each field renders an "Inherit (X)" mute hint when unset and the resolved
/// snapshot has a value for that field. A small ↺ button next to set fields
/// resets the override back to the inherited value.
///
/// We deliberately avoid SwiftUI's `Menu` for selections — single-item Menus
/// render with zero-height rows on macOS (see
/// `feedback_swiftui_menu_macos_bug.md`). Segmented `Picker`s and inline
/// glass cards are used instead.
struct CallSettingsForm: View {
    @Binding var settings: ClarkCallSettings
    let inheritedSettings: ClarkCallSettings?
    let driverType: String
    let modelCapabilities: ClarkModelCapabilities?

    private var showsTopK: Bool {
        driverType == "anthropic" || driverType == "google"
    }

    private var showsThinking: Bool {
        modelCapabilities?.thinking == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            commonSection
            if showsTopK { topKRow }
            if showsThinking { thinkingSection }
            switch driverType {
            case "anthropic":
                anthropicSection
            case "openai-compatible":
                openaiSection
            case "google":
                googleSection
            default:
                EmptyView()
            }
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
                format: { String(format: "%.2f", $0) }
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

            // Stop sequences
            stopSequencesRow
        }
    }

    private var temperatureDescription: String {
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
        driverType == "anthropic" ? 0...1 : 0...2
    }

    private var topKRow: some View {
        formSection("Top K") {
            int32StepperRow(
                title: "Top K",
                description: "Limit sampling to the top K tokens. Anthropic + Google only.",
                value: $settings.topK,
                inherited: inheritedSettings?.topK,
                step: 1,
                lowerBound: 1,
                upperBound: 500
            )
        }
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
                .font(.caption2)
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
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            if settings.stopSequences.isEmpty,
               let inherited = inheritedSettings?.stopSequences,
               !inherited.isEmpty {
                Text("Inherits \(inheritedListSummary(inherited))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Thinking

    @ViewBuilder
    private var thinkingSection: some View {
        formSection("Thinking") {
            // Enabled toggle
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    fieldLabel("Enabled")
                    Spacer()
                    Picker("Enabled", selection: thinkingEnabledBinding) {
                        Text("Inherit").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if (settings.thinking?.enabled ?? nil) == nil,
                   let inherited = inheritedSettings?.thinking?.enabled {
                    Text("Inherits \(inherited ? "On" : "Off")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                var t = settings.thinking ?? ClarkThinkingSettings()
                t.enabled = newValue
                settings.thinking = t.isEmpty ? nil : t
            }
        )
    }

    private var thinkingBudgetBinding: Binding<Int32?> {
        Binding(
            get: { settings.thinking?.budgetTokens },
            set: { newValue in
                var t = settings.thinking ?? ClarkThinkingSettings()
                t.budgetTokens = newValue
                settings.thinking = t.isEmpty ? nil : t
            }
        )
    }

    // MARK: - Anthropic extras

    private var anthropicSection: some View {
        formSection("Anthropic extras") {
            cachingControls
        }
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
                    Text("Inherit").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text("When off, no cache_control marker is sent — useful for one-off conversations or privacy.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if settings.anthropic?.cacheEnabled == nil {
                let inherited = inheritedSettings?.anthropic?.cacheEnabled
                Text(inheritedCacheEnabledLabel(inherited))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        // Cache TTL
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel("Cache TTL")
                Spacer()
                Picker("Cache TTL", selection: cacheTTLBinding) {
                    Text("Inherit").tag(ClarkCacheTTL?.none)
                    Text("5 min").tag(ClarkCacheTTL?.some(.fiveMinutes))
                    Text("1 hour").tag(ClarkCacheTTL?.some(.oneHour))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text("1 hour costs more to write but survives stop-and-resume workflows.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if settings.anthropic?.cacheTTL == nil {
                let inherited = inheritedSettings?.anthropic?.cacheTTL
                Text(inheritedCacheTTLLabel(inherited))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
                var a = settings.anthropic ?? ClarkAnthropicExtras()
                a.cacheEnabled = newValue
                settings.anthropic = a.isEmpty ? nil : a
            }
        )
    }

    private var cacheTTLBinding: Binding<ClarkCacheTTL?> {
        Binding(
            get: { settings.anthropic?.cacheTTL },
            set: { newValue in
                var a = settings.anthropic ?? ClarkAnthropicExtras()
                a.cacheTTL = newValue
                settings.anthropic = a.isEmpty ? nil : a
            }
        )
    }

    private func inheritedCacheEnabledLabel(_ v: Bool?) -> String {
        switch v {
        case .some(true):  return "Inherits On"
        case .some(false): return "Inherits Off"
        case .none:        return "Inherits On (default)"
        }
    }

    private func inheritedCacheTTLLabel(_ v: ClarkCacheTTL?) -> String {
        switch v {
        case .some(.fiveMinutes): return "Inherits 5 min"
        case .some(.oneHour):     return "Inherits 1 hour"
        case .none:               return "Inherits 5 min (default)"
        }
    }

    // MARK: - OpenAI extras

    @ViewBuilder
    private var openaiSection: some View {
        formSection("OpenAI extras") {
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
                        Text("Inherit").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if settings.openai?.parallelToolCalls == nil,
                   let inherited = inheritedSettings?.openai?.parallelToolCalls {
                    Text("Inherits \(inherited ? "On" : "Off")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Service tier
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    fieldLabel("Service tier")
                    Spacer()
                    Picker("Service tier", selection: serviceTierBinding) {
                        Text("Inherit").tag(ClarkServiceTier?.none)
                        Text("Auto").tag(ClarkServiceTier?.some(.auto))
                        Text("Standard").tag(ClarkServiceTier?.some(.standard))
                        Text("Priority").tag(ClarkServiceTier?.some(.priority))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if settings.openai?.serviceTier == nil,
                   let inherited = inheritedSettings?.openai?.serviceTier {
                    Text("Inherits \(serviceTierLabel(inherited))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            responseFormatRow
            logitBiasRow
        }
    }

    private func openaiBinding<T>(_ keyPath: WritableKeyPath<ClarkOpenAIExtras, T>) -> Binding<T> where T: Sendable {
        Binding(
            get: { (settings.openai ?? ClarkOpenAIExtras())[keyPath: keyPath] },
            set: { newValue in
                var o = settings.openai ?? ClarkOpenAIExtras()
                o[keyPath: keyPath] = newValue
                settings.openai = o.isEmpty ? nil : o
            }
        )
    }

    private var serviceTierBinding: Binding<ClarkServiceTier?> {
        Binding(
            get: { settings.openai?.serviceTier },
            set: { newValue in
                var o = settings.openai ?? ClarkOpenAIExtras()
                o.serviceTier = newValue
                settings.openai = o.isEmpty ? nil : o
            }
        )
    }

    private func serviceTierLabel(_ t: ClarkServiceTier) -> String {
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
                    Text("Inherit").tag(ResponseFormatKind.inherit)
                    Text("Text").tag(ResponseFormatKind.text)
                    Text("JSON object").tag(ResponseFormatKind.jsonObject)
                    Text("JSON schema").tag(ResponseFormatKind.jsonSchema)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if case .jsonSchema = settings.openai?.responseFormat {
                jsonSchemaEditor
            }
            if settings.openai?.responseFormat == nil,
               let inherited = inheritedSettings?.openai?.responseFormat {
                Text("Inherits \(responseFormatLabel(inherited))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                var o = settings.openai ?? ClarkOpenAIExtras()
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

    private func responseFormatLabel(_ rf: ClarkResponseFormat) -> String {
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

    private func updateOpenAIResponseFormat(_ rf: ClarkResponseFormat) {
        var o = settings.openai ?? ClarkOpenAIExtras()
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
                        var o = settings.openai ?? ClarkOpenAIExtras()
                        o.logitBias = [:]
                        settings.openai = o.isEmpty ? nil : o
                    }
                )
            }
            Text("JSON object mapping token IDs (integers) to bias values (doubles, [-100, 100]).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            jsonEditor(
                title: "Logit bias JSON",
                text: logitBiasJSONString,
                onChange: { newJSON in
                    let map = parseLogitBiasJSON(newJSON)
                    var o = settings.openai ?? ClarkOpenAIExtras()
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
                    .font(.caption2)
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

    private func updateGoogle<T>(_ keyPath: WritableKeyPath<ClarkGoogleExtras, T>, _ value: T) {
        var g = settings.google ?? ClarkGoogleExtras()
        g[keyPath: keyPath] = value
        settings.google = g.isEmpty ? nil : g
    }

    private func googleBinding<T>(_ keyPath: WritableKeyPath<ClarkGoogleExtras, T>) -> Binding<T> where T: Sendable {
        Binding(
            get: { (settings.google ?? ClarkGoogleExtras())[keyPath: keyPath] },
            set: { updateGoogle(keyPath, $0) }
        )
    }

    private func googleStringBinding(_ keyPath: WritableKeyPath<ClarkGoogleExtras, String?>) -> Binding<String> {
        Binding(
            get: { settings.google?[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.isEmpty ? nil : newValue
                updateGoogle(keyPath, trimmed)
            }
        )
    }

    private func googleSafetyBinding(_ keyPath: WritableKeyPath<ClarkSafetySettings, ClarkHarmThreshold?>) -> Binding<ClarkHarmThreshold?> {
        Binding(
            get: { settings.google?.safetySettings?[keyPath: keyPath] },
            set: { newValue in
                var g = settings.google ?? ClarkGoogleExtras()
                var s = g.safetySettings ?? ClarkSafetySettings()
                s[keyPath: keyPath] = newValue
                g.safetySettings = s.isEmpty ? nil : s
                settings.google = g.isEmpty ? nil : g
            }
        )
    }

    private func safetyThresholdRow(
        title: String,
        value: Binding<ClarkHarmThreshold?>,
        inherited: ClarkHarmThreshold?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel(title)
                Spacer()
                Picker(title, selection: value) {
                    Text("Inherit").tag(ClarkHarmThreshold?.none)
                    Text("None").tag(ClarkHarmThreshold?.some(.blockNone))
                    Text("Low+").tag(ClarkHarmThreshold?.some(.blockLowAndAbove))
                    Text("Med+").tag(ClarkHarmThreshold?.some(.blockMediumAndAbove))
                    Text("High").tag(ClarkHarmThreshold?.some(.blockOnlyHigh))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if value.wrappedValue == nil, let inherited {
                Text("Inherits \(harmLabel(inherited))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func harmLabel(_ t: ClarkHarmThreshold) -> String {
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
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel(title)
                Spacer()
                if let v = value.wrappedValue {
                    Text(format(v))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                } else if let inherited {
                    Text("\(format(inherited)) (inherited)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                resetButton(
                    isOverridden: value.wrappedValue != nil,
                    inheritedSummary: inherited.map { format($0) },
                    onReset: { value.wrappedValue = nil }
                )
            }
            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Slider(
                value: Binding(
                    get: { value.wrappedValue ?? inherited ?? range.lowerBound },
                    set: { value.wrappedValue = $0 }
                ),
                in: range,
                step: step
            )
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
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                } else if let inherited {
                    Text("\(inherited.formatted()) (inherited)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.callout.monospacedDigit())
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
                .font(.caption2)
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
                .font(.caption2)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(.callout)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 80, maxHeight: 240)
                .onChange(of: text) { _, newValue in onChange(newValue) }
            if !text.isEmpty, !isValidJSON(text) {
                Label("Doesn't parse as JSON.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { text = initial }
    }

    private func isValidJSON(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
