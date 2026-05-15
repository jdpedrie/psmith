import SwiftUI
import ReeveKit
import ReeveUI

/// iOS conversation-settings — pushed onto the conversation's
/// NavigationStack per `docs/ios-screens.md` §2.8. Hosts the shared
/// `CallSettingsForm` bound to the model's draft. Auto-saves on
/// disappear (no Save button — every field is debounced + persisted
/// on its own; back-tap commits).
struct ConversationSettingsView: View {
    @Bindable var model: ConversationViewModel

    var body: some View {
        Group {
            if model.preparingSettingsView {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerNote
                        CallSettingsForm(
                            settings: $model.conversationCallSettingsDraft,
                            inheritedSettings: model.resolvedCallSettings,
                            driverType: effectiveDriverType,
                            modelCapabilities: effectiveModelCapabilities,
                            modelConstraints: effectiveModelConstraints
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.prepareSettingsView()
        }
        .onDisappear {
            Task { await model.saveCallSettings() }
        }
    }

    private var headerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Conversation overrides")
                .font(.headline)
            Text("Any field left unset inherits from the resolved profile (and below). Changes auto-save when you go back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Driver / model resolution

    private var effectiveDriverType: String {
        if let pid = effectiveProviderID, let type = model.providerTypes[pid] {
            return type
        }
        return "anthropic"
    }

    private var effectiveProviderID: String? {
        if let pid = model.conversation.settings?.defaultProviderID, !pid.isEmpty { return pid }
        return model.settingsResolvedProfile?.defaultSettings?.defaultProviderID
    }

    private var effectiveModelID: String? {
        if let mid = model.conversation.settings?.defaultModelID, !mid.isEmpty { return mid }
        return model.settingsResolvedProfile?.defaultSettings?.defaultModelID
    }

    private var effectiveModelCapabilities: ReeveModelCapabilities? {
        guard let pid = effectiveProviderID, let mid = effectiveModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .capabilities
    }

    private var effectiveModelConstraints: ReeveModelConstraints? {
        guard let pid = effectiveProviderID, let mid = effectiveModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .constraints
    }
}
