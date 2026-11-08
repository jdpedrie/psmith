import SwiftUI
import PsmithKit
import PsmithUI

/// One model's own description (board SettingsModelDetail), or a new one
/// added by hand. The form is the truth: saving writes back every field as
/// shown, and a blank number clears its column. Edits stage until the
/// save bar commits them.
struct ModelDetailScreen: View {
    enum Mode { case add, edit(PsmithUserModel) }

    let provider: PsmithUserModelProvider
    let mode: Mode
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State var form: ModelForm
    @State private var baseline: ModelForm
    @State var confirmingDelete: Bool
    @State private var saving = false
    @State private var refreshing = false
    @State private var note: String?
    @State private var error: String?

    init(provider: PsmithUserModelProvider, mode: Mode, confirmingDelete: Bool = false) {
        self.provider = provider
        self.mode = mode
        let f: ModelForm
        if case .edit(let m) = mode { f = ModelForm(m) } else { f = ModelForm() }
        _form = State(initialValue: f)
        _baseline = State(initialValue: f)
        _confirmingDelete = State(initialValue: confirmingDelete)
    }

    private var existing: PsmithUserModel? { if case .edit(let m) = mode { return m } else { return nil } }
    private var isManual: Bool { existing?.metadataSource == "manual" }
    private var pending: Int { form.changes(from: baseline) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identity.padding(.top, 2)

                if let m = existing {
                    IKGroup {
                        IKRow(title: "Enabled") {
                            Toggle("Enabled", isOn: Binding(get: { true }, set: { if !$0 { disable(m) } }))
                                .labelsHidden().tint(theme.accent)
                                .padding(.vertical, 9.5)
                        }
                        callSettingsLink
                    }
                    .padding(.top, 14)
                } else {
                    IKGroup { callSettingsLink }.padding(.top, 14)
                }

                if !form.invalid.isEmpty {
                    IKBanner(systemImage: "exclamationmark.triangle",
                             text: "Not a number: \(form.invalid.joined(separator: ", ")). Fix or clear it to save.")
                        .padding(.top, 14)
                }

                HStack {
                    Text("Limits and prices").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("USD per 1M tokens").font(.system(size: 13))
                }
                .foregroundStyle(IK.tertiary)
                .padding(EdgeInsets(top: 18, leading: 4, bottom: 6, trailing: 4))
                IKGroup {
                    numberRow("Context window", $form.contextWindow, placeholder: "tokens")
                    numberRow("Max output", $form.maxOutput, placeholder: "tokens")
                    pairRow("Input / output", $form.inputPrice, $form.outputPrice)
                    pairRow("Cache read / write", $form.cacheReadPrice, $form.cacheWritePrice)
                }

                IKPageHead(text: "Capabilities")
                chips(ModelForm.capabilityNames, isOn: { form.capabilities.contains($0) }) { form.toggleCapability($0) }
                IKPageNote("Profiles that need a capability hide models without it.", settings: true)

                IKPageHead(text: "Inputs")
                chips(ModelForm.modalityNames, isOn: { form.modalities.contains($0) }) { form.toggleModality($0) }

                IKPageHead(text: "Knowledge cutoff")
                IKGroup {
                    IKRow(title: "Set a cutoff") {
                        Toggle("Set a cutoff", isOn: $form.cutoffOn).labelsHidden().tint(theme.accent)
                            .padding(.vertical, 9.5)
                    }
                    if form.cutoffOn {
                        DatePicker("Cutoff", selection: $form.cutoff, displayedComponents: .date)
                            .font(.system(size: 16)).foregroundStyle(IK.text)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                    }
                }

                if let m = existing { tools(m) }

                if let note { IKPageNote(note, settings: true).padding(.top, 8) }
                if let error {
                    IKBanner(systemImage: "exclamationmark.triangle", text: error, color: IK.red).padding(.top, 14)
                }

                if let m = existing, isManual {
                    Group {
                        if confirmingDelete {
                            IKConfirmCard(question: "Delete \(m.displayName)?",
                                          detail: "You added it by hand, so Find New Models won’t bring it back. Conversations using it can’t send until they switch.",
                                          onCancel: { withAnimation(.snappy) { confirmingDelete = false } },
                                          onConfirm: { disable(m) })
                        } else {
                            IKGroup {
                                Button { withAnimation(.snappy) { confirmingDelete = true } } label: {
                                    IKRow("Delete Model", titleColor: IK.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage(existing == nil ? "Add Custom Model" : "Model")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if existing == nil || pending > 0 {
                IKSaveBar(summary: existing == nil ? (form.modelID.isEmpty ? "Enter a model ID" : form.modelID)
                                                   : IKCallSettingsDiff.summary(pending),
                          saveLabel: existing == nil ? "Add Model" : "Save",
                          revertLabel: existing == nil ? "Cancel" : "Revert",
                          canSave: form.canSave && !saving,
                          onRevert: { if existing == nil { dismiss() } else { form = baseline } },
                          onSave: { Task { await save() } })
            }
        }
    }

    // MARK: Sections

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            if existing == nil {
                label("Model ID")
                IKFieldWell {
                    TextField("claude-sonnet-5", text: $form.modelID)
                        .font(.system(size: 14, design: .monospaced)).foregroundStyle(IK.text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(.top, 6)
                label("Display name").padding(.top, 14)
            } else {
                label("Display name")
            }
            IKFieldWell {
                TextField(form.modelID.isEmpty ? "Optional" : form.modelID, text: $form.displayName)
                    .font(.system(size: 16)).foregroundStyle(IK.text)
            }
            .padding(.top, 6)
            if let m = existing {
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 12, weight: .medium)).foregroundStyle(IK.tertiary)
                    Text(m.modelID).font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    IKTag(text: isManual ? "Added by hand" : "From the catalog")
                }
                .padding(.top, 13)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
    }

    private var callSettingsLink: some View {
        NavigationLink {
            ModelDefaultsScreen(provider: provider, settings: $form.defaults, displayName: form.shownName,
                                capabilities: form.capabilityValue, constraints: existing?.constraints)
        } label: {
            let n = IKCallSettingsDiff.setCount(form.defaults)
            IKRow("Call settings", value: n == 0 ? "None" : (n == 1 ? "1 override" : "\(n) overrides"), chevron: true)
        }
        .buttonStyle(.plain)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
    }

    private func numberRow(_ title: String, _ text: Binding<String>, placeholder: String) -> some View {
        IKRow(title: title) {
            TextField(placeholder, text: text)
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.secondary)
                .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                .frame(maxWidth: 140)
        }
    }

    private func pairRow(_ title: String, _ a: Binding<String>, _ b: Binding<String>) -> some View {
        IKRow(title: title) {
            HStack(spacing: 2) {
                priceField(a)
                Text(" / ").font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.secondary)
                priceField(b)
            }
        }
    }

    private func priceField(_ text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Text("$").font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.secondary)
            TextField("–", text: text)
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.secondary)
                .keyboardType(.decimalPad).fixedSize()
        }
    }

    private func chips(_ items: [(String, String)], isOn: @escaping (String) -> Bool, toggle: @escaping (String) -> Void) -> some View {
        IKFlow(spacing: 6) {
            ForEach(items, id: \.0) { key, title in
                let on = isOn(key)
                Button { toggle(key) } label: {
                    Text(title).font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? theme.accentInk : IK.secondary)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(on ? theme.selection : IK.wash(0.07)))
                        .overlay(Capsule().strokeBorder(on ? theme.accent : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
    }

    @ViewBuilder
    private func tools(_ m: PsmithUserModel) -> some View {
        IKPageHead(text: "Checks")
        IKGroup {
            CapabilityProbeView(
                status: app.providers.capabilityProbeStatus[ModelTestKey(providerID: provider.id, modelID: m.modelID)] ?? .idle
            ) { apply in
                Task {
                    await app.providers.probeModelCapabilities(providerID: provider.id, modelID: m.modelID, apply: apply)
                    if apply, let caps = app.providers.enabledModels.first(where: { $0.modelID == m.modelID })?.capabilities {
                        form.capabilities = ModelForm.capabilitySet(caps)
                        baseline.capabilities = form.capabilities
                    }
                }
            }
            .padding(14)
            if m.metadataSource == "catalog" {
                Button { Task { await refresh(m) } } label: {
                    HStack {
                        Text("Refresh from the Catalog").font(.system(size: 16)).foregroundStyle(theme.accentInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if refreshing { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(refreshing || saving)
            }
        }
        IKPageNote("A probe can switch a capability on, never off. Refreshing replaces hand edits with the catalog’s values and keeps call settings and the favorite.", settings: true)
    }

    // MARK: Actions

    private func disable(_ m: PsmithUserModel) {
        app.providers.selectedID = provider.id
        Task { await app.providers.disableModel(m.modelID) }
        dismiss()
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            if existing != nil {
                _ = try await app.providers.updateModelFull(
                    providerID: provider.id, modelID: form.modelID, displayName: form.shownName,
                    contextWindow: form.int(form.contextWindow), clearContextWindow: form.int(form.contextWindow) == nil,
                    maxOutputTokens: form.int(form.maxOutput), clearMaxOutputTokens: form.int(form.maxOutput) == nil,
                    pricing: form.pricing ?? PsmithModelPricing(inputPerMillion: nil, outputPerMillion: nil,
                                                                cacheReadPerMillion: nil, cacheWritePerMillion: nil,
                                                                tiers: form.tiers),
                    modalities: form.modalityList, capabilities: form.capabilityValue,
                    knowledgeCutoff: form.cutoffString, clearKnowledgeCutoff: !form.cutoffOn,
                    defaultSettings: form.defaults)
                baseline = form
            } else {
                _ = try await app.providers.addManualModel(
                    providerID: provider.id, modelID: form.modelID.trimmingCharacters(in: .whitespaces),
                    displayName: form.shownName, contextWindow: form.int(form.contextWindow),
                    maxOutputTokens: form.int(form.maxOutput), pricing: form.pricing, modalities: form.modalityList,
                    capabilities: form.capabilityValue, knowledgeCutoff: form.cutoffString,
                    defaultSettings: form.defaults.isEmpty ? nil : form.defaults)
                dismiss()
            }
            await app.providers.selectProvider(provider.id)
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    private func refresh(_ m: PsmithUserModel) async {
        refreshing = true
        defer { refreshing = false }
        do {
            let (model, refreshed) = try await app.providers.refreshModelMetadata(providerID: provider.id, modelID: m.modelID)
            if refreshed {
                var f = ModelForm(model)
                f.defaults = form.defaults
                form = f
                baseline = f
                note = "Refreshed from the catalog."
                await app.providers.selectProvider(provider.id)
            } else {
                note = "The catalog has no entry for this model. Nothing changed."
            }
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}

/// The model form's editable state: text for numbers so a half-typed value
/// survives, and sets for the chips.
struct ModelForm: Equatable {
    var modelID = ""
    var displayName = ""
    var contextWindow = ""
    var maxOutput = ""
    var inputPrice = ""
    var outputPrice = ""
    var cacheReadPrice = ""
    var cacheWritePrice = ""
    var capabilities: Set<String> = ["streaming"]
    var modalities: Set<String> = ["text"]
    var cutoffOn = false
    var cutoff = Date()
    var defaults = PsmithCallSettings()
    /// Carried through untouched: the form has no tier editor, and the server
    /// replaces pricing as a block.
    var tiers: [PsmithPricingTier] = []

    static let capabilityNames = [("streaming", "Streaming"), ("thinking", "Thinking"), ("toolUse", "Tool use"),
                                  ("vision", "Vision"), ("promptCaching", "Prompt caching"),
                                  ("generatesImages", "Makes images")]
    static let modalityNames = [("text", "Text"), ("image", "Image"), ("audio", "Audio"), ("pdf", "PDF"), ("video", "Video")]

    init() {}

    init(_ m: PsmithUserModel) {
        modelID = m.modelID
        displayName = m.displayName
        contextWindow = m.contextWindow.map { $0.formatted() } ?? ""
        maxOutput = m.maxOutputTokens.map { $0.formatted() } ?? ""
        inputPrice = Self.price(m.pricing?.inputPerMillion)
        outputPrice = Self.price(m.pricing?.outputPerMillion)
        cacheReadPrice = Self.price(m.pricing?.cacheReadPerMillion)
        cacheWritePrice = Self.price(m.pricing?.cacheWritePerMillion)
        capabilities = m.capabilities.map(Self.capabilitySet) ?? []
        modalities = Set(m.modalities)
        if let c = m.knowledgeCutoff.flatMap(Self.parseCutoff) { cutoffOn = true; cutoff = c }
        defaults = m.defaultSettings ?? PsmithCallSettings()
        tiers = m.pricing?.tiers ?? []
    }

    static func capabilitySet(_ c: PsmithModelCapabilities) -> Set<String> {
        var s: Set<String> = []
        if c.streaming { s.insert("streaming") }
        if c.thinking { s.insert("thinking") }
        if c.toolUse { s.insert("toolUse") }
        if c.vision { s.insert("vision") }
        if c.promptCaching { s.insert("promptCaching") }
        if c.generatesImages { s.insert("generatesImages") }
        return s
    }

    var capabilityValue: PsmithModelCapabilities {
        PsmithModelCapabilities(streaming: capabilities.contains("streaming"), thinking: capabilities.contains("thinking"),
                                toolUse: capabilities.contains("toolUse"), vision: capabilities.contains("vision"),
                                promptCaching: capabilities.contains("promptCaching"),
                                generatesImages: capabilities.contains("generatesImages"))
    }

    mutating func toggleCapability(_ k: String) { if capabilities.contains(k) { capabilities.remove(k) } else { capabilities.insert(k) } }
    mutating func toggleModality(_ k: String) { if modalities.contains(k) { modalities.remove(k) } else { modalities.insert(k) } }

    var modalityList: [String] { Self.modalityNames.map(\.0).filter { modalities.contains($0) } }

    var shownName: String {
        let n = displayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? modelID.trimmingCharacters(in: .whitespaces) : n
    }

    /// Fields holding text that isn't a number. On an edit a blank field
    /// clears its column, so reading "128k" as blank would wipe it.
    var invalid: [String] {
        var out: [String] = []
        if !blank(contextWindow) && int(contextWindow) == nil { out.append("Context window") }
        if !blank(maxOutput) && int(maxOutput) == nil { out.append("Max output") }
        for (t, v) in [("Input price", inputPrice), ("Output price", outputPrice), ("Cache read price", cacheReadPrice),
                       ("Cache write price", cacheWritePrice)] where !blank(v) && double(v) == nil { out.append(t) }
        return out
    }

    var canSave: Bool { !blank(modelID) && invalid.isEmpty }

    func changes(from b: ModelForm) -> Int {
        var n = 0
        let pairs: [(AnyHashable, AnyHashable)] = [
            (displayName, b.displayName), (contextWindow, b.contextWindow), (maxOutput, b.maxOutput),
            (inputPrice, b.inputPrice), (outputPrice, b.outputPrice), (cacheReadPrice, b.cacheReadPrice),
            (cacheWritePrice, b.cacheWritePrice), (capabilities, b.capabilities), (modalities, b.modalities),
            (cutoffOn, b.cutoffOn), (cutoffOn ? cutoffString : nil, b.cutoffOn ? b.cutoffString : nil),
        ]
        for (x, y) in pairs where x != y { n += 1 }
        return n + IKCallSettingsDiff.count(defaults, b.defaults)
    }

    var pricing: PsmithModelPricing? {
        let i = double(inputPrice), o = double(outputPrice), r = double(cacheReadPrice), w = double(cacheWritePrice)
        if i == nil && o == nil && r == nil && w == nil && tiers.isEmpty { return nil }
        return PsmithModelPricing(inputPerMillion: i, outputPerMillion: o, cacheReadPerMillion: r,
                                  cacheWritePerMillion: w, tiers: tiers)
    }

    var cutoffString: String? { cutoffOn ? Self.cutoffFormatter.string(from: cutoff) : nil }

    /// Accepts the grouping the form shows ("200,000").
    func int(_ s: String) -> Int32? {
        var t = s.trimmingCharacters(in: .whitespaces)
        for sep in [",", " ", "\u{00A0}", "\u{202F}", Locale.current.groupingSeparator ?? ","] {
            t = t.replacingOccurrences(of: sep, with: "")
        }
        return t.isEmpty ? nil : Int32(t)
    }

    /// Accepts the device's decimal separator: the decimal pad types "," in
    /// comma-decimal locales.
    func double(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let v = Double(t) { return v }
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        return f.number(from: t)?.doubleValue
    }

    private func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

    static func price(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    // The cutoff is a calendar day, shown in the device's zone, so it's
    // parsed and written in that zone too.
    static var cutoffFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }

    static func parseCutoff(_ s: String) -> Date? { cutoffFormatter.date(from: s) }

    static func == (a: ModelForm, b: ModelForm) -> Bool { a.changes(from: b) == 0 && a.modelID == b.modelID }
}

/// A model's default call settings, edited in place on the model's form and
/// saved with it.
struct ModelDefaultsScreen: View {
    let provider: PsmithUserModelProvider
    @Binding var settings: PsmithCallSettings
    let displayName: String
    let capabilities: PsmithModelCapabilities?
    let constraints: PsmithModelConstraints?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IKPageNote("\(displayName) starts from \(provider.label)’s defaults. Set a field here to change it for this model only. Profiles and conversations can still override it. Save on the model page.",
                           settings: true, top: -2)
                IKCallSettingsForm(settings: $settings, inherited: provider.defaultSettings, driverType: provider.type,
                                   capabilities: capabilities, constraints: constraints, showAllProviderSections: false,
                                   style: .settings)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage("\(displayName) Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { settings = PsmithCallSettings() }
                    .foregroundStyle(IK.text)
                    .disabled(settings.isEmpty)
            }
        }
    }
}
