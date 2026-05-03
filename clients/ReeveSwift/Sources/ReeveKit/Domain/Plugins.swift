import Foundation

public struct ReevePluginCapabilities: Sendable, Hashable {
    public let configurable: Bool
    public let systemPrompter: Bool
    public let outgoingUserTransformer: Bool
    public let historyTransformer: Bool
    public let chunkTransformer: Bool
    public let displayTransformer: Bool
    public let toolProvider: Bool
    public let assistantContentTransformer: Bool
    public let messageLifecycleHook: Bool

    public init(
        configurable: Bool = false,
        systemPrompter: Bool = false,
        outgoingUserTransformer: Bool = false,
        historyTransformer: Bool = false,
        chunkTransformer: Bool = false,
        displayTransformer: Bool = false,
        toolProvider: Bool = false,
        assistantContentTransformer: Bool = false,
        messageLifecycleHook: Bool = false
    ) {
        self.configurable = configurable
        self.systemPrompter = systemPrompter
        self.outgoingUserTransformer = outgoingUserTransformer
        self.historyTransformer = historyTransformer
        self.chunkTransformer = chunkTransformer
        self.displayTransformer = displayTransformer
        self.toolProvider = toolProvider
        self.assistantContentTransformer = assistantContentTransformer
        self.messageLifecycleHook = messageLifecycleHook
    }
}

public enum ReeveConfigFieldType: Sendable, Hashable {
    case number, text, textarea, boolean, select
}

public struct ReeveConfigOption: Sendable, Hashable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct ReeveConfigField: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let display: String
    public let description: String
    public let type: ReeveConfigFieldType
    /// JSON-encoded default literal (e.g. "1", "\"<choices>\"", "true").
    /// Empty string means no default.
    public let defaultJSON: String
    public let options: [ReeveConfigOption]
    /// True when the form must collect a value before the plugin can be
    /// considered valid. The parent (profile form) Save button stays
    /// disabled while any required field on any attached plugin is empty.
    public let required: Bool
    /// True when this field lives at user scope rather than profile
    /// scope. Global fields render on a separate "Plugin settings"
    /// surface instead of in the per-profile plugin form (the user
    /// only enters credentials and other shared values once).
    public let global: Bool

    public init(
        name: String,
        display: String,
        description: String,
        type: ReeveConfigFieldType,
        defaultJSON: String,
        options: [ReeveConfigOption],
        required: Bool = false,
        global: Bool = false
    ) {
        self.name = name
        self.display = display
        self.description = description
        self.type = type
        self.defaultJSON = defaultJSON
        self.options = options
        self.required = required
        self.global = global
    }

    /// True when `value` is missing or blank for a required field.
    /// Number/boolean treat any present value as satisfying — the runtime
    /// validator on the server has the final say.
    public func isUnsatisfied(by value: Any?) -> Bool {
        guard required else { return false }
        switch type {
        case .text, .textarea, .select:
            if let s = value as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty }
            return true
        case .number:
            return value == nil
        case .boolean:
            // For required booleans, "false" still counts as a chosen value.
            return value == nil
        }
    }
}

public struct ReevePluginType: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Human-friendly label for the UI; falls back to `name` when the
    /// server doesn't ship one (older builds).
    public let displayName: String
    public let description: String
    public let capabilities: ReevePluginCapabilities
    public let configFields: [ReeveConfigField]

    public init(
        name: String,
        displayName: String? = nil,
        description: String,
        capabilities: ReevePluginCapabilities,
        configFields: [ReeveConfigField]
    ) {
        self.name = name
        self.displayName = displayName ?? name
        self.description = description
        self.capabilities = capabilities
        self.configFields = configFields
    }

    /// Fields that live on the per-profile plugin form.
    public var profileScopedConfigFields: [ReeveConfigField] {
        configFields.filter { !$0.global }
    }

    /// Fields that live on the global "Plugin settings" surface.
    public var globalConfigFields: [ReeveConfigField] {
        configFields.filter { $0.global }
    }
}

/// Per-user, per-plugin global config blob (mirrors the proto
/// UserPluginSettings shape). Returned by Get/List/Upsert RPCs.
public struct ReeveUserPluginSettings: Sendable, Hashable, Identifiable {
    public var id: String { pluginName }
    public let pluginName: String
    /// Raw JSON object with the global-scoped field values. Empty data
    /// (zero bytes) is treated as `{}` by the merge code on the server.
    public let config: Data

    public init(pluginName: String, config: Data) {
        self.pluginName = pluginName
        self.config = config
    }
}

extension ReeveUserPluginSettings {
    init(from p: Reeve_V1_UserPluginSettings) {
        self.init(pluginName: p.pluginName, config: p.config)
    }
}

public struct ReeveProfilePlugin: Sendable, Hashable, Identifiable {
    /// Stable id for SwiftUI ForEach. Profile plugins don't have a server
    /// id of their own; ordinal+name is unique within a profile.
    public var id: String { "\(ordinal)-\(pluginName)" }
    public let pluginName: String
    public let ordinal: Int32
    /// Raw JSON object encoding the per-instance config. Caller responsible
    /// for matching the plugin type's ConfigFields.
    public let config: Data

    public init(pluginName: String, ordinal: Int32, config: Data) {
        self.pluginName = pluginName
        self.ordinal = ordinal
        self.config = config
    }
}

// MARK: - Proto bridging

extension ReevePluginCapabilities {
    init(from p: Reeve_V1_PluginCapabilities) {
        self.init(
            configurable: p.configurable,
            systemPrompter: p.systemPrompter,
            outgoingUserTransformer: p.outgoingUserTransformer,
            historyTransformer: p.historyTransformer,
            chunkTransformer: p.chunkTransformer,
            displayTransformer: p.displayTransformer,
            toolProvider: p.toolProvider,
            assistantContentTransformer: p.assistantContentTransformer,
            messageLifecycleHook: p.messageLifecycleHook
        )
    }
}

extension ReeveConfigFieldType {
    init(from p: Reeve_V1_ConfigField.TypeEnum) {
        switch p {
        case .number:   self = .number
        case .text:     self = .text
        case .textarea: self = .textarea
        case .boolean:  self = .boolean
        case .select:   self = .select
        case .unspecified, .UNRECOGNIZED:
            self = .text
        }
    }
}

extension ReeveConfigOption {
    init(from p: Reeve_V1_ConfigOption) {
        self.init(value: p.value, label: p.label)
    }
}

extension ReeveConfigField {
    init(from p: Reeve_V1_ConfigField) {
        self.init(
            name: p.name,
            display: p.display,
            description: p.description_p,
            type: ReeveConfigFieldType(from: p.type),
            defaultJSON: p.defaultJson,
            options: p.options.map(ReeveConfigOption.init(from:)),
            required: p.required,
            global: p.global
        )
    }
}

extension ReevePluginType {
    init(from p: Reeve_V1_PluginType) {
        self.init(
            name: p.name,
            displayName: p.displayName.isEmpty ? p.name : p.displayName,
            description: p.description_p,
            capabilities: ReevePluginCapabilities(from: p.capabilities),
            configFields: p.configFields.map(ReeveConfigField.init(from:))
        )
    }
}

extension ReeveProfilePlugin {
    init(from p: Reeve_V1_ProfilePlugin) {
        self.init(
            pluginName: p.pluginName,
            ordinal: p.ordinal,
            config: p.config
        )
    }

    var proto: Reeve_V1_ProfilePlugin {
        var p = Reeve_V1_ProfilePlugin()
        p.pluginName = pluginName
        p.ordinal = ordinal
        p.config = config
        return p
    }
}
