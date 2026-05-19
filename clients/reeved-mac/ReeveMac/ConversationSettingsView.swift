import SwiftUI
import ReeveKit
import ReeveUI

/// Full-pane "Settings" view shown when the user opens the gear button in
/// the conversation toolbar. Replaces the message scroll inline (no
/// popovers, no sheets) per the project's "no popup windows" convention.
/// Mirrors `CompactPane` and `ContextListPane`'s page-replaces-pane shape.
///
/// Two tabs: **Call Settings** (the existing CallSettingsForm) and
/// **Plugins** (a per-row view of the merged pipeline with inheritance
/// badges + per-row disable/restore against the conversation override).
/// Call-settings draft auto-saves on dismiss; plugin overrides persist
/// immediately on each toggle.
struct ConversationSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case callSettings = "Call Settings"
        case plugins      = "Plugins"
        var id: String { rawValue }
    }

    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .callSettings

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.preparingSettingsView {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else {
                        switch tab {
                        case .callSettings: callSettingsTab
                        case .plugins:      pluginsTab
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            await model.loadAvailableModels()
            await model.prepareSettingsView()
        }
        .onDisappear {
            // Auto-save the call-settings draft on dismiss. Plugin
            // overrides persist on each toggle so nothing else to flush.
            let m = model
            Task { await m.saveCallSettings() }
        }
    }

    // MARK: - Tab chrome

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.rawValue)
                        .font(.callout.weight(t == tab ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(t == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .foregroundStyle(t == tab ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Call Settings tab

    private var callSettingsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation overrides")
                    .font(.headline)
                Text("Any field left unset inherits from the resolved profile (and below). Changes auto-save when you go back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CallSettingsForm(
                settings: $model.conversationCallSettingsDraft,
                inheritedSettings: model.resolvedCallSettings,
                driverType: effectiveDriverType,
                modelCapabilities: effectiveModelCapabilities,
                modelConstraints: effectiveModelConstraints
            )
        }
    }

    // MARK: - Plugins tab

    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugin pipeline")
                    .font(.headline)
                Text("Each row shows a plugin that's currently active for this conversation, with where it came from. Disable a row to subtract it from this conversation only — the profile chain stays intact for everyone else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.resolvedPluginPipeline.isEmpty && subtractedRows.isEmpty {
                Text("No plugins are active for this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.resolvedPluginPipeline) { entry in
                        pluginRow(for: entry)
                    }
                    ForEach(subtractedRows, id: \.self) { name in
                        subtractedRow(for: name)
                    }
                }
            }

            if !model.conversationPluginOverrides.isEmpty {
                Divider().padding(.vertical, 4)
                Button(role: .destructive) {
                    Task { await model.clearAllConversationOverrides() }
                } label: {
                    Label("Clear all conversation overrides", systemImage: "arrow.uturn.backward")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Names of plugins that aren't in the merged pipeline because the
    /// conversation override subtracted them — surfaced so the user can
    /// reverse the subtract without leaving the page.
    private var subtractedRows: [String] {
        let active = Set(model.resolvedPluginPipeline.map { $0.pluginName })
        return model.conversationPluginOverrides
            .filter { $0.disabled && !active.contains($0.pluginName) }
            .map { $0.pluginName }
    }

    @ViewBuilder
    private func pluginRow(for entry: ReeveResolvedPipelineEntry) -> some View {
        let displayName = displayName(for: entry.pluginName)
        let source = entry.source
        let canSubtract = source == .profile
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.callout.weight(.medium))
                    sourceBadge(for: source)
                }
                Text(entry.pluginName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if canSubtract {
                Button("Disable here") {
                    Task { await model.toggleConversationDisableInherited(pluginName: entry.pluginName) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if source == .conversation {
                Button("Remove override") {
                    Task { await model.removeConversationOverride(pluginName: entry.pluginName) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func subtractedRow(for pluginName: String) -> some View {
        let displayName = displayName(for: pluginName)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Text("Disabled for this conversation")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.orange.opacity(0.18))
                        )
                        .foregroundStyle(Color.orange)
                }
                Text(pluginName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Restore") {
                Task { await model.toggleConversationDisableInherited(pluginName: pluginName) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
    }

    @ViewBuilder
    private func sourceBadge(for source: ReeveResolvedPipelineSource) -> some View {
        let (label, color): (String, Color) = {
            switch source {
            case .profile:      return ("Inherited", .secondary)
            case .conversation: return ("Conversation override", .accentColor)
            case .unspecified:  return ("Unknown", .secondary)
            }
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.18))
            )
            .foregroundStyle(color)
    }

    private func displayName(for pluginName: String) -> String {
        if let t = model.registeredPluginTypes.first(where: { $0.name == pluginName }) {
            return t.displayName.isEmpty ? pluginName : t.displayName
        }
        return pluginName
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
