import SwiftUI
import PsmithKit

/// One layer of call settings (boards "Models · provider defaults",
/// "… driver settings", the model page and a profile's Model tab). Every
/// field is optional: unset inherits from the layers below, shown in blue
/// under the row; set shows a reset button that clears it.
struct SKCallSettings: View {
    @Binding var settings: PsmithCallSettings
    /// The lower layers merged, for the blue "inherits" lines.
    var inherited: PsmithCallSettings?
    /// Where `inherited` comes from: "Anthropic", "Claude Sonnet 4.6 and Anthropic".
    var inheritedFrom: String?
    /// The provider driver: "anthropic", "openai-compatible", "google".
    let driver: String
    /// Profiles and conversations can run on any provider, so they get a
    /// driver switch; providers and models show their own driver only.
    var driverTabs = false
    var constraints: PsmithModelConstraints?

    @State private var tab = ""
    @State private var addingStop = false
    @State private var newStop = ""

    private var shownDriver: String { tab.isEmpty ? Self.normalized(driver) : tab }

    static func normalized(_ driver: String) -> String {
        switch driver {
        case "google": "google"
        case "anthropic": "anthropic"
        default: "openai-compatible"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sampling
            thinking
            switch shownDriver {
            case "anthropic": anthropic
            case "google": google
            default: openai
            }
        }
    }

    // MARK: Rows

