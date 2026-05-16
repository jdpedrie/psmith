import SwiftUI
import ReeveKit

/// Fullscreen onboarding gate shown when the signed-in user has zero
/// configured providers or zero enabled models. Walks them through
/// adding a provider + enabling a model in three inline steps:
///
///   1. **Pick a provider** — grid of provider templates (logo + name).
///   2. **Enter API key** — label / api_key / base_url form.
///   3. **Enable models** — list of discovered models with checkboxes.
///
/// Once step 3 completes (enabled count > 0), the parent gate flips and
/// the user lands in the normal app. State is observed live: if the
/// user opens Settings in another window and adds a provider/model
/// there, the gate also lifts automatically.
public struct OnboardingView: View {
    @Environment(AppModel.self) private var app

    @State private var step: Step = .pickProvider
    @State private var selectedTemplate: ReeveProviderTemplate?
    @State private var label: String = ""
    @State private var apiKey: String = ""
    @State private var baseURL: String = ""
    @State private var working: Bool = false
    @State private var errorMessage: String?
    @State private var createdProviderID: String?
    @State private var discovered: [ReeveDiscoveredModel] = []
    @State private var selectedModelIDs: Set<String> = []

    public init() {}

    enum Step: Int { case pickProvider, enterCredentials, enableModels }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                stepIndicator
                Group {
                    switch step {
                    case .pickProvider:    pickProviderStep
                    case .enterCredentials: enterCredentialsStep
                    case .enableModels:    enableModelsStep
                    }
                }
                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await app.providers.loadTemplates() }
    }

    // MARK: - Header / step indicator

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Reeve")
                .font(.largeTitle.weight(.semibold))
            Text("To get started, connect at least one AI provider and enable a model. Reeve stores your credentials locally on this machine and routes every chat through providers you control.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 12) {
            stepDot(1, label: "Provider", active: step == .pickProvider, done: step.rawValue > 0)
            Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
            stepDot(2, label: "Credentials", active: step == .enterCredentials, done: step.rawValue > 1)
            Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
            stepDot(3, label: "Models", active: step == .enableModels, done: false)
        }
    }

    private func stepDot(_ n: Int, label: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(done ? Color.accentColor : (active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(n)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                }
            }
            Text(label)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    // MARK: - Step 1: pick a provider

    @ViewBuilder
    private var pickProviderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a provider")
                .font(.title3.weight(.semibold))
            Text("Reeve supports the major LLM providers plus any OpenAI-compatible endpoint. Pick one to start — you can add more later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if app.providers.templates.isEmpty {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(app.providers.templates, id: \.catalogProviderID) { tmpl in
                        templateCard(tmpl)
                    }
                }
            }
        }
    }

    private func templateCard(_ tmpl: ReeveProviderTemplate) -> some View {
        Button {
            selectedTemplate = tmpl
            label = tmpl.name
            apiKey = ""
            baseURL = tmpl.apiBase ?? ""
            errorMessage = nil
            step = .enterCredentials
        } label: {
            HStack(spacing: 10) {
                ProviderLogo(slug: tmpl.logoSlug, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tmpl.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(tmpl.driverType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: credentials

    @ViewBuilder
    private var enterCredentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let tmpl = selectedTemplate {
                    ProviderLogo(slug: tmpl.logoSlug, size: 22)
                    Text(tmpl.name)
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Button("Back") {
                    step = .pickProvider
                    errorMessage = nil
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Label").font(.caption.weight(.medium))
                TextField("e.g. Anthropic", text: $label)
                    .textFieldStyle(.roundedBorder)
                Text("Display name shown in pickers.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API key").font(.caption.weight(.medium))
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                if let envKey = selectedTemplate?.envKey {
                    Text("Often set via the \(envKey) environment variable.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let tmpl = selectedTemplate, tmpl.driverType == "openai-compatible" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API base URL").font(.caption.weight(.medium))
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Required for OpenAI-compatible providers.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack {
                Spacer()
                Button {
                    Task { await createProvider() }
                } label: {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add Provider")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!credentialsValid || working)
            }
        }
    }

    private var credentialsValid: Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        if trimmedLabel.isEmpty || trimmedKey.isEmpty { return false }
        if let tmpl = selectedTemplate, tmpl.driverType == "openai-compatible" {
            if baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    @MainActor
    private func createProvider() async {
        guard let tmpl = selectedTemplate, credentialsValid, !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }

        var config: [String: String] = ["api_key": apiKey]
        if tmpl.driverType == "openai-compatible" {
            config["base_url"] = baseURL
        }
        if let presetID = tmpl.presetID {
            config["preset_id"] = presetID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            errorMessage = "Failed to encode credentials."
            return
        }

        do {
            let p = try await app.providers.createProvider(
                type: tmpl.driverType,
                label: label.trimmingCharacters(in: .whitespaces),
                config: data
            )
            createdProviderID = p.id
            await app.providers.load()
            // Auto-discover before showing step 3 so the list appears
            // already populated — one less click for the user.
            do {
                discovered = try await app.providers.discoverModels(providerID: p.id)
                // Preselect the most common defaults: every non-already-
                // enabled model with a `streaming` capability (excludes
                // image/embedding-only models for the chat use case).
                selectedModelIDs = Set(
                    discovered
                        .filter { !$0.alreadyEnabled }
                        .filter { $0.capabilities?.streaming ?? false }
                        .map(\.modelID)
                )
            } catch {
                // Discovery failure is recoverable — surface but advance
                // anyway so the user can retry from step 3.
                errorMessage = "Provider added, but model discovery failed: \(ReeveError.display(error))"
            }
            step = .enableModels
        } catch {
            errorMessage = "Couldn't add provider: \(ReeveError.display(error))"
        }
    }

    // MARK: - Step 3: enable models

    @ViewBuilder
    private var enableModelsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Enable models")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Back") {
                    step = .enterCredentials
                    errorMessage = nil
                }
                .buttonStyle(.borderless)
            }
            Text("Pick one or more models to make available for chat. You can add more later from Settings → Providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if discovered.isEmpty {
                if let providerID = createdProviderID {
                    Button("Retry discovery") {
                        Task { await retryDiscover(providerID: providerID) }
                    }
                    .disabled(working)
                } else {
                    Text("No models found.")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(discovered) { m in
                        modelCheckbox(m)
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    Task { await enableSelected() }
                } label: {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Finish setup")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedModelIDs.isEmpty || working)
            }
        }
    }

    private func modelCheckbox(_ m: ReeveDiscoveredModel) -> some View {
        let selected = selectedModelIDs.contains(m.modelID) || m.alreadyEnabled
        return Button {
            if m.alreadyEnabled { return }
            if selectedModelIDs.contains(m.modelID) {
                selectedModelIDs.remove(m.modelID)
            } else {
                selectedModelIDs.insert(m.modelID)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.displayName)
                        .font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        Text(m.modelID)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if m.alreadyEnabled {
                            Text("(already enabled)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(m.alreadyEnabled)
    }

    @MainActor
    private func retryDiscover(providerID: String) async {
        working = true
        defer { working = false }
        do {
            discovered = try await app.providers.discoverModels(providerID: providerID)
        } catch {
            errorMessage = "Discovery failed: \(ReeveError.display(error))"
        }
    }

    @MainActor
    private func enableSelected() async {
        guard let providerID = createdProviderID, !selectedModelIDs.isEmpty, !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            _ = try await app.providers.enableModels(
                providerID: providerID,
                modelIDs: Array(selectedModelIDs)
            )
            await app.providers.load()
            // Done — parent gate observes the providers/models change
            // and swaps in the main app. Nothing more to do here.
        } catch {
            errorMessage = "Couldn't enable models: \(ReeveError.display(error))"
        }
    }
}
