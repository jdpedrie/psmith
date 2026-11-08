import SwiftUI
import PsmithKit
import PsmithUI

/// First run, before any model exists (boards AppOnboardingProvider,
/// AppOnboarding, AppOnboardingModels): pick a provider, give it a key,
/// enable models. The gate lifts on its own once a provider and a model
/// exist, including when they're added from Settings.
struct MacOnboarding: View {
    @Environment(AppModel.self) private var app
    @State private var step: Step = .pickProvider
    @State private var selectedTemplate: PsmithProviderTemplate?
    @State private var label = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var createdProviderID: String?
    @State private var discovered: [PsmithDiscoveredModel] = []
    @State private var selectedModelIDs: Set<String> = []

    enum Step: Int { case pickProvider, enterCredentials, enableModels }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome to Psmith").sk(22, weight: .bold)
                Text("Add a model provider to start. You can add more in Settings later.")
                    .sk(12.5, SK.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 18)
                steps.padding(.bottom, 18)
                switch step {
                case .pickProvider: pickProvider
                case .enterCredentials: credentials
                case .enableModels: models
                }
                if let errorMessage {
                    Text(errorMessage).sk(12, SK.red).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }
            }
            .frame(width: 560)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { h, _ in h }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectHidden(true, for: .top)
        .ignoresSafeArea()
        .task { await app.providers.loadTemplates() }
    }

    private var steps: some View {
        HStack(spacing: 18) {
            stepDot(0, "Provider")
            stepDot(1, "Key")
            stepDot(2, "Models")
        }
    }

    private func stepDot(_ i: Int, _ title: String) -> some View {
        let done = i < step.rawValue, active = i == step.rawValue
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(done ? SK.accent : (active ? SK.accent.opacity(0.18) : Color.white.opacity(0.08)))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                } else {
                    Text("\(i + 1)").sk(11, active ? MK.accentText : SK.tertiary, weight: .semibold)
                }
            }
            .frame(width: 20, height: 20)
            Text(title).sk(12, done || active ? SK.text : SK.tertiary)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var pickProvider: some View {
        if app.providers.templates.isEmpty {
            MKSpinner(size: 16).frame(maxWidth: .infinity).padding(.vertical, 30)
        } else {
            SKGroup("Choose a provider") {
                ForEach(app.providers.templates, id: \.catalogProviderID) { tmpl in
                    Button {
                        selectedTemplate = tmpl
                        label = tmpl.name
                        apiKey = ""
                        baseURL = tmpl.apiBase ?? ""
                        errorMessage = nil
                        step = .enterCredentials
                    } label: {
                        SKRawRow {
                            HStack(spacing: 10) {
                                ProviderLogo(slug: tmpl.logoSlug, size: 16)
                                SKLabel(title: tmpl.name, detail: tmpl.driverType)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(SK.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKGroup(selectedTemplate?.name ?? "Provider") {
                SKRow("Label") { SKTextField(label: "Label", text: $label, width: 260) }
                SKRow("API key", detail: selectedTemplate?.envKey.map { "Or leave it empty and set \($0) on the server." }) {
                    SKTextField(label: "API key", text: $apiKey, placeholder: "sk-…", width: 260, secure: true)
                }
                if selectedTemplate?.driverType == "openai-compatible" {
                    SKRow("API base URL") { SKTextField(label: "API base URL", text: $baseURL, placeholder: "https://api.example.com/v1", width: 260) }
                }
            }
            HStack(spacing: 8) {
                Button("Back") { step = .pickProvider; errorMessage = nil }.skButton()
                Spacer(minLength: 0)
                Button(working ? "Adding…" : "Add Provider") { Task { await createProvider() } }
                    .skButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!credentialsValid || working)
            }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKGroup("Enable models") {
                if discovered.isEmpty {
                    SKRawRow {
                        HStack {
                            Text("No models found.").sk(13, SK.secondary)
                            Spacer(minLength: 0)
                            if let id = createdProviderID {
                                Button("Try Again") { Task { await retryDiscover(providerID: id) } }.skButton(small: true).disabled(working)
                            }
                        }
                    }
                } else {
                    ForEach(discovered) { m in
                        SKRawRow {
                            HStack(spacing: 10) {
                                SKCheckbox(title: "", isOn: Binding(
                                    get: { selectedModelIDs.contains(m.modelID) || m.alreadyEnabled },
                                    set: { on in
                                        if on { selectedModelIDs.insert(m.modelID) } else { selectedModelIDs.remove(m.modelID) }
                                    }))
                                    .disabled(m.alreadyEnabled)
                                SKLabel(title: m.displayName, detail: m.alreadyEnabled ? "\(m.modelID) · already enabled" : m.modelID)
                            }
                        }
                    }
                }
            } footer: {
                Text("You can enable more in Settings ▸ Models.").sk(11.5, SK.tertiary)
            }
            HStack(spacing: 8) {
                Button("Back") { step = .enterCredentials; errorMessage = nil }.skButton()
                Spacer(minLength: 0)
                Button(working ? "Finishing…" : "Finish Setup") { Task { await enableSelected() } }
                    .skButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedModelIDs.isEmpty || working)
            }
        }
    }

    // MARK: Work

    private var credentialsValid: Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        if trimmedLabel.isEmpty || trimmedKey.isEmpty { return false }
        if selectedTemplate?.driverType == "openai-compatible", baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func createProvider() async {
        guard let tmpl = selectedTemplate, credentialsValid, !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        var config: [String: String] = ["api_key": apiKey]
        if tmpl.driverType == "openai-compatible" { config["base_url"] = baseURL }
        if let presetID = tmpl.presetID { config["preset_id"] = presetID }
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            errorMessage = "Couldn’t encode the credentials."
            return
        }
        do {
            let p = try await app.providers.createProvider(type: tmpl.driverType, label: label.trimmingCharacters(in: .whitespaces), config: data)
            createdProviderID = p.id
            await app.providers.load()
            do {
                discovered = try await app.providers.discoverModels(providerID: p.id)
                selectedModelIDs = Set(discovered.filter { !$0.alreadyEnabled }.filter { $0.capabilities?.streaming ?? false }.map(\.modelID))
            } catch {
                errorMessage = "The provider was added, but listing its models failed: \(PsmithError.display(error))"
            }
            step = .enableModels
        } catch {
            errorMessage = "Couldn’t add the provider: \(PsmithError.display(error))"
        }
    }

    private func retryDiscover(providerID: String) async {
        working = true
        defer { working = false }
        do {
            discovered = try await app.providers.discoverModels(providerID: providerID)
        } catch {
            errorMessage = "Listing models failed: \(PsmithError.display(error))"
        }
    }

    private func enableSelected() async {
        guard let providerID = createdProviderID, !selectedModelIDs.isEmpty, !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            _ = try await app.providers.enableModels(providerID: providerID, modelIDs: Array(selectedModelIDs))
            await app.providers.load()
        } catch {
            errorMessage = "Couldn’t enable the models: \(PsmithError.display(error))"
        }
    }
}
