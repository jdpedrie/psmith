import SwiftUI
import PsmithKit
import PsmithUI

/// The first-run gate (boards OnboardProvider, OnboardKey, OnboardModels):
/// shown while the account has no provider with an enabled model. Three
/// steps in place: pick a provider template, give it a key, turn on the
/// models discovery found. The gate lifts on its own once the providers
/// model reports an enabled model, from here or from another device.
struct OnboardingScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    enum Step: Int { case provider, key, models }

    @State private var step: Step
    @State private var template: PsmithProviderTemplate?
    @State private var label: String
    @State private var apiKey: String
    @State private var baseURL: String
    @State private var createdProviderID: String?
    @State private var discovered: [PsmithDiscoveredModel]
    @State private var selected: Set<String>
    @State private var errorMessage: String?
    @State private var working = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case label, key, baseURL }

    /// The seeds let a snapshot open on any step; the app starts empty.
    init(step: Step = .provider, template: PsmithProviderTemplate? = nil, apiKey: String = "",
         createdProviderID: String? = nil, discovered: [PsmithDiscoveredModel] = [],
         selected: Set<String>? = nil, errorMessage: String? = nil) {
        _step = State(initialValue: step)
        _template = State(initialValue: template)
        _label = State(initialValue: template?.name ?? "")
        _apiKey = State(initialValue: apiKey)
        _baseURL = State(initialValue: template?.apiBase ?? "")
        _createdProviderID = State(initialValue: createdProviderID)
        _discovered = State(initialValue: discovered)
        _selected = State(initialValue: selected ?? Self.defaultSelection(discovered))
        _errorMessage = State(initialValue: errorMessage)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                OnboardingSteps(current: step).frame(maxWidth: .infinity).padding(.top, 19)
                Group {
                    switch step {
                    case .provider: VStack(alignment: .leading, spacing: 0) { providerStep }.padding(.top, 11)
                    case .key: VStack(alignment: .leading, spacing: 0) { keyStep }.padding(.top, 29)
                    case .models: VStack(alignment: .leading, spacing: 0) { modelsStep }.padding(.top, 11)
                    }
                }
                if let errorMessage {
                    IKStatusLine(systemImage: "xmark.circle", text: errorMessage, color: IK.red)
                        .padding(.horizontal, 4)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(IK.settingsGround.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if step != .provider { bar }
        }
        .task { await app.providers.loadTemplates() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Psmith")
                .font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(IK.text)
                .frame(height: 36)
            Text("Connect a provider and turn on a model, and you're ready to chat. Your keys stay on your server.")
                .font(.system(size: 15)).ikLineHeight(21, size: 15).foregroundStyle(IK.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    // MARK: Step 1

    @ViewBuilder
    private var providerStep: some View {
        IKSectionHead("Choose a provider")
        if app.providers.templates.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 32)
        } else {
            IKGroup(separatorInset: 52) {
                ForEach(app.providers.templates) { t in
                    Button { pick(t) } label: {
                        HStack(spacing: 12) {
                            ProviderTile(template: t, size: 28)
                            VStack(alignment: .leading, spacing: 0.5) {
                                Text(t.name).font(.system(size: 16)).foregroundStyle(IK.text)
                                Text(Self.driverName(t)).font(.system(size: 12.5)).foregroundStyle(IK.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            IKChevron()
                        }
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 14))
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pick(_ t: PsmithProviderTemplate) {
        template = t
        label = t.name
        apiKey = ""
        baseURL = t.apiBase ?? ""
        errorMessage = nil
        step = .key
    }

    static func driverName(_ t: PsmithProviderTemplate) -> String {
        t.driverType == "openai-compatible" ? "OpenAI-compatible" : "Native driver"
    }

    // MARK: Step 2

    private var needsBaseURL: Bool { template?.driverType == "openai-compatible" }

    @ViewBuilder
    private var keyStep: some View {
        if let t = template {
            IKCard {
                HStack(spacing: 12) {
                    ProviderTile(template: t, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                        Text(templateDetail(t)).font(.system(size: 12.5)).foregroundStyle(IK.secondary).lineLimit(1)
                    }
                }
            }
        }
        IKCard {
            VStack(alignment: .leading, spacing: 16) {
                IKField(label: "Label", hint: "Display name shown in pickers.", ring: focus == .label ? theme.accent : nil) {
                    TextField("e.g. Anthropic", text: $label).focused($focus, equals: .label)
                }
                IKField(label: "API key", ring: focus == .key ? theme.accent : nil) {
                    SecureField("sk-…", text: $apiKey)
                        .font(.system(size: 13.5, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .key)
                }
                if let env = template?.envKey {
                    (Text("Often set with the ") + Text(env).font(.system(size: 12.5, design: .monospaced)).foregroundColor(IK.strong)
                        + Text(" environment variable on the server instead."))
                        .font(.system(size: 13)).ikLineHeight(18, size: 13).foregroundStyle(IK.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -10)
                }
                if needsBaseURL {
                    IKField(label: "API base URL", hint: "Required for OpenAI-compatible providers.",
                            ring: focus == .baseURL ? theme.accent : nil) {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .baseURL)
                    }
                }
            }
        }
        .padding(.top, 14)
    }

    private func templateDetail(_ t: PsmithProviderTemplate) -> String {
        let host = t.apiBase.flatMap { URL(string: $0)?.host }
        return [Self.driverName(t), host].compactMap { $0 }.joined(separator: " · ")
    }

    private var credentialsValid: Bool {
        if label.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if needsBaseURL && baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func createProvider() async {
        guard let t = template, credentialsValid, !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }

        var config: [String: String] = ["api_key": apiKey]
        if t.driverType == "openai-compatible" { config["base_url"] = baseURL }
        if let preset = t.presetID { config["preset_id"] = preset }
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            errorMessage = "Couldn't encode the key."
            return
        }
        do {
            let p = try await app.providers.createProvider(
                type: t.driverType, label: label.trimmingCharacters(in: .whitespaces), config: data)
            createdProviderID = p.id
            await app.providers.load()
            // Discover before showing step 3 so the list arrives populated.
            do {
                discovered = try await app.providers.discoverModels(providerID: p.id)
                selected = Self.defaultSelection(discovered)
            } catch {
                // Recoverable: step 3 offers Retry discovery.
                errorMessage = "Provider added, but model discovery failed: \(PsmithError.display(error))"
            }
            step = .models
        } catch {
            errorMessage = "Couldn't add provider: \(PsmithError.display(error))"
        }
    }

    /// Every streaming model that isn't already on: excludes image and
    /// embedding-only models for the chat use case.
    static func defaultSelection(_ models: [PsmithDiscoveredModel]) -> Set<String> {
        Set(models.filter { !$0.alreadyEnabled && ($0.capabilities?.streaming ?? false) }.map(\.modelID))
    }

    // MARK: Step 3

    @ViewBuilder
    private var modelsStep: some View {
        IKSectionHead(text: "\(template?.name ?? "Provider") found \(discovered.count) \(discovered.count == 1 ? "model" : "models")") {
            if let id = createdProviderID {
                Button("Retry discovery") { Task { await retryDiscovery(id) } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accentInk)
                    .buttonStyle(.plain)
                    .disabled(working)
            }
        }
        if !discovered.isEmpty {
            IKGroup {
                ForEach(discovered) { m in modelRow(m) }
            }
        }
        IKFooter("You can enable more in Settings › Models.")
    }

    private func modelRow(_ m: PsmithDiscoveredModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(m.displayName).font(.system(size: 16)).foregroundStyle(IK.text)
                Text(m.alreadyEnabled ? "Already enabled" : Self.modelDetail(m))
                    .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(IK.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(m.displayName, isOn: Binding(
                get: { m.alreadyEnabled || selected.contains(m.modelID) },
                set: { on in
                    if on { selected.insert(m.modelID) } else { selected.remove(m.modelID) }
                }
            ))
            .labelsHidden()
            .tint(theme.accent)
            .disabled(m.alreadyEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7.5)
        .frame(minHeight: 44)
        .opacity(m.alreadyEnabled ? 0.6 : 1)
    }

    /// "200k · $15 / $75 · thinks": context, price per million in and
    /// out, and whether it reasons.
    static func modelDetail(_ m: PsmithDiscoveredModel) -> String {
        var parts: [String] = []
        if let w = m.contextWindow, w > 0 {
            parts.append(w >= 1_000_000 && w % 1_000_000 == 0 ? "\(w / 1_000_000)M" : "\(Int((Double(w) / 1000).rounded()))k")
        }
        if let p = m.pricing, let i = p.inputPerMillion, let o = p.outputPerMillion {
            parts.append("\(price(i)) / \(price(o))")
        }
        if m.capabilities?.thinking == true { parts.append("thinks") }
        return parts.isEmpty ? m.modelID : parts.joined(separator: " · ")
    }

    private static func price(_ v: Double) -> String {
        v == v.rounded() ? "$\(Int(v))" : String(format: "$%.2f", v)
    }

    private func retryDiscovery(_ providerID: String) async {
        working = true
        defer { working = false }
        do {
            discovered = try await app.providers.discoverModels(providerID: providerID)
            errorMessage = nil
        } catch {
            errorMessage = "Discovery failed: \(PsmithError.display(error))"
        }
    }

    private func enableSelected() async {
        guard let providerID = createdProviderID, !selected.isEmpty, !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            _ = try await app.providers.enableModels(providerID: providerID, modelIDs: Array(selected))
            // The gate above observes the providers model and swaps in the app.
            await app.providers.load()
        } catch {
            errorMessage = "Couldn't enable models: \(PsmithError.display(error))"
        }
    }

    // MARK: Bar

    private var newCount: Int { selected.count }

    private var bar: some View {
        Group {
            if step == .key {
                OnboardingBar(summary: "Step 2 of 3", next: "Add Provider", working: working,
                              canGo: credentialsValid,
                              back: { step = .provider; errorMessage = nil },
                              go: { Task { await createProvider() } })
            } else {
                OnboardingBar(summary: newCount == 1 ? "1 new model on" : "\(newCount) new models on",
                              next: "Finish Setup", working: working, canGo: newCount > 0,
                              back: { step = .key; errorMessage = nil },
                              go: { Task { await enableSelected() } })
            }
        }
        .padding(.bottom, 0)
    }
}

/// The step bar: where you are, Back, and the step's action, on a 60pt
/// glass capsule over the bottom safe area.
struct OnboardingBar: View {
    let summary: String
    let next: String
    let working: Bool
    let canGo: Bool
    let back: () -> Void
    let go: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(summary).font(.system(size: 14)).foregroundStyle(IK.strong).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: back) {
                Text("Back").font(.system(size: 15)).foregroundStyle(IK.text)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(IK.wash(0.09)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(working)
            Button(action: go) {
                ZStack {
                    Text(next).opacity(working ? 0 : 1)
                    if working { ProgressView().tint(.white) }
                }
            }
            .ikButton(.primary, height: 40)
            .fixedSize()
            .disabled(!canGo || working)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 60)
        .ikGlass(in: Capsule(), ground: .settings)
        .padding(.horizontal, 12)
    }
}

/// The three-step indicator: done steps fill with the accent, the current
/// one rings it.
struct OnboardingSteps: View {
    let current: OnboardingScreen.Step
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            step(.provider, "Provider")
            connector(done: current.rawValue > 0)
            step(.key, "Key")
            connector(done: current.rawValue > 1)
            step(.models, "Models")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current.rawValue + 1) of 3")
    }

    private func step(_ s: OnboardingScreen.Step, _ label: String) -> some View {
        let done = s.rawValue < current.rawValue
        let active = s == current
        return VStack(spacing: 6) {
            ZStack {
                if done {
                    Circle().fill(theme.accent)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else if active {
                    Circle().fill(theme.accent.opacity(0.2))
                    Circle().strokeBorder(theme.accent, lineWidth: 1.5)
                    Text("\(s.rawValue + 1)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.accentInk)
                } else {
                    Circle().fill(IK.secondary.opacity(0.15))
                    Text("\(s.rawValue + 1)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(IK.secondary)
                }
            }
            .frame(width: 24, height: 24)
            Text(label).font(.system(size: 12.5)).foregroundStyle(active ? IK.text : IK.secondary)
        }
        .frame(width: 84)
    }

    private func connector(done: Bool) -> some View {
        Rectangle().fill(done ? theme.accent : IK.secondary.opacity(0.3))
            .frame(width: 28, height: 1)
            .padding(.top, 12)
    }
}

/// A provider's mark on a rounded tile.
struct ProviderTile: View {
    let template: PsmithProviderTemplate
    let size: CGFloat

    var body: some View {
        ProviderLogo(slug: template.logoSlug, size: size * 0.6)
            .foregroundStyle(IK.strong)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size > 30 ? 12 : 8).fill(IK.wash(0.08)))
    }
}
