import Foundation

public struct PsmithPluginCapabilities: Sendable, Hashable {
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

public enum PsmithConfigFieldType: Sendable, Hashable {
    case number, text, textarea, boolean, select, modelPicker
}

/// How one field's value combines across the resolver's layered view
/// (root profile → leaf profile → conversation override). UIs can use
/// `appendString` to hint that an entry adds to whatever the chain
/// already contributes rather than replacing it.
public enum PsmithConfigFieldMerge: Sendable, Hashable {
    /// Leaf wins — every earlier layer is ignored for the field.
    case replace
    /// Each non-empty layer concatenates root-to-leaf, blank-line joined.
    case appendString
}

/// Mirror of `psmith.v1.ModelPickerFilter`. Drives which user_models
/// the chooser surfaces for a `.modelPicker` field. Any flag set to
/// true is required; flags AND together. Empty = no filter.
public struct PsmithModelPickerFilter: Sendable, Hashable {
    public let requiresStreaming: Bool
    public let requiresThinking: Bool
    public let requiresToolUse: Bool
    public let requiresVision: Bool
    public let requiresPromptCaching: Bool
    public let requiresGeneratesImages: Bool

    public init(
        requiresStreaming: Bool = false,
        requiresThinking: Bool = false,
        requiresToolUse: Bool = false,
        requiresVision: Bool = false,
        requiresPromptCaching: Bool = false,
        requiresGeneratesImages: Bool = false
    ) {
        self.requiresStreaming = requiresStreaming
        self.requiresThinking = requiresThinking
        self.requiresToolUse = requiresToolUse
        self.requiresVision = requiresVision
        self.requiresPromptCaching = requiresPromptCaching
        self.requiresGeneratesImages = requiresGeneratesImages
    }
}

public struct PsmithConfigOption: Sendable, Hashable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct PsmithConfigField: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let display: String
    public let description: String
    public let type: PsmithConfigFieldType
    /// JSON-encoded default literal (e.g. "1", "\"<choices>\"", "true").
    /// Empty string means no default.
    public let defaultJSON: String
    public let options: [PsmithConfigOption]
    /// True when the form must collect a value before the plugin can be
    /// considered valid. The parent (profile form) Save button stays
    /// disabled while any required field on any attached plugin is empty.
    public let required: Bool
    /// True when this field lives at user scope rather than profile
    /// scope. Global fields render on a separate "Plugin settings"
    /// surface instead of in the per-profile plugin form (the user
    /// only enters credentials and other shared values once).
    public let global: Bool
    /// Optional filter for `.modelPicker` fields. Hints to the UI
    /// which models to surface in the chooser. nil = no filter
    /// (irrelevant on non-`.modelPicker` types).
    public let modelPickerFilter: PsmithModelPickerFilter?
    /// How this field combines across the resolver's layered view.
    /// `.replace` (default) keeps the existing leaf-wins behaviour;
    /// `.appendString` means each layer's non-empty contribution
    /// concatenates with blank-line separators.
    public let merge: PsmithConfigFieldMerge
    /// Optional section header the UI groups the field under. Empty
    /// = ungrouped (rendered with the top-level fields). Used by
    /// plugins with many fields of the same kind — app_tools' per-
    /// tool toggles bundled by capability (Calendar / Reminders).
    public let category: String

    public init(
        name: String,
        display: String,
        description: String,
        type: PsmithConfigFieldType,
        defaultJSON: String,
        options: [PsmithConfigOption],
        required: Bool = false,
        global: Bool = false,
        modelPickerFilter: PsmithModelPickerFilter? = nil,
        merge: PsmithConfigFieldMerge = .replace,
        category: String = ""
    ) {
        self.name = name
        self.display = display
        self.description = description
        self.type = type
        self.defaultJSON = defaultJSON
        self.options = options
        self.required = required
        self.global = global
        self.modelPickerFilter = modelPickerFilter
        self.merge = merge
        self.category = category
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
        case .modelPicker:
            // Model picker stores `{"provider_id":"…","model_id":"…"}`;
            // any dict with both halves non-empty satisfies.
            if let dict = value as? [String: Any],
               let pid = dict["provider_id"] as? String,
               let mid = dict["model_id"] as? String,
               !pid.isEmpty, !mid.isEmpty {
                return false
            }
            return true
        }
    }
}

