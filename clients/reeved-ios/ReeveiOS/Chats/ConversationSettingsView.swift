import SwiftUI
import ReeveKit
import ReeveUI

/// iOS conversation-settings — pushed onto the conversation's
/// NavigationStack per `docs/ios-screens.md` §2.8. Two segmented tabs:
/// **Call Settings** (the shared CallSettingsForm) and **Plugins** (a
/// per-row view of the merged pipeline with inheritance badges +
/// per-row disable/restore against the conversation override).
/// Call-settings draft auto-saves on disappear; plugin overrides
/// persist immediately on each toggle.
struct ConversationSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case callSettings = "Call Settings"
        case plugins      = "Plugins"
        var id: String { rawValue }
    }

    @Bindable var model: ConversationViewModel
    @State private var tab: Tab = .callSettings

    var body: some View {
        Group {
            if model.preparingSettingsView {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch tab {
                            case .callSettings: callSettingsTab
                            case .plugins:      pluginsTab
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
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

    // MARK: - Call Settings tab

    private var callSettingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugin pipeline")
                    .font(.headline)
                Text("Each row shows a plugin that's currently active for this conversation, with where it came from. Disable a row to subtract it from this conversation only — the profile chain stays intact.")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                sourceBadge(for: source)
                Spacer()
            }
            Text(entry.pluginName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                if source == .profile {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func subtractedRow(for pluginName: String) -> some View {
        let displayName = displayName(for: pluginName)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Text("Disabled")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.orange.opacity(0.2))
                    )
                    .foregroundStyle(Color.orange)
                Spacer()
            }
            Text(pluginName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Restore") {
                    Task { await model.toggleConversationDisableInherited(pluginName: pluginName) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    @ViewBuilder
    private func sourceBadge(for source: ReeveResolvedPipelineSource) -> some View {
        let (label, color): (String, Color) = {
            switch source {
            case .profile:      return ("Inherited", .secondary)
            case .conversation: return ("Override", .accentColor)
            case .unspecified:  return ("Unknown", .secondary)
            }
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.2))
            )
            .foregroundStyle(color)
    }

    private func displayName(for pluginName: String) -> String {
        if let t = model.registeredPluginTypes.first(where: { $0.name == pluginName }) {
            return t.displayName.isEmpty ? pluginName : t.displayName
        }
        return pluginName
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