    /// The board's setting row: title, detail, an inherited line in blue,
    /// the control, and a reset button when this layer sets the field.
    private func row<C: View>(_ title: String, detail: String? = nil, inherits: String? = nil, isSet: Bool, reset: @escaping () -> Void, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).sk(13).skOneLine(13)
                if detail != nil || (inherits != nil && !isSet) {
                    (Text(detail.map { $0 + (inherits != nil && !isSet ? " " : "") } ?? "")
                        + Text(!isSet ? (inherits ?? "") : "").foregroundStyle(SK.link))
                        .sk(11.5, SK.secondary)
                        .skLineHeight(11.5, 1.35)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                control()
                if isSet {
                    Button(action: reset) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10.5, weight: .medium)).frame(width: 12)
                    }
                    .skButton(small: true, compact: true)
                    .help("Reset to inherited")
                    .accessibilityLabel("Reset \(title)")
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }

    private func inherits(_ value: String?) -> String? {
        guard let value, let inheritedFrom else { return nil }
        return "Inherits \(value) from \(inheritedFrom)"
    }

    private func number(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

    // MARK: Sampling

    private var tempRange: ClosedRange<Double> {
        if let r = constraints?.temperature, let lo = r.min, let hi = r.max { return lo...hi }
        return Self.normalized(driver) == "anthropic" ? 0...1 : 0...2
    }

    private var tempDetail: String {
        if let locked = constraints?.temperature?.lockedAt { return "This model locks temperature at \(number(locked))." }
        if constraints?.temperature != nil { return "This model accepts \(number(tempRange.lowerBound)) to \(number(tempRange.upperBound))." }
        return Self.normalized(driver) == "anthropic" ? "0 to 1 for Anthropic." : "0 to 2. Higher is more varied."
    }

    private var sampling: some View {
        SKGroup("Sampling") {
            row("Temperature", detail: tempDetail, inherits: inherits(inherited?.temperature.map { number($0) }),
                isSet: settings.temperature != nil, reset: { settings.temperature = nil }) {
                HStack(spacing: 10) {
                    SKSlider(value: Binding(get: { settings.temperature ?? inherited?.temperature ?? tempRange.lowerBound },
                                            set: { settings.temperature = $0 }),
                             range: tempRange, step: 0.05, width: 160)
                        .disabled(constraints?.temperature?.lockedAt != nil)
                    valueText(settings.temperature.map { number($0) })
                }
            }
            row("Top P", inherits: inherits(inherited?.topP.map { number($0) }), isSet: settings.topP != nil, reset: { settings.topP = nil }) {
                HStack(spacing: 10) {
                    SKSlider(value: Binding(get: { settings.topP ?? inherited?.topP ?? 0 }, set: { settings.topP = $0 }),
                             range: 0...1, step: 0.05, width: 160)
                    valueText(settings.topP.map { number($0) })
                }
            }
            row("Max output tokens", inherits: inherits(inherited?.maxOutputTokens.map { $0.formatted() }),
                isSet: settings.maxOutputTokens != nil, reset: { settings.maxOutputTokens = nil }) {
                SKOptionalStepper(value: $settings.maxOutputTokens, range: 1...200_000, step: 256)
            }
            row("Top K", detail: "Anthropic and Google only.", inherits: inherits(inherited?.topK.map { "\($0)" }),
                isSet: settings.topK != nil, reset: { settings.topK = nil }) {
                SKOptionalStepper(value: $settings.topK, range: 1...500, step: 1)
            }
            row("Stop sequences", inherits: settings.stopSequences.isEmpty ? inherits(inherited.flatMap { $0.stopSequences.isEmpty ? nil : "\($0.stopSequences.count)" }) : nil,
                isSet: !settings.stopSequences.isEmpty, reset: { settings.stopSequences = [] }) {
                HStack(spacing: 6) {
                    ForEach(settings.stopSequences, id: \.self) { stop in
                        Button { settings.stopSequences.removeAll { $0 == stop } } label: {
                            SKChip(text: stop, color: SK.text)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(stop)")
                    }
                    if addingStop {
                        SKTextField(label: "Stop sequence", text: $newStop, width: 90, mono: true)
                            .onSubmit {
                                let s = newStop
                                if !s.isEmpty, !settings.stopSequences.contains(s) { settings.stopSequences.append(s) }
                                newStop = ""
                                addingStop = false
                            }
                    } else {
                        Button { addingStop = true } label: {
                            HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)); Text("Add") }
                        }
                        .skButton(.plain)
                    }
                }
            }
        } trailing: {
            SKChip.synced
        }
    }

    private func valueText(_ s: String?) -> some View {
        Text(s ?? "—").sk(13, s == nil ? SK.tertiary : SK.text, mono: true).frame(minWidth: 34, alignment: .leading)
    }

    // MARK: Thinking and caching

    private var thinking: some View {
        SKGroup("Thinking and caching") {
            let effort = settings.thinking?.effort
            row("Thinking effort", inherits: inherits(inherited?.thinking?.effort.map(Self.effortLabel)),
                isSet: effort != nil, reset: { settings.thinking = nil }) {
                SKSegmented(
                    options: [(PsmithThinkingEffort?.none, "Inherit")] + PsmithThinkingEffort.allCases.map { (Optional($0), Self.effortLabel($0)) },
                    selection: Binding(get: { effort }, set: { settings.thinking = $0.map { PsmithThinkingSettings(effort: $0) } })
                )
            }
            row("Long cache", detail: "Anthropic keeps the cache an hour instead of five minutes. Google stores it per hour.",
                inherits: inherits(inherited?.explicitCache.map { $0 ? "on" : "off" }),
                isSet: settings.explicitCache != nil, reset: { settings.explicitCache = nil }) {
                HStack(spacing: 8) {
                    if settings.explicitCache == nil { Text("Inherit").sk(12.5, SK.secondary) }
                    Toggle("Long cache", isOn: Binding(get: { settings.explicitCache ?? inherited?.explicitCache ?? false },
                                                       set: { settings.explicitCache = $0 })).skSwitch()
                }
            }
        }
    }

    static func effortLabel(_ e: PsmithThinkingEffort) -> String {
        e == .xhigh ? "Max" : e.label
    }

    // MARK: Driver groups

    @ViewBuilder
    private var driverSwitch: some View {
        if driverTabs {
            SKSegmented(options: [("anthropic", "Anthropic"), ("openai-compatible", "OpenAI"), ("google", "Google")],
                        selection: Binding(get: { shownDriver }, set: { tab = $0 }))
        }
    }

    private var driverFooter: String {
        driverTabs
            ? (shownDriver == Self.normalized(driver) ? "Applies to the selected model's provider." : "Saved, and used only when the conversation runs on this provider.")
            : "Shown for this provider's driver. Profiles and conversations also see the other drivers' settings."
    }

    private var anthropic: some View {
        let a = settings.anthropic
        let caching = a?.cacheEnabled
        return SKGroup(driverTabs ? "Provider settings" : "Anthropic") {
            row("Prompt caching", inherits: caching == nil ? "On by default" : nil, isSet: false, reset: {}) {
                SKSegmented(options: [(Bool?.none, "Inherit"), (true, "On"), (false, "Off")],
                            selection: Binding(get: { caching }, set: { v in updateAnthropic { $0.cacheEnabled = v } }))
            }
            row("Cache lifetime", inherits: a?.cacheTTL == nil ? "5 min by default" : nil, isSet: false, reset: {}) {
                SKSegmented(options: [(PsmithCacheTTL?.none, "Inherit"), (.fiveMinutes, "5 min"), (.oneHour, "1 hour")],
                            selection: Binding(get: { a?.cacheTTL }, set: { v in updateAnthropic { $0.cacheTTL = v } }))
                    .disabled(caching == false)
                    .opacity(caching == false ? 0.45 : 1)
            }
        } trailing: {
            driverSwitch
        } footer: {
            Text(driverFooter)
        }
    }

    private func updateAnthropic(_ f: (inout PsmithAnthropicExtras) -> Void) {
        var a = settings.anthropic ?? PsmithAnthropicExtras()
        f(&a)
        settings.anthropic = a.isEmpty ? nil : a
    }

    private func updateOpenAI(_ f: (inout PsmithOpenAIExtras) -> Void) {
        var o = settings.openai ?? PsmithOpenAIExtras()
        f(&o)
        settings.openai = o.isEmpty ? nil : o
    }

    private func updateGoogle(_ f: (inout PsmithGoogleExtras) -> Void) {
        var g = settings.google ?? PsmithGoogleExtras()
        f(&g)
        settings.google = g.isEmpty ? nil : g
    }

    private enum FormatChoice: Hashable { case inherit, text, json, schema }

    private var format: FormatChoice {
        switch settings.openai?.responseFormat {
        case nil: .inherit
        case .text: .text
        case .jsonObject: .json
        case .jsonSchema: .schema
        }
    }

    private var openai: some View {
        let o = settings.openai
        return SKGroup(driverTabs ? "Provider settings" : "OpenAI") {
            row("Seed", detail: "Same seed, same input, usually the same output.", isSet: o?.seed != nil, reset: { updateOpenAI { $0.seed = nil } }) {
                SKOptionalStepper(value: Binding(get: { o?.seed }, set: { v in updateOpenAI { $0.seed = v } }), range: -1_000_000...1_000_000, step: 1)
            }
            row("Frequency penalty", detail: "−2 to 2. Positive values repeat less.", isSet: o?.frequencyPenalty != nil, reset: { updateOpenAI { $0.frequencyPenalty = nil } }) {
                HStack(spacing: 10) {
                    SKSlider(value: Binding(get: { o?.frequencyPenalty ?? 0 }, set: { v in updateOpenAI { $0.frequencyPenalty = v } }), range: -2...2, step: 0.1, width: 160)
                    valueText(o?.frequencyPenalty.map { number($0, 1) })
                }
            }
            row("Presence penalty", detail: "−2 to 2. Positive values move to new topics.", isSet: o?.presencePenalty != nil, reset: { updateOpenAI { $0.presencePenalty = nil } }) {
                HStack(spacing: 10) {
                    SKSlider(value: Binding(get: { o?.presencePenalty ?? 0 }, set: { v in updateOpenAI { $0.presencePenalty = v } }), range: -2...2, step: 0.1, width: 160)
                    valueText(o?.presencePenalty.map { number($0, 1) })
                }
            }
            row("Top logprobs", detail: "0 to 5.", isSet: o?.topLogprobs != nil, reset: { updateOpenAI { $0.topLogprobs = nil } }) {
                SKOptionalStepper(value: Binding(get: { o?.topLogprobs }, set: { v in updateOpenAI { $0.topLogprobs = v } }), range: 0...5, step: 1)
            }
            row("Parallel tool calls", isSet: false, reset: {}) {
                SKSegmented(options: [(Bool?.none, "Inherit"), (true, "On"), (false, "Off")],
                            selection: Binding(get: { o?.parallelToolCalls }, set: { v in updateOpenAI { $0.parallelToolCalls = v } }))
            }
            row("Service tier", isSet: false, reset: {}) {
                SKSegmented(options: [(PsmithServiceTier?.none, "Inherit"), (.auto, "Auto"), (.standard, "Standard"), (.priority, "Priority")],
                            selection: Binding(get: { o?.serviceTier }, set: { v in updateOpenAI { $0.serviceTier = v } }))
            }
            row("Response format", isSet: o?.responseFormat != nil, reset: { updateOpenAI { $0.responseFormat = nil } }) {
                SKSegmented(options: [(FormatChoice.inherit, "Inherit"), (.text, "Text"), (.json, "JSON"), (.schema, "JSON schema")],
                            selection: Binding(get: { format }, set: { choice in
                                updateOpenAI {
                                    switch choice {
                                    case .inherit: $0.responseFormat = nil
                                    case .text: $0.responseFormat = .text
                                    case .json: $0.responseFormat = .jsonObject
                                    case .schema: $0.responseFormat = .jsonSchema(name: "answer", description: nil, schema: Data("{}".utf8), strict: true)
                                    }
                                }
                            }))
            }
            if case .jsonSchema(let name, let description, let schema, let strict) = o?.responseFormat {
                SKRow("Schema name") {
                    SKTextField(label: "Schema name", text: Binding(get: { name }, set: { v in updateOpenAI { $0.responseFormat = .jsonSchema(name: v, description: description, schema: schema, strict: strict) } }), width: 200, mono: true)
                }
                SKRow("Strict", detail: "Only output that matches the schema.") {
                    Toggle("Strict", isOn: Binding(get: { strict ?? false }, set: { v in updateOpenAI { $0.responseFormat = .jsonSchema(name: name, description: description, schema: schema, strict: v) } })).skSwitch()
                }
                SKRawRow {
                    VStack(alignment: .leading, spacing: 7) {
                        SKLabel(title: "Schema", detail: "JSON Schema the reply must match.")
                        SKJSONArea(data: Binding(get: { schema }, set: { v in updateOpenAI { $0.responseFormat = .jsonSchema(name: name, description: description, schema: v, strict: strict) } }), lines: 3)
                    }
                }
            }
            SKRawRow {
                VStack(alignment: .leading, spacing: 7) {
                    SKLabel(title: "Logit bias", detail: "Token id to bias, −100 to 100.")
                    SKJSONArea(data: Binding(
                        get: { o.map { Self.encodeBias($0.logitBias) } ?? Data() },
                        set: { v in updateOpenAI { $0.logitBias = Self.decodeBias(v) ?? $0.logitBias } }
                    ), lines: 2)
                }
            }
        } trailing: {
            driverTabs ? AnyView(driverSwitch) : AnyView(SKChip.synced)
        } footer: {
            if driverTabs { Text(driverFooter) }
        }
    }

    static func encodeBias(_ bias: [Int32: Double]) -> Data {
        guard !bias.isEmpty else { return Data() }
        let dict = Dictionary(uniqueKeysWithValues: bias.map { ("\($0.key)", $0.value) })
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    static func decodeBias(_ data: Data) -> [Int32: Double]? {
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [Int32: Double] = [:]
        for (k, v) in obj {
            guard let id = Int32(k), let n = (v as? NSNumber)?.doubleValue else { return nil }
            out[id] = n
        }
        return out
    }

    private static let thresholds: [(PsmithHarmThreshold?, String)] = [(nil, "Inherit"), (.blockNone, "None"), (.blockLowAndAbove, "Low+"), (.blockMediumAndAbove, "Medium+"), (.blockOnlyHigh, "High")]

    private func safetyRow(_ title: String, _ key: WritableKeyPath<PsmithSafetySettings, PsmithHarmThreshold?>) -> some View {
        let current = settings.google?.safetySettings?[keyPath: key]
        return row(title, isSet: current != nil, reset: { setSafety(key, nil) }) {
            SKSegmented(options: Self.thresholds, selection: Binding(get: { current }, set: { setSafety(key, $0) }))
        }
    }

    private func setSafety(_ key: WritableKeyPath<PsmithSafetySettings, PsmithHarmThreshold?>, _ v: PsmithHarmThreshold?) {
        updateGoogle {
            var s = $0.safetySettings ?? PsmithSafetySettings()
            s[keyPath: key] = v
            $0.safetySettings = s.isEmpty ? nil : s
        }
    }

    private var google: some View {
        let g = settings.google
        return SKGroup(driverTabs ? "Provider settings" : "Google") {
            safetyRow("Harassment", \.harassment)
            safetyRow("Hate speech", \.hateSpeech)
            safetyRow("Sexually explicit", \.sexuallyExplicit)
            safetyRow("Dangerous content", \.dangerousContent)
            SKRow("Response type") {
                SKTextField(label: "Response type", text: Binding(get: { g?.responseMimeType ?? "" },
                                                                 set: { v in updateGoogle { $0.responseMimeType = v.isEmpty ? nil : v } }),
                            placeholder: "text/plain", width: 200, mono: true)
            }
            row("Candidates", detail: "1 to 8.", isSet: g?.candidateCount != nil, reset: { updateGoogle { $0.candidateCount = nil } }) {
                SKOptionalStepper(value: Binding(get: { g?.candidateCount }, set: { v in updateGoogle { $0.candidateCount = v } }), range: 1...8, step: 1)
            }
        } trailing: {
            driverTabs ? AnyView(driverSwitch) : AnyView(SKChip.synced)
        } footer: {
            Text(driverTabs ? driverFooter : "Thresholds block replies that score at or above them.")
        }
    }
}

