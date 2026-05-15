import SwiftUI
import ReeveKit
import ReeveUI

/// Full-pane "Settings" view shown when the user opens the gear button in
/// the conversation toolbar. Replaces the message scroll inline (no
/// popovers, no sheets) per the project's "no popup windows" convention.
/// Mirrors `CompactPane` and `ContextListPane`'s page-replaces-pane shape.
///
/// The form auto-saves on dismiss — no "Save" button. Back-chevron in the
/// leading toolbar slot (owned by `ConversationBody`) flips
/// `model.showingSettingsView` back to false; the view's `onDisappear`
/// fires `saveCallSettings()`.
struct ConversationSettingsView: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.preparingSettingsView {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    headerNote

                    CallSettingsForm(
                        settings: $model.conversationCallSettingsDraft,
                        inheritedSettings: model.resolvedCallSettings,
                        driverType: effectiveDriverType,
                        modelCapabilities: effectiveModelCapabilities,
                        modelConstraints: effectiveModelConstraints
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Make sure the conversation view model has the latest models /
            // providers — the form needs availableModels to resolve the
            // per-model layer of the merge chain and providerTypes to pick
            // the right driver-specific extras block.
            await model.loadAvailableModels()
            await model.prepareSettingsView()
        }
        .onDisappear {
            // Auto-save on dismiss. Spawn a detached task because
            // onDisappear runs synchronously.
            let m = model
            Task { await m.saveCallSettings() }
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

    // MARK: - Driver / model resolution for the form

    /// The driver type the form should render extras for. Picked from the
    /// most-precedent (provider, model) selection visible: conversation
    /// settings → resolved profile defaults → fallback to "anthropic".
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

    /// Per-model UI guardrails for the active conversation's pinned
    /// model. Sourced from `internal/modelmeta/constraints.go` over
    /// the wire on `ReeveUserModel.constraints`. nil = no known
    /// constraints; the form falls back to driver-type heuristics.
    private var effectiveModelConstraints: ReeveModelConstraints? {
        guard let pid = effectiveProviderID, let mid = effectiveModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .constraints
    }
}
