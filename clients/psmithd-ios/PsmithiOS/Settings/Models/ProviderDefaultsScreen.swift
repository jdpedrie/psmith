import SwiftUI
import PsmithKit
import PsmithUI

/// The call settings every model on a provider starts from (board
/// SettingsProviderDefaults). The bottom of the chain: nothing inherits
/// into it, so an unset field means the model's own default.
struct ProviderDefaultsScreen: View {
    let initialProvider: PsmithUserModelProvider
    @Environment(AppModel.self) private var app
    @State var draft: PsmithCallSettings
    @State private var saving = false
    @State private var error: String?

    init(provider: PsmithUserModelProvider, draft: PsmithCallSettings? = nil) {
        initialProvider = provider
        _draft = State(initialValue: draft ?? provider.defaultSettings ?? PsmithCallSettings())
    }

    private var provider: PsmithUserModelProvider {
        app.providers.providers.first { $0.id == initialProvider.id } ?? initialProvider
    }

    private var saved: PsmithCallSettings { provider.defaultSettings ?? PsmithCallSettings() }
    private var pending: Int { IKCallSettingsDiff.count(draft, saved) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IKPageNote("Every \(provider.label) model starts here. A model’s own settings win, then the profile’s, then the conversation’s. Not set means the model’s own default.",
                           settings: true, top: -2)
                if let error {
                    IKBanner(systemImage: "exclamationmark.triangle", text: error, color: IK.red).padding(.top, 10)
                }
                IKCallSettingsForm(settings: $draft, inherited: nil, driverType: provider.type, capabilities: nil,
                                   showAllProviderSections: false, style: .settings)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage("\(provider.label) Defaults")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pending > 0 {
                IKSaveBar(summary: IKCallSettingsDiff.summary(pending), canSave: !saving,
                          onRevert: { draft = saved }, onSave: { Task { await save() } })
            }
        }
    }

    func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await app.providers.updateProviderDefaultSettings(providerID: provider.id, settings: draft)
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}

/// A profile's own call settings, the layer between the model and the
/// conversation. Same look as a provider's defaults, with the model's
/// values below it shown as inherited and every provider's extras.
struct ProfileCallSettingsScreen: View {
    let profileID: String
    @Environment(AppModel.self) private var app
    @State var draft: PsmithCallSettings?
    @State private var saving = false
    @State private var error: String?

    init(profileID: String, draft: PsmithCallSettings? = nil) {
        self.profileID = profileID
        _draft = State(initialValue: draft)
    }

    private var profile: PsmithProfile? { app.profiles.profiles.first { $0.id == profileID } }
    private var saved: PsmithCallSettings { profile?.defaultSettings?.callSettings ?? PsmithCallSettings() }

    private var model: PsmithUserModel? {
        guard let d = profile?.defaultSettings, let p = d.defaultProviderID, let m = d.defaultModelID else { return nil }
        return app.profiles.availableModels.first { $0.providerID == p && $0.modelID == m }
    }

    /// What the profile inherits: the default model's settings over its
    /// provider's.
    private var inherited: PsmithCallSettings? {
        let pid = profile?.defaultSettings?.defaultProviderID
        let lower = pid.flatMap { p in app.profiles.providerDefaultSettings[p] ?? app.providers.providers.first { $0.id == p }?.defaultSettings }
        switch (model?.defaultSettings, lower) {
        case let (m?, l?): return CallSettingsMerge.merge(higher: m, lower: l)
        case let (m?, nil): return m
        case let (nil, l?): return l
        default: return nil
        }
    }

    private var driver: String {
        profile?.defaultSettings?.defaultProviderID.flatMap { app.profiles.providerTypes[$0] } ?? "anthropic"
    }

    var body: some View {
        let binding = Binding(get: { draft ?? saved }, set: { draft = $0 })
        let pending = IKCallSettingsDiff.count(draft ?? saved, saved)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IKPageNote(intro, settings: true, top: -2)
                if let error {
                    IKBanner(systemImage: "exclamationmark.triangle", text: error, color: IK.red).padding(.top, 10)
                }
                IKCallSettingsForm(settings: binding, inherited: inherited, driverType: driver,
                                   capabilities: model?.capabilities, constraints: model?.constraints,
                                   showAllProviderSections: true, style: .settings)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .ikSettingsPage("Call Settings")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pending > 0 {
                IKSaveBar(summary: IKCallSettingsDiff.summary(pending), canSave: !saving && profile != nil,
                          onRevert: { draft = nil }, onSave: { Task { await save() } })
            }
        }
        .task {
            if app.profiles.availableModels.isEmpty { await app.profiles.loadAvailableModels() }
        }
    }

    private var intro: String {
        let name = profile?.name ?? "This profile"
        let below = model.map { "\($0.displayName), then its provider" } ?? "the model, then its provider"
        return "\(name)’s defaults for every conversation it starts. Unset fields inherit from \(below). Conversations can override any of them."
    }

    func save() async {
        guard let p = profile else { return }
        saving = true
        error = nil
        defer { saving = false }
        let next = draft ?? saved
        // The server replaces the whole defaults blob: carry the model pick
        // and the thinking-history flag through.
        let defaults = PsmithProfileDefaults(
            defaultProviderID: p.defaultSettings?.defaultProviderID,
            defaultModelID: p.defaultSettings?.defaultModelID,
            includeThinkingInHistory: p.defaultSettings?.includeThinkingInHistory,
            callSettings: next.isEmpty ? nil : next)
        do {
            _ = try await app.profiles.update(id: p.id, patch: PsmithProfilePatch(defaultSettings: defaults))
            draft = nil
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}
