import SwiftUI
import PsmithKit
import PsmithUI

/// The call-settings editor for every layer: a conversation's overrides
/// (CallSettingsPage), a provider's defaults (SettingsProviderDefaults), a
/// model's defaults and a profile's (same look as provider defaults).
///
/// It edits one sparse layer. A field left unset inherits from the layer
/// below; `inherited` is that layer's resolved value, shown muted. Sections
/// always show, even when they don't apply to the current model, so a
/// stored value stays visible and clearable.
///
/// `.page` is the themed conversation look: field blocks with a
/// description under each and a dot marking an override. `.settings` is
/// the compact neutral-ground look: one row per field, a slider only once
/// the field is set.
struct IKCallSettingsForm: View {
    enum Style { case page, settings }

    @Binding var settings: PsmithCallSettings
    var inherited: PsmithCallSettings?
    var driverType: String
    var capabilities: PsmithModelCapabilities?
    var constraints: PsmithModelConstraints?
    /// Profile and conversation layers show every provider's extras behind
    /// tabs; provider and model layers show only their own driver's.
    var showAllProviderSections = true
    var style: Style = .page

    @State private var extrasTab: ExtrasTab?
    @Environment(\.theme) private var theme

    enum ExtrasTab: String, CaseIterable, Hashable {
        case anthropic = "Anthropic", openai = "OpenAI", google = "Google"
        init(driverType: String) {
            switch driverType {
            case "openai-compatible": self = .openai
            case "google": self = .google
            default: self = .anthropic
            }
        }
    }

