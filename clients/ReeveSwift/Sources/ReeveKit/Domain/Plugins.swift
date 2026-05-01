import Foundation

public struct ReevePluginCapabilities: Sendable, Hashable {
    public let configurable: Bool
    public let systemPrompter: Bool
    public let outgoingUserTransformer: Bool
    public let historyTransformer: Bool
    public let chunkTransformer: Bool
    public let displayTransformer: Bool
    public let toolProvider: Bool

    public init(
        configurable: Bool = false,
        systemPrompter: Bool = false,
        outgoingUserTransformer: Bool = false,
        historyTransformer: Bool = false,
        chunkTransformer: Bool = false,
        displayTransformer: Bool = false,
        toolProvider: Bool = false
    ) {
        self.configurable = configurable
        self.systemPrompter = systemPrompter
        self.outgoingUserTransformer = outgoingUserTransformer
        self.historyTransformer = historyTransformer
        self.chunkTransformer = chunkTransformer
        self.displayTransformer = displayTransformer
        self.toolProvider = toolProvider
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

    public init(
        name: String,
        display: String,
        description: String,
        type: ReeveConfigFieldType,
        defaultJSON: String,
        options: [ReeveConfigOption]
    ) {
        self.name = name
        self.display = display
        self.description = description
        self.type = type
        self.defaultJSON = defaultJSON
        self.options = options
    }
}

public struct ReevePluginType: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let capabilities: ReevePluginCapabilities
    public let configFields: [ReeveConfigField]

    public init(
        name: String,
        description: String,
        capabilities: ReevePluginCapabilities,
        configFields: [ReeveConfigField]
    ) {
        self.name = name
        self.description = description
        self.capabilities = capabilities
        self.configFields = configFields
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
            toolProvider: p.toolProvider
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
            options: p.options.map(ReeveConfigOption.init(from:))
        )
    }
}

extension ReevePluginType {
    init(from p: Reeve_V1_PluginType) {
        self.init(
            name: p.name,
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