/// A number that may be unset: empty field means inherit.
struct SKOptionalStepper: View {
    @Binding var value: Int32?
    let range: ClosedRange<Int32>
    var step: Int32 = 1
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            SKTextField(label: "Value", text: $text, width: 80, mono: true)
                .onSubmit(commit)
                .onAppear { text = value.map { $0.formatted() } ?? "" }
                .onChange(of: value) { _, v in text = v.map { $0.formatted() } ?? "" }
            VStack(spacing: 0) {
                Button { value = min((value ?? range.lowerBound - step) + step, range.upperBound) } label: {
                    SKChevron(up: true).stroke(SK.secondary, style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)).frame(width: 9, height: 9).frame(width: 15, height: 11)
                }
                .accessibilityLabel("Increase")
                Button { value = max((value ?? range.lowerBound + step) - step, range.lowerBound) } label: {
                    SKChevron(up: false).stroke(SK.secondary, style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)).frame(width: 9, height: 9).frame(width: 15, height: 11)
                }
                .accessibilityLabel("Decrease")
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 5).fill(SK.control))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SK.controlRing, lineWidth: 0.5))
        }
    }

    private func commit() {
        let digits = text.filter { $0.isNumber || $0 == "-" }
        if digits.isEmpty { value = nil; return }
        if let v = Int32(digits) { value = min(max(v, range.lowerBound), range.upperBound) }
        text = value.map { $0.formatted() } ?? ""
    }
}

/// JSON edited as text; it keeps the last value that parsed and says when
/// the text doesn't.
struct SKJSONArea: View {
    @Binding var data: Data
    var lines = 3
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SKTextArea(text: $text, lines: lines, mono: true)
                .onAppear { text = String(data: data, encoding: .utf8) ?? "" }
                .onChange(of: text) { _, t in
                    let d = Data(t.utf8)
                    if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        invalid = false
                        data = Data()
                    } else if (try? JSONSerialization.jsonObject(with: d)) != nil {
                        invalid = false
                        data = d
                    } else {
                        invalid = true
                    }
                }
            if invalid { Text("Doesn't parse as JSON.").sk(11.5, SK.red) }
        }
    }
}