    private var ground: IKGround { style == .page ? .themed : .settings }
    private var tab: ExtrasTab { extrasTab ?? ExtrasTab(driverType: driverType) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head("Common")
            group {
                temperatureField
                sliderField("Top P", key: "topP",
                            description: "Nucleus sampling cutoff. Lower values keep generation focused on the most likely tokens.",
                            value: $settings.topP, inherited: inherited?.topP, range: 0...1, step: 0.05)
                stepperField("Max output tokens", description: "Hard cap on tokens the model can generate in one turn.",
                             value: $settings.maxOutputTokens, inherited: inherited?.maxOutputTokens,
                             step: 256, range: 1...200_000)
                stepperField("Top K",
                             description: "Limit sampling to the top K tokens. Honoured by Anthropic and Google; other providers ignore it.",
                             value: $settings.topK, inherited: inherited?.topK, step: 1, range: 1...500)
                stopSequencesField
            }

            head("Thinking")
            group {
                menuField("Effort",
                          description: "How hard the model reasons before answering. Off is honoured where the model can stop; elsewhere it means the lowest level.",
                          value: thinkingEffort,
                          options: PsmithThinkingEffort.allCases.map { ($0, $0.label) },
                          inherited: inherited?.thinking?.effort.map(\.label))
            }
            if capabilities?.thinking == false {
                note("The selected model doesn't support thinking. These are saved but ignored until you switch to one that does.")
            }

            head("Caching")
            group { explicitCacheField }

            if showAllProviderSections {
                head("Provider extras")
                IKSegmented(options: ExtrasTab.allCases.map { ($0, $0.rawValue) },
                            selection: Binding(get: { tab }, set: { extrasTab = $0 }))
                Text(tab == ExtrasTab(driverType: driverType)
                     ? "Applies to the currently selected model’s provider."
                     : "Saved, but only used when running on \(tab.rawValue).")
                    .font(.system(size: style == .page ? 12.5 : 13))
                    .foregroundStyle(style == .page ? IK.secondary : IK.tertiary)
                    .padding(EdgeInsets(top: 6, leading: 4, bottom: 8, trailing: 4))
                extras(tab)
            } else {
                switch driverType {
                case "anthropic": head("Anthropic extras"); extras(.anthropic)
                case "openai-compatible": head("OpenAI extras"); extras(.openai)
                case "google": head("Google extras"); extras(.google)
                default: EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func extras(_ t: ExtrasTab) -> some View {
        switch t {
        case .anthropic:
            group {
                menuField("Prompt caching",
                          description: "When off, no cache_control marker is sent. Useful for one-off conversations or privacy.",
                          value: anthropic(\.cacheEnabled),
                          options: [(true, "On"), (false, "Off")],
                          inherited: inherited?.anthropic?.cacheEnabled.map { $0 ? "On" : "Off" } ?? "On")
                menuField("Cache TTL",
                          description: style == .page ? "1 hour costs more to write but survives stop-and-resume workflows." : nil,
                          value: anthropic(\.cacheTTL),
                          options: [(.fiveMinutes, "5 min"), (.oneHour, "1 hour")],
                          inherited: inherited?.anthropic?.cacheTTL.map(ttlLabel) ?? "5 min")
                    .opacity(settings.anthropic?.cacheEnabled == false ? 0.45 : 1)
                    .allowsHitTesting(settings.anthropic?.cacheEnabled != false)
            }
            if style == .settings {
                note("1 hour costs more to write but survives stop-and-resume work.")
            }
        case .openai:
            group {
                stepperField("Seed", description: "Reproducibility seed. Set to make outputs deterministic across calls.",
                             value: openai(\.seed), inherited: inherited?.openai?.seed, step: 1,
                             range: -1_000_000...1_000_000)
                sliderField("Frequency penalty", key: "freq",
                            description: "Penalize tokens by how often they’ve already appeared. Range −2 to 2.",
                            value: openai(\.frequencyPenalty), inherited: inherited?.openai?.frequencyPenalty,
                            range: -2...2, step: 0.1)
                sliderField("Presence penalty", key: "presence",
                            description: "Penalize tokens that appeared at all. Range −2 to 2.",
                            value: openai(\.presencePenalty), inherited: inherited?.openai?.presencePenalty,
                            range: -2...2, step: 0.1)
                stepperField("Top logprobs",
                             description: "How many top alternatives to return for each output token. Range 0 to 5.",
                             value: openai(\.topLogprobs), inherited: inherited?.openai?.topLogprobs, step: 1, range: 0...5)
                menuField("Parallel tool calls", description: nil, value: openai(\.parallelToolCalls),
                          options: [(true, "On"), (false, "Off")],
                          inherited: inherited?.openai?.parallelToolCalls.map { $0 ? "On" : "Off" })
                menuField("Service tier", description: nil, value: openai(\.serviceTier),
                          options: [(.auto, "Auto"), (.standard, "Standard"), (.priority, "Priority")],
                          inherited: inherited?.openai?.serviceTier.map(tierLabel))
                responseFormatField
                jsonField("Logit bias",
                          description: "JSON object mapping token IDs to bias values from −100 to 100.",
                          text: logitBiasText, isSet: !(settings.openai?.logitBias.isEmpty ?? true),
                          inheritedSummary: inherited?.openai?.logitBias.isEmpty == false
                              ? "\(inherited?.openai?.logitBias.count ?? 0) entries" : nil,
                          onChange: setLogitBias,
                          onReset: { mutateOpenAI { $0.logitBias = [:] } })
            }
        case .google:
            group {
                safetyField("Harassment", \.harassment)
                safetyField("Hate speech", \.hateSpeech)
                safetyField("Sexually explicit", \.sexuallyExplicit)
                safetyField("Dangerous content", \.dangerousContent)
                textField("Response MIME type", placeholder: inherited?.google?.responseMimeType.map { "Inherits \($0)" } ?? "application/json",
                          value: Binding(get: { settings.google?.responseMimeType ?? "" },
                                         set: { v in mutateGoogle { $0.responseMimeType = v.isEmpty ? nil : v } }))
                jsonField("Response schema", description: "JSON schema that constrains the response shape.",
                          text: settings.google?.responseSchema.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                          isSet: settings.google?.responseSchema != nil,
                          inheritedSummary: inherited?.google?.responseSchema != nil ? "set" : nil,
                          onChange: { s in mutateGoogle { $0.responseSchema = s.isEmpty ? nil : s.data(using: .utf8) } },
                          onReset: { mutateGoogle { $0.responseSchema = nil } })
                stepperField("Candidate count", description: "How many candidate completions to request. Range 1 to 8.",
                             value: google(\.candidateCount), inherited: inherited?.google?.candidateCount, step: 1, range: 1...8)
            }
        }
    }

    // MARK: - Structure

    private func head(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(IK.tertiary)
            .padding(EdgeInsets(top: 18, leading: 4, bottom: 6, trailing: 4))
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        IKGroup(ground: ground) { content() }
    }

    private func note(_ text: String) -> some View {
        IKPageNote(text, settings: style == .settings)
    }

    // MARK: - Value display

    private func valueLabel(set: String?, inherited: String?, none: String = "Not set") -> some View {
        Group {
            if let set {
                Text(set).font(.system(size: style == .page ? 14 : 15, design: .monospaced)).foregroundStyle(IK.text)
            } else if let inherited {
                Text("\(inherited) (Inherited)").font(.system(size: style == .page ? 14 : 15)).foregroundStyle(IK.tertiary)
            } else {
                Text(none).font(.system(size: style == .page ? 14 : 15)).foregroundStyle(IK.tertiary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    /// A field block in page style, a row in settings style.
    @ViewBuilder
    private func field<Control: View, Trailing: View>(
        _ title: String, isSet: Bool, description: String?, vPad: CGFloat = 8,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder control: () -> Control
    ) -> some View {
        switch style {
        case .page:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if isSet { IKOverrideDot() }
                    Text(title).font(.system(size: 15.5)).foregroundStyle(IK.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
                .frame(minHeight: 28)
                control()
                if let description {
                    Text(description).font(.system(size: 12.5)).ikLineHeight(12.5, 17).foregroundStyle(IK.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        case .settings:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(title).font(.system(size: 16)).foregroundStyle(IK.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
                .frame(minHeight: isSet ? 28 : 24)
                control()
                if let description {
                    Text(description).font(.system(size: 12.5)).ikLineHeight(12.5, 17).foregroundStyle(IK.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, vPad)
            .frame(minHeight: 44)
        }
    }

    // MARK: - Common fields

    private var temperatureRange: ClosedRange<Double> {
        if let r = constraints?.temperature {
            if let l = r.lockedAt { return l...l }
            let lo = r.min ?? 0, hi = r.max ?? (driverType == "anthropic" ? 1 : 2)
            if lo <= hi { return lo...hi }
        }
        return driverType == "anthropic" ? 0...1 : 0...2
    }

    private var temperatureDescription: String {
        if let r = constraints?.temperature {
            if let l = r.lockedAt { return "This model locks temperature at \(String(format: "%.2f", l))." }
            if r.min != nil || r.max != nil {
                let lo = r.min.map { String(format: "%.2f", $0) } ?? "0"
                let hi = r.max.map { String(format: "%.2f", $0) } ?? "any"
                return "This model accepts \(lo) to \(hi)."
            }
        }
        switch (driverType, style) {
        case ("anthropic", .page): return "Sampling temperature. Anthropic clamps to [0, 1]."
        case ("anthropic", .settings): return "Anthropic clamps to 0 to 1."
        case ("google", .page), ("openai-compatible", .page): return "Sampling temperature. Range [0, 2]; higher is more creative."
        case ("google", .settings), ("openai-compatible", .settings): return "Range 0 to 2. Higher is more creative."
        default: return "Sampling temperature."
        }
    }

    @ViewBuilder
    private var temperatureField: some View {
        if constraints?.temperature?.lockedAt != nil {
            field("Temperature", isSet: false, description: temperatureDescription) {
                Text(String(format: "%.2f", temperatureRange.lowerBound)).font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(IK.secondary)
                Text("locked").font(.system(size: 12.5)).foregroundStyle(IK.tertiary)
            } control: { EmptyView() }
        } else {
            sliderField("Temperature", key: "temperature", description: temperatureDescription,
                        value: $settings.temperature, inherited: inherited?.temperature,
                        range: temperatureRange, step: 0.05)
        }
    }

    @ViewBuilder
    private func sliderField(_ title: String, key: String, description: String?, value: Binding<Double?>,
                             inherited: Double?, range: ClosedRange<Double>, step: Double) -> some View {
        let fmt: (Double) -> String = { String(format: "%.2f", $0) }
        let isSet = value.wrappedValue != nil
        let shown = Binding<Double>(get: { value.wrappedValue ?? inherited ?? range.lowerBound },
                                    set: { value.wrappedValue = $0 })
        switch style {
        case .page:
            field(title, isSet: isSet, description: description) {
                valueLabel(set: value.wrappedValue.map(fmt), inherited: inherited.map(fmt))
                if isSet { IKResetButton(label: resetLabel(inherited.map(fmt))) { value.wrappedValue = nil } }
            } control: {
                IKSlider(value: shown, range: range, step: step, muted: !isSet).padding(.top, 4)
                    .accessibilityLabel(title)
            }
        case .settings:
            field(title, isSet: isSet, description: isSet ? description : nil, vPad: 10) {
                valueLabel(set: value.wrappedValue.map(fmt), inherited: inherited.map(fmt))
                if isSet { IKResetButton(label: "Reset \(title.lowercased())") { value.wrappedValue = nil } }
            } control: {
                if isSet {
                    IKSlider(value: shown, range: range, step: step, thumb: 28).padding(.top, 15)
                        .accessibilityLabel(title)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isSet { value.wrappedValue = inherited ?? (range.lowerBound + range.upperBound) / 2 } }
        }
    }

    private func stepperField(_ title: String, description: String?, value: Binding<Int32?>, inherited: Int32?,
                              step: Int32, range: ClosedRange<Int32>) -> some View {
        let isSet = value.wrappedValue != nil
        let base = value.wrappedValue ?? inherited ?? range.lowerBound
        return field(title, isSet: isSet, description: style == .page ? description : nil) {
            valueLabel(set: value.wrappedValue.map { $0.formatted() }, inherited: inherited.map { $0.formatted() })
            IKStepper(label: title.lowercased(), segmentWidth: style == .page ? 44 : 46,
                      onDecrement: { value.wrappedValue = isSet ? max(base - step, range.lowerBound) : base },
                      onIncrement: { value.wrappedValue = isSet ? min(base + step, range.upperBound) : base })
                .padding(.leading, style == .page ? 0 : -4)
            if isSet {
                IKResetButton(label: style == .page ? resetLabel(inherited.map { $0.formatted() }) : "Reset \(title.lowercased())") {
                    value.wrappedValue = nil
                }
            }
        } control: { EmptyView() }
    }

    @ViewBuilder
    private var stopSequencesField: some View {
        let list = settings.stopSequences
        let inheritedList = inherited?.stopSequences ?? []
        let summary: String? = list.isEmpty ? (inheritedList.isEmpty ? nil : "Inherits (\(inheritedList.count))") : nil
        switch style {
        case .page:
            field("Stop sequences", isSet: !list.isEmpty, description: nil) {
                if let summary { Text(summary).font(.system(size: 14)).foregroundStyle(IK.tertiary) }
                if !list.isEmpty { IKResetButton(label: "Reset stop sequences") { settings.stopSequences = [] } }
            } control: {
                stopSequenceEditors
                Button { settings.stopSequences.append("") } label: {
                    Label("Add stop sequence", systemImage: "plus").font(.system(size: 15))
                        .labelStyle(IKTightLabel())
                        .foregroundStyle(theme.accentInk)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                Text("Strings that, when generated, end the response.")
                    .font(.system(size: 12.5)).foregroundStyle(IK.secondary)
            }
        case .settings:
            ForEach(Array(list.enumerated()), id: \.offset) { idx, _ in
                stopSequenceRow(idx).padding(.horizontal, 14).frame(minHeight: 44)
            }
            Button { settings.stopSequences.append("") } label: {
                HStack(spacing: 12) {
                    Text("Add stop sequence").font(.system(size: 16)).foregroundStyle(theme.accentInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(list.isEmpty ? (summary ?? "None") : "\(list.count)").font(.system(size: 15))
                        .foregroundStyle(IK.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var stopSequenceEditors: some View {
        if !settings.stopSequences.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(settings.stopSequences.enumerated()), id: \.offset) { idx, _ in
                    stopSequenceRow(idx)
                }
            }
            .padding(.top, 6)
        }
    }

    private func stopSequenceRow(_ idx: Int) -> some View {
        HStack(spacing: 8) {
            IKFieldWell {
                TextField("Stop sequence", text: Binding(
                    get: { idx < settings.stopSequences.count ? settings.stopSequences[idx] : "" },
                    set: { if idx < settings.stopSequences.count { settings.stopSequences[idx] = $0 } }))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(IK.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button { if idx < settings.stopSequences.count { settings.stopSequences.remove(at: idx) } } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 20)).foregroundStyle(IK.red)
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove stop sequence")
        }
    }

    // MARK: - Menus and toggles

    private func menuField<T: Hashable>(_ title: String, description: String?, value: Binding<T?>,
                                        options: [(T, String)], inherited: String?) -> some View {
        let current = value.wrappedValue.flatMap { v in options.first(where: { $0.0 == v })?.1 }
        let shown = current ?? (inherited.map { "Inherit (\($0))" } ?? "Inherit")
        let menu = Menu {
            Picker(title, selection: value) {
                Text(inherited.map { "Inherit (\($0))" } ?? "Inherit").tag(T?.none)
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in Text(o.1).tag(T?.some(o.0)) }
            }
        } label: {
            HStack(spacing: style == .page ? 6 : 8) {
                Text(shown).font(.system(size: style == .page ? 14 : 15))
                    .foregroundStyle(style == .page ? (current == nil ? IK.secondary : theme.accentInk)
                                     : (current == nil ? IK.secondary : IK.text))
                IKMenuChevrons().foregroundStyle(style == .page ? (current == nil ? IK.secondary : theme.accentInk) : IK.chevron)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        return field(title, isSet: current != nil, description: style == .page ? description : nil) {
            menu
            if style == .page && current != nil {
                IKResetButton(label: resetLabel(inherited)) { value.wrappedValue = nil }
            }
        } control: { EmptyView() }
    }

    @ViewBuilder
    private var explicitCacheField: some View {
        let v = settings.explicitCache
        let inh = inherited?.explicitCache
        let toggle = Toggle("Explicit caching", isOn: Binding(get: { v ?? inh ?? false },
                                                               set: { settings.explicitCache = $0 }))
            .labelsHidden()
            .tint(theme.accent)
        let state: String = v.map { $0 ? "Enabled" : "Disabled" }
            ?? inh.map { $0 ? "Enabled (Inherited)" : "Disabled (Inherited)" } ?? "Inherit"
        switch style {
        case .page:
            field("Explicit caching", isSet: v != nil,
                  description: "On Anthropic, raises the cache lifetime from 5 minutes to 1 hour. On Google, places cached content for you, billed per hour. Elsewhere it does nothing.") {
                Text(state).font(.system(size: 14)).foregroundStyle(v == nil ? IK.tertiary : IK.text)
                    .padding(.trailing, 0)
                if v != nil { IKResetButton(label: resetLabel(inh.map { $0 ? "On" : "Off" })) { settings.explicitCache = nil } }
                toggle
            } control: { EmptyView() }
        case .settings:
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explicit caching").font(.system(size: 16)).foregroundStyle(IK.text)
                    Text("\(state) · \(explicitCacheEffect)").font(.system(size: 12.5)).foregroundStyle(IK.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if v != nil { IKResetButton(label: "Reset explicit caching") { settings.explicitCache = nil } }
                toggle
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
        }
    }

    private var explicitCacheEffect: String {
        switch driverType {
        case "anthropic": "raises Anthropic’s cache TTL to 1 hour"
        case "google": "Google places cached content, billed per hour"
        default: "does nothing on this provider"
        }
    }

    private func safetyField(_ title: String, _ kp: WritableKeyPath<PsmithSafetySettings, PsmithHarmThreshold?>) -> some View {
        menuField(title, description: nil,
                  value: Binding(get: { settings.google?.safetySettings?[keyPath: kp] },
                                 set: { nv in mutateGoogle { g in
                                     var s = g.safetySettings ?? PsmithSafetySettings()
                                     s[keyPath: kp] = nv
                                     g.safetySettings = s.isEmpty ? nil : s
                                 } }),
                  options: [(.blockNone, "None"), (.blockLowAndAbove, "Low+"), (.blockMediumAndAbove, "Med+"), (.blockOnlyHigh, "High")],
                  inherited: inherited?.google?.safetySettings?[keyPath: kp].map(harmLabel))
    }

    private func textField(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        field(title, isSet: !value.wrappedValue.isEmpty, description: nil) {
            if !value.wrappedValue.isEmpty { IKResetButton(label: "Reset \(title.lowercased())") { value.wrappedValue = "" } }
        } control: {
            IKFieldWell {
                TextField(placeholder, text: value)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(IK.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.top, 6)
        }
    }

    private func jsonField(_ title: String, description: String, text: String, isSet: Bool, inheritedSummary: String?,
                           onChange: @escaping (String) -> Void, onReset: @escaping () -> Void) -> some View {
        field(title, isSet: isSet, description: description) {
            if !isSet, let inheritedSummary {
                Text("Inherits (\(inheritedSummary))").font(.system(size: 14)).foregroundStyle(IK.tertiary)
            }
            if isSet { IKResetButton(label: "Reset \(title.lowercased())", action: onReset) }
        } control: {
            IKJSONEditor(initial: text, onChange: onChange).padding(.top, 6)
        }
    }

    // MARK: - Response format

    private enum FormatKind: Hashable { case text, jsonObject, jsonSchema }

    @ViewBuilder
    private var responseFormatField: some View {
        menuField("Response format", description: nil,
                  value: Binding<FormatKind?>(
                    get: {
                        switch settings.openai?.responseFormat {
                        case nil: nil
                        case .text: .text
                        case .jsonObject: .jsonObject
                        case .jsonSchema: .jsonSchema
                        }
                    },
                    set: { k in mutateOpenAI { o in
                        switch k {
                        case nil: o.responseFormat = nil
                        case .text: o.responseFormat = .text
                        case .jsonObject: o.responseFormat = .jsonObject
                        case .jsonSchema:
                            if case .jsonSchema = o.responseFormat {} else {
                                o.responseFormat = .jsonSchema(name: "", description: nil, schema: Data(), strict: nil)
                            }
                        }
                    } }),
                  options: [(.text, "Text"), (.jsonObject, "JSON object"), (.jsonSchema, "JSON schema")],
                  inherited: inherited?.openai?.responseFormat.map(formatLabel))
        if case .jsonSchema(let name, let desc, let schema, let strict) = settings.openai?.responseFormat {
            VStack(alignment: .leading, spacing: 8) {
                IKFieldWell {
                    TextField("Schema name", text: Binding(get: { name }, set: { setSchema(name: $0, description: desc, schema: schema, strict: strict) }))
                        .font(.system(size: 15)).foregroundStyle(IK.text)
                }
                IKFieldWell {
                    TextField("Description (optional)", text: Binding(get: { desc ?? "" },
                                                                       set: { setSchema(name: name, description: $0.isEmpty ? nil : $0, schema: schema, strict: strict) }))
                        .font(.system(size: 15)).foregroundStyle(IK.text)
                }
                Toggle("Strict", isOn: Binding(get: { strict ?? false },
                                               set: { setSchema(name: name, description: desc, schema: schema, strict: $0) }))
                    .font(.system(size: 15)).foregroundStyle(IK.text).tint(theme.accent)
                IKJSONEditor(initial: String(data: schema, encoding: .utf8) ?? "") { s in
                    setSchema(name: name, description: desc, schema: s.data(using: .utf8) ?? Data(), strict: strict)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func setSchema(name: String, description: String?, schema: Data, strict: Bool?) {
        mutateOpenAI { $0.responseFormat = .jsonSchema(name: name, description: description, schema: schema, strict: strict) }
    }

    // MARK: - Bindings

    private var thinkingEffort: Binding<PsmithThinkingEffort?> {
        Binding(get: { settings.thinking?.effort }, set: { nv in
            var t = settings.thinking ?? PsmithThinkingSettings()
            t.effort = nv
            settings.thinking = t.isEmpty ? nil : t
        })
    }

    private func anthropic<T>(_ kp: WritableKeyPath<PsmithAnthropicExtras, T?>) -> Binding<T?> {
        Binding(get: { settings.anthropic?[keyPath: kp] }, set: { nv in
            var a = settings.anthropic ?? PsmithAnthropicExtras()
            a[keyPath: kp] = nv
            settings.anthropic = a.isEmpty ? nil : a
        })
    }

    private func openai<T>(_ kp: WritableKeyPath<PsmithOpenAIExtras, T?>) -> Binding<T?> {
        Binding(get: { settings.openai?[keyPath: kp] }, set: { nv in mutateOpenAI { $0[keyPath: kp] = nv } })
    }

    private func google<T>(_ kp: WritableKeyPath<PsmithGoogleExtras, T?>) -> Binding<T?> {
        Binding(get: { settings.google?[keyPath: kp] }, set: { nv in mutateGoogle { $0[keyPath: kp] = nv } })
    }

    private func mutateOpenAI(_ f: (inout PsmithOpenAIExtras) -> Void) {
        var o = settings.openai ?? PsmithOpenAIExtras()
        f(&o)
        settings.openai = o.isEmpty ? nil : o
    }

    private func mutateGoogle(_ f: (inout PsmithGoogleExtras) -> Void) {
        var g = settings.google ?? PsmithGoogleExtras()
        f(&g)
        settings.google = g.isEmpty ? nil : g
    }

    private var logitBiasText: String {
        guard let map = settings.openai?.logitBias, !map.isEmpty else { return "" }
        let keyed = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        guard let d = try? JSONSerialization.data(withJSONObject: keyed, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    private func setLogitBias(_ s: String) {
        var out: [Int32: Double] = [:]
        if let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj {
                guard let key = Int32(k) else { continue }
                if let x = v as? Double { out[key] = x } else if let i = v as? Int { out[key] = Double(i) }
            }
        }
        mutateOpenAI { $0.logitBias = out }
    }

    // MARK: - Labels

    private func resetLabel(_ inherited: String?) -> String {
        inherited.map { "Reset to inherited (\($0))" } ?? "Reset to inherited"
    }

    private func ttlLabel(_ t: PsmithCacheTTL) -> String { t == .oneHour ? "1 hour" : "5 min" }

    private func tierLabel(_ t: PsmithServiceTier) -> String {
        switch t { case .auto: "Auto"; case .standard: "Standard"; case .priority: "Priority" }
    }

    private func formatLabel(_ f: PsmithResponseFormat) -> String {
        switch f { case .text: "Text"; case .jsonObject: "JSON object"; case .jsonSchema: "JSON schema" }
    }

    private func harmLabel(_ t: PsmithHarmThreshold) -> String {
        switch t {
        case .blockNone: "None"
        case .blockLowAndAbove: "Low+"
        case .blockMediumAndAbove: "Med+"
        case .blockOnlyHigh: "High"
        }
    }
}

/// Icon and title 6pt apart, as the boards' text buttons draw them.
struct IKTightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 13, weight: .semibold))
            configuration.title
        }
    }
}

/// A monospaced JSON editor, 80 to 240pt tall. Invalid JSON is still
/// stored; the note only warns.
struct IKJSONEditor: View {
    let initial: String
    let onChange: (String) -> Void
    @State private var text = ""
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(IK.text)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(6)
                .frame(minHeight: 80, maxHeight: 240)
                .background(RoundedRectangle(cornerRadius: 10).fill(IK.fieldWell))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(IK.ring(0.08), lineWidth: 1))
                .onChange(of: text) { _, v in if seeded { onChange(v) } }
            if !text.isEmpty, !Self.parses(text) {
                Label("Doesn't parse as JSON.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5)).foregroundStyle(IK.red)
            }
        }
        .onAppear {
            text = initial
            DispatchQueue.main.async { seeded = true }
        }
    }

    static func parses(_ s: String) -> Bool {
        guard let d = s.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
    }
}

// MARK: - Unsaved changes

enum IKCallSettingsDiff {
    /// How many fields differ between two layers, counted the way the save
    /// bar reads them ("2 unsaved changes").
    static func count(_ a: PsmithCallSettings, _ b: PsmithCallSettings) -> Int {
        fields(a).enumerated().filter { $0.element != fields(b)[$0.offset] }.count
    }

    /// How many fields a layer sets ("1 override").
    static func setCount(_ a: PsmithCallSettings) -> Int { count(a, PsmithCallSettings()) }

    private static func fields(_ s: PsmithCallSettings) -> [AnyHashable?] {
        func h<T: Hashable>(_ v: T?) -> AnyHashable? { v.map { AnyHashable($0) } }
        var out: [AnyHashable?] = []
        out.append(h(s.temperature))
        out.append(h(s.topP))
        out.append(h(s.maxOutputTokens))
        out.append(h(s.topK))
        out.append(s.stopSequences.isEmpty ? nil : AnyHashable(s.stopSequences))
        out.append(h(s.thinking?.effort))
        out.append(h(s.explicitCache))
        out.append(h(s.anthropic?.cacheEnabled))
        out.append(h(s.anthropic?.cacheTTL))
        let o = s.openai
        out.append(h(o?.seed))
        out.append(h(o?.frequencyPenalty))
        out.append(h(o?.presencePenalty))
        out.append(h(o?.topLogprobs))
        out.append(h(o?.parallelToolCalls))
        out.append(h(o?.serviceTier))
        out.append(h(o?.responseFormat))
        out.append((o?.logitBias.isEmpty ?? true) ? nil : h(o?.logitBias))
        let g = s.google
        out.append(h(g?.safetySettings?.harassment))
        out.append(h(g?.safetySettings?.hateSpeech))
        out.append(h(g?.safetySettings?.sexuallyExplicit))
        out.append(h(g?.safetySettings?.dangerousContent))
        out.append(h(g?.responseMimeType))
        out.append(h(g?.responseSchema))
        out.append(h(g?.candidateCount))
        return out
    }

    static func summary(_ n: Int) -> String { n == 1 ? "1 unsaved change" : "\(n) unsaved changes" }
}