public struct PsmithPluginType: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Human-friendly label for the UI; falls back to `name` when the
    /// server doesn't ship one (older builds).
    public let displayName: String
    public let description: String
    public let capabilities: PsmithPluginCapabilities
    public let configFields: [PsmithConfigField]

    public init(
        name: String,
        displayName: String? = nil,
        description: String,
        capabilities: PsmithPluginCapabilities,
        configFields: [PsmithConfigField]
    ) {
        self.name = name
        self.displayName = displayName ?? name
        self.description = description
        self.capabilities = capabilities
        self.configFields = configFields
    }

    /// Fields that live on the per-profile plugin form.
    public var profileScopedConfigFields: [PsmithConfigField] {
        configFields.filter { !$0.global }
    }

    /// Fields that live on the global "Plugin settings" surface.
    public var globalConfigFields: [PsmithConfigField] {
        configFields.filter { $0.global }
    }
}

/// Per-user, per-plugin global config blob (mirrors the proto
/// UserPluginSettings shape). Returned by Get/List/Upsert RPCs.
public struct PsmithUserPluginSettings: Sendable, Hashable, Identifiable {
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

extension PsmithUserPluginSettings {
    init(from p: Psmith_V1_UserPluginSettings) {
        self.init(pluginName: p.pluginName, config: p.config)
    }
}

public struct PsmithProfilePlugin: Sendable, Hashable, Identifiable {
    /// Stable id for SwiftUI ForEach. Profile plugins don't have a server
    /// id of their own; ordinal+name is unique within a profile.
    public var id: String { "\(ordinal)-\(pluginName)" }
    public let pluginName: String
    public let ordinal: Int32
    /// Raw JSON object encoding the per-instance config. Caller responsible
    /// for matching the plugin type's ConfigFields.
    public let config: Data
    /// When true, this row subtracts the same-named plugin inherited
    /// from a parent profile instead of contributing one. `config` is
    /// ignored in this case.
    public let disabled: Bool

    public init(pluginName: String, ordinal: Int32, config: Data, disabled: Bool = false) {
        self.pluginName = pluginName
        self.ordinal = ordinal
        self.config = config
        self.disabled = disabled
    }
}

/// Conversation-scoped plugin override. Same shape as `PsmithProfilePlugin`
/// but lives on the conversation row; merged on top of the profile chain
/// at resolve time (same-name entries override, `disabled: true` subtracts).
public struct PsmithConversationPlugin: Sendable, Hashable, Identifiable {
    public var id: String { "\(ordinal)-\(pluginName)" }
    public let pluginName: String
    public let ordinal: Int32
    public let config: Data
    public let disabled: Bool

    public init(pluginName: String, ordinal: Int32, config: Data, disabled: Bool = false) {
        self.pluginName = pluginName
        self.ordinal = ordinal
        self.config = config
        self.disabled = disabled
    }
}

/// Which layer of the resolver produced an entry in the merged pipeline.
public enum PsmithResolvedPipelineSource: Sendable, Hashable {
    case profile
    case conversation
    case unspecified
}

/// One entry in the merged pipeline (profile chain + conversation
/// overrides + disabled subtracts already applied).
public struct PsmithResolvedPipelineEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(ordinal)-\(pluginName)" }
    public let pluginName: String
    public let ordinal: Int32
    public let config: Data
    public let source: PsmithResolvedPipelineSource

    public init(pluginName: String, ordinal: Int32, config: Data, source: PsmithResolvedPipelineSource) {
        self.pluginName = pluginName
        self.ordinal = ordinal
        self.config = config
        self.source = source
    }
}

