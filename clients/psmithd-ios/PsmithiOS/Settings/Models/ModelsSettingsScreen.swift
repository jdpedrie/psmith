import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Models (board SettingsModelsList): the configured providers,
/// each with its connection dot and how many models it has on, and the way
/// in to adding another.
struct ModelsSettingsScreen: View {
    @Environment(AppModel.self) private var app
    /// Enabled-model counts per provider, read from each provider's detail.
    @State var counts: [String: Int]
    var autoload = true

    init(counts: [String: Int] = [:], autoload: Bool = true) {
        _counts = State(initialValue: counts)
        self.autoload = autoload
    }

    var body: some View {
        let providers = app.providers
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let err = providers.error {
                    IKBanner(systemImage: "exclamationmark.triangle", text: err) { providers.error = nil }
                        .padding(.bottom, 10)
                }
                IKPageHead(text: "Providers", topPadding: 2)
                IKGroup {
                    if providers.providers.isEmpty {
                        IKRow("No providers yet", detail: "Add one below to start a conversation.")
                    }
                    ForEach(providers.providers) { p in
                        NavigationLink { ModelsProviderScreen(provider: p) } label: { providerRow(p) }
                            .buttonStyle(.plain)
                    }
                }
                IKPageNote("The dot shows the last connection test run from this iPhone.", settings: true)

                IKGroup {
                    NavigationLink { ModelsAddProviderScreen() } label: { IKAddRow(title: "Add Provider") }
                        .buttonStyle(.plain)
                }
                .padding(.top, 18)
                IKPageNote("Anthropic, Google, or any OpenAI-compatible API, hosted or on your own network.", settings: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage("Models")
        .refreshable { await reload() }
        .task {
            guard autoload else { return }
            if providers.providers.isEmpty { await providers.load() }
            if !providers.templatesLoaded { await providers.loadTemplates() }
            await loadCounts()
        }
    }

    private func reload() async {
        await app.providers.load()
        await loadCounts()
    }

    private func loadCounts() async {
        for p in app.providers.providers {
            if let (_, models) = try? await app.client.modelProviders.get(id: p.id) { counts[p.id] = models.count }
        }
    }

    private func providerRow(_ p: PsmithUserModelProvider) -> some View {
        let status = ModelsProviderStatus(p, app.providers.providerTestStatus[p.id])
        return HStack(spacing: 12) {
            IKLetterTile(letter: String(p.label.prefix(1)).uppercased())
            VStack(alignment: .leading, spacing: 0) {
                Text(p.label).font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text([status.text, counts[p.id].map { "\($0) model\($0 == 1 ? "" : "s") on" }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                .font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IKChevron()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7.5)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A provider's connection state as its row and header read it.
struct ModelsProviderStatus {
    let text: String
    let color: Color

    init(_ p: PsmithUserModelProvider, _ test: ProviderTestStatus?) {
        switch test {
        case .success(let r) where r.ok: (text, color) = ("Key saved", IK.green)
        case .success, .failure: (text, color) = ("Last test failed", IK.orange)
        case .testing: (text, color) = ("Testing…", IK.tertiary)
        case .idle, .none: (text, color) = ("Key saved", IK.tertiary)
        }
    }
}

/// An accent "+ Title" row that opens a page.
struct IKAddRow: View {
    let title: String
    var chevron = true
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
            Text(title).font(.system(size: 16)).frame(maxWidth: .infinity, alignment: .leading)
            if chevron { IKChevron() }
        }
        .foregroundStyle(theme.accentInk)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Add provider

/// The providers that can still be added (board SettingsAddProvider):
/// native drivers, the OpenAI-compatible presets, and a custom endpoint.
struct ModelsAddProviderScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let available = app.providers.unconfiguredTemplates
        let native = available.filter { $0.driverType != "openai-compatible" }
        let compatible = available.filter { $0.driverType == "openai-compatible" }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !native.isEmpty {
                    IKPageHead(text: "Native", topPadding: 2)
                    IKGroup { ForEach(native) { templateRow($0) } }
                }
                if !compatible.isEmpty {
                    IKPageHead(text: "OpenAI-compatible", topPadding: native.isEmpty ? 2 : 18)
                    IKGroup { ForEach(compatible) { templateRow($0) } }
                }
                IKPageNote("Providers you’ve already added aren’t listed.", settings: true)

                IKPageHead(text: "Custom")
                IKGroup {
                    NavigationLink { ModelsProviderKeyScreen(mode: .add(nil)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(IK.strong)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 9).fill(IK.wash(0.08)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Custom provider").font(.system(size: 16)).foregroundStyle(IK.text)
                                Text("Any Anthropic or OpenAI-compatible endpoint").font(.system(size: 12.5))
                                    .foregroundStyle(IK.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            IKChevron()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7.5).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage("Add Provider")
        .task { if !app.providers.templatesLoaded { await app.providers.loadTemplates() } }
    }

    private func templateRow(_ t: PsmithProviderTemplate) -> some View {
        NavigationLink { ModelsProviderKeyScreen(mode: .add(t)) } label: {
            HStack(spacing: 12) {
                IKLetterTile(letter: String(t.name.prefix(1)).uppercased())
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.name).font(.system(size: 16)).foregroundStyle(IK.text)
                    if let base = t.apiBase {
                        Text(Self.bare(base)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(IK.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                IKChevron()
            }
            .padding(.horizontal, 14).padding(.vertical, 7.75).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func bare(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

// MARK: - Provider key (add or edit)

/// Credentials for a new provider, or a configured one's label, key and
/// base URL (board SettingsProviderKey). The key is write-only: editing
/// leaves the saved key alone unless a new one is typed.
struct ModelsProviderKeyScreen: View {
    enum Mode {
        case add(PsmithProviderTemplate?)
        case edit(PsmithUserModelProvider)
    }

    let mode: Mode
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var label = ""
    @State var apiKey = ""
    @State var baseURL = ""
    /// Custom endpoints pick their driver; presets come with one.
    @State var customDriver = "openai-compatible"
    @State private var seeded = false
    @State private var saving = false
    @State private var error: String?

    init(mode: Mode, label: String? = nil, apiKey: String = "", baseURL: String? = nil) {
        self.mode = mode
        switch mode {
        case .add(let t):
            _label = State(initialValue: label ?? t?.name ?? "")
            _baseURL = State(initialValue: baseURL ?? t?.apiBase ?? "")
        case .edit(let p):
            _label = State(initialValue: label ?? p.label)
            _baseURL = State(initialValue: baseURL ?? p.baseURL ?? "")
        }
        _apiKey = State(initialValue: apiKey)
    }

    private var template: PsmithProviderTemplate? { if case .add(let t) = mode { return t } else { return nil } }
    private var editing: PsmithUserModelProvider? { if case .edit(let p) = mode { return p } else { return nil } }

    private var driver: String {
        editing?.type ?? template?.driverType ?? customDriver
    }

    private var needsBaseURL: Bool { driver == "openai-compatible" }

    private var name: String { editing?.label ?? template?.name ?? "Custom provider" }

    private var canSave: Bool {
        let l = label.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { return false }
        if editing == nil && apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if needsBaseURL && baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private var changed: Bool {
        guard let p = editing else { return true }
        return label != p.label || !apiKey.isEmpty || (needsBaseURL && baseURL != (p.baseURL ?? ""))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    IKLetterTile(letter: template == nil && editing == nil ? "+" : String(name.prefix(1)).uppercased(), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                        Text(driver).font(.system(size: 12.5)).foregroundStyle(IK.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
                .padding(.top, 2)

                if template == nil && editing == nil {
                    IKPageHead(text: "Driver")
                    IKSegmented(options: [("openai-compatible", "OpenAI-compatible"), ("anthropic", "Anthropic")],
                                selection: $customDriver)
                }

                IKPageHead(text: "Credentials")
                VStack(alignment: .leading, spacing: 0) {
                    fieldLabel("Label")
                    IKFieldWell {
                        TextField("Display name", text: $label).font(.system(size: 16)).foregroundStyle(IK.text)
                            .textInputAutocapitalization(.words)
                    }
                    .padding(.top, 6)
                    fieldLabel("API key").padding(.top, 14)
                    IKFieldWell {
                        SecureField(editing == nil ? "Paste key here" : "Leave blank to keep the saved key", text: $apiKey)
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(IK.text)
                            .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.top, 6)
                    if let env = template?.envKey { hint("env: \(env)") }
                    if needsBaseURL {
                        fieldLabel("Base URL").padding(.top, 14)
                        IKFieldWell {
                            TextField("https://api.example.com/v1", text: $baseURL)
                                .font(.system(size: 14, design: .monospaced)).foregroundStyle(IK.text)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        .padding(.top, 6)
                        hint("Required for OpenAI-compatible providers. Change it only for a proxy or gateway.")
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
                IKPageNote(editing == nil
                           ? "The key is encrypted on the server and never shown again. After adding, pick which models to turn on."
                           : "The key is encrypted on the server and never shown. Type a new one only to replace it.",
                           settings: true)

                if let p = editing { testSection(p) }

                if let error {
                    IKBanner(systemImage: "exclamationmark.triangle", text: error, color: IK.red).padding(.top, 14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage(editing == nil ? "Add \(template?.name ?? "Provider")" : "Edit \(name)")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if changed {
                IKActionBar(summary: summary, secondary: "Cancel", primary: editing == nil ? "Add Provider" : "Save",
                            canSave: canSave && !saving, onSecondary: { dismiss() }, onPrimary: { Task { await save() } })
            }
        }
    }

    private var summary: String {
        let l = label.trimmingCharacters(in: .whitespaces)
        if editing != nil { return apiKey.isEmpty ? "Unsaved changes" : "New key pasted" }
        if apiKey.isEmpty { return "Paste a key to continue" }
        return "\(l.isEmpty ? "Provider" : l), key pasted"
    }

    @ViewBuilder
    private func testSection(_ p: PsmithUserModelProvider) -> some View {
        let status = app.providers.providerTestStatus[p.id]
        IKGroup {
            Button { Task { await app.providers.testProvider(p.id) } } label: {
                HStack(spacing: 12) {
                    Text("Test Connection").font(.system(size: 16)).foregroundStyle(IK.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if case .testing = status { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let line = testLine(status) {
                Text(line.0).font(.system(size: 13)).foregroundStyle(line.1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .padding(.top, 18)
    }

    private func testLine(_ s: ProviderTestStatus?) -> (String, Color)? {
        switch s {
        case .success(let r) where r.ok: ("Connected. Found \(r.modelCount) models in \(r.latencyMs) ms.", IK.green)
        case .success(let r): ("Failed: \(r.errorMessage)", IK.red)
        case .failure(let m): ("Failed: \(m)", IK.red)
        default: nil
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(IK.tertiary).padding(.top, 5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() async {
        guard canSave, !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        do {
            if let p = editing {
                var config: Data?
                if !apiKey.isEmpty || (needsBaseURL && baseURL != (p.baseURL ?? "")) {
                    var dict: [String: String] = [:]
                    if !apiKey.isEmpty { dict["api_key"] = apiKey }
                    if needsBaseURL { dict["base_url"] = baseURL }
                    if let preset = p.presetID, !preset.isEmpty { dict["preset_id"] = preset }
                    config = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
                }
                try await app.providers.updateProviderPartial(id: p.id, label: trimmed != p.label ? trimmed : nil,
                                                              config: config)
            } else {
                var dict = ["api_key": apiKey]
                if needsBaseURL { dict["base_url"] = baseURL }
                if let preset = template?.presetID { dict["preset_id"] = preset }
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
                _ = try await app.providers.createProvider(type: driver, label: trimmed, config: data)
            }
            await app.providers.load()
            dismiss()
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}
