import SwiftUI
import ReeveKit
import ReeveUI

// MARK: - Per-plugin config sub-screen
//
// Pushed by either the profile-edit flow or the conversation-settings
// Plugins tab. Renders the per-plugin config form against a shared
// `[String: Any]` binding so the caller owns the draft state. The
// caller is responsible for persisting on dismiss / save / back.
//
// Extracted out of ProfilesListView so the conversation-settings
// Plugins tab can drive the exact same editor — single source of
// truth for plugin config rendering across surfaces.

struct PluginConfigSubScreen: View {
    let pluginName: String
    let pluginType: ReevePluginType?
    @Binding var config: [String: Any]
    let availableModels: [ReeveUserModel]
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let type = pluginType {
                    if !type.description.isEmpty {
                        Text(type.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let fields = type.profileScopedConfigFields
                    if fields.isEmpty {
                        Text("This plugin has no per-profile fields. Its global settings live in Settings → Plugins.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        PluginConfigEditor(
                            pluginName: type.name,
                            fields: fields,
                            config: $config,
                            availableModels: availableModels,
                            providerLabels: providerLabels,
                            providerTypes: providerTypes,
                            providerPresetIDs: providerPresetIDs
                        )
                    }
                } else {
                    Text("Plugin descriptor not loaded — pull back to refresh, then re-enter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .navigationTitle(pluginType?.displayName ?? pluginName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Add plugin sheet

/// Sheet that lists plugin types not yet attached. Tapping a row
/// invokes `onPick` and dismisses; the parent decides what to do
/// with the pick (attach to draft, create override, etc.).
struct AddPluginSheet: View {
    let types: [ReevePluginType]
    let onPick: (ReevePluginType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if types.isEmpty {
                    Text("Every available plugin is already attached.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(types) { type in
                        Button {
                            onPick(type)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(type.displayName)
                                        .foregroundStyle(.primary)
                                    if !type.description.isEmpty {
                                        Text(type.description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Config encoding helpers
//
// These two helpers convert between the on-disk JSON object the server
// stores (`Data`) and the in-memory `[String: Any]` PluginConfigEditor
// binds to. Used by both the profile draft flow and the conversation
// override flow.

/// Decode plugin config bytes into the editor's `[String: Any]` shape.
/// Empty/invalid bytes round-trip as an empty dict so the editor can
/// still surface every field.
func decodePluginConfig(_ data: Data) -> [String: Any] {
    guard !data.isEmpty,
          let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let dict = any as? [String: Any]
    else { return [:] }
    return dict
}

/// Encode an editor draft back to JSON bytes for the server. Strips
/// `NSNull` entries because PluginConfigForm represents "unset" as
/// no-key-present, but field-clear edits sometimes leave NSNulls
/// behind that the Go side rejects.
func encodePluginConfig(_ config: [String: Any]) -> Data {
    let cleaned = config.compactMapValues { value -> Any? in
        value is NSNull ? nil : value
    }
    return (try? JSONSerialization.data(withJSONObject: cleaned, options: [])) ?? Data("{}".utf8)
}

/// Builds an initial `[String: Any]` draft from a plugin type's
/// declared defaults. Used by the "add new plugin" flow so booleans
/// + numbers start at the field's `defaultJSON` literal rather than
/// "no value, please pick one".
func initialConfigFromDefaults(_ type: ReevePluginType) -> [String: Any] {
    var initial: [String: Any] = [:]
    for field in type.profileScopedConfigFields {
        if !field.defaultJSON.isEmpty,
           let data = field.defaultJSON.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            initial[field.name] = any
        }
    }
    return initial
}