// MARK: - Proto bridging

extension PsmithPluginCapabilities {
    init(from p: Psmith_V1_PluginCapabilities) {
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

extension PsmithConfigFieldType {
    init(from p: Psmith_V1_ConfigField.TypeEnum) {
        switch p {
        case .number:      self = .number
        case .text:        self = .text
        case .textarea:    self = .textarea
        case .boolean:     self = .boolean
        case .select:      self = .select
        case .modelPicker: self = .modelPicker
        case .unspecified, .UNRECOGNIZED:
            self = .text
        }
    }
}

extension PsmithModelPickerFilter {
    init(from p: Psmith_V1_ModelPickerFilter) {
        self.init(
            requiresStreaming:       p.requiresStreaming,
            requiresThinking:        p.requiresThinking,
            requiresToolUse:         p.requiresToolUse,
            requiresVision:          p.requiresVision,
            requiresPromptCaching:   p.requiresPromptCaching,
            requiresGeneratesImages: p.requiresGeneratesImages
        )
    }
}

extension PsmithConfigOption {
    init(from p: Psmith_V1_ConfigOption) {
        self.init(value: p.value, label: p.label)
    }
}

extension PsmithConfigField {
    init(from p: Psmith_V1_ConfigField) {
        let filter: PsmithModelPickerFilter? = p.hasModelPickerFilter
            ? PsmithModelPickerFilter(from: p.modelPickerFilter)
            : nil
        let merge: PsmithConfigFieldMerge
        switch p.merge {
        case .appendString: merge = .appendString
        default:            merge = .replace
        }
        self.init(
            name: p.name,
            display: p.display,
            description: p.description_p,
            type: PsmithConfigFieldType(from: p.type),
            defaultJSON: p.defaultJson,
            options: p.options.map(PsmithConfigOption.init(from:)),
            required: p.required,
            global: p.global,
            modelPickerFilter: filter,
            merge: merge,
            category: p.category
        )
    }
}

extension PsmithPluginType {
    init(from p: Psmith_V1_PluginType) {
        self.init(
            name: p.name,
            displayName: p.displayName.isEmpty ? p.name : p.displayName,
            description: p.description_p,
            capabilities: PsmithPluginCapabilities(from: p.capabilities),
            configFields: p.configFields.map(PsmithConfigField.init(from:))
        )
    }
}

extension PsmithProfilePlugin {
    init(from p: Psmith_V1_ProfilePlugin) {
        self.init(
            pluginName: p.pluginName,
            ordinal: p.ordinal,
            config: p.config,
            disabled: p.disabled
        )
    }

    var proto: Psmith_V1_ProfilePlugin {
        var p = Psmith_V1_ProfilePlugin()
        p.pluginName = pluginName
        p.ordinal = ordinal
        p.config = config
        p.disabled = disabled
        return p
    }
}

extension PsmithConversationPlugin {
    init(from p: Psmith_V1_ConversationPlugin) {
        self.init(
            pluginName: p.pluginName,
            ordinal: p.ordinal,
            config: p.config,
            disabled: p.disabled
        )
    }

    var proto: Psmith_V1_ConversationPlugin {
        var p = Psmith_V1_ConversationPlugin()
        p.pluginName = pluginName
        p.ordinal = ordinal
        p.config = config
        p.disabled = disabled
        return p
    }
}

extension PsmithResolvedPipelineSource {
    init(from p: Psmith_V1_ResolvedPipelineSource) {
        switch p {
        case .profile:      self = .profile
        case .conversation: self = .conversation
        case .unspecified, .UNRECOGNIZED:
            self = .unspecified
        }
    }
}

extension PsmithResolvedPipelineEntry {
    init(from p: Psmith_V1_ResolvedPipelineEntry) {
        self.init(
            pluginName: p.pluginName,
            ordinal: p.ordinal,
            config: p.config,
            source: PsmithResolvedPipelineSource(from: p.source)
        )
    }
}
