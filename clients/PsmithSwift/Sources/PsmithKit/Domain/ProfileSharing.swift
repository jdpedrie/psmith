import Foundation

/// A profile serialized for sharing, plus what the export deliberately left
/// behind.
public struct PsmithProfileExport: Sendable, Hashable {
    /// The bundle bytes. Write to a file, or base64 for paste-sharing: the
    /// payload is the same either way.
    public let payload: Data
    /// Filename hint from the server, e.g. `coding-assistant.psmithprofile`.
    public let suggestedFilename: String
    /// What was withheld, phrased for the person doing the sharing. A bundle
    /// never carries credentials, and the recipient will have to supply their
    /// own, so this is worth showing before they send it.
    public let notices: [String]

    public init(payload: Data, suggestedFilename: String, notices: [String]) {
        self.payload = payload
        self.suggestedFilename = suggestedFilename
        self.notices = notices
    }

    /// Convenience for the paste-a-small-profile case.
    public var base64: String { payload.base64EncodedString() }
}

/// One thing an import could not wire up. Not an error: the profile still
/// imported, with that reference left unset.
public struct PsmithImportWarning: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// The bundle wanted a provider type this account has not configured.
        case providerMissing
        /// A named MCP server is not in this account's registry.
        case mcpServerMissing
        /// This server has no such plugin compiled in.
        case pluginUnknown
        /// The name collided with an existing profile and was suffixed.
        case renamed
        case unspecified
    }

    public let kind: Kind
    /// Server-composed and ready to display, so every client words it the same.
    public let message: String
    /// What the warning is about: a provider type, a server name, a plugin
    /// name. Lets a client offer a fix-it action.
    public let subject: String

    public var id: String { "\(kind)-\(subject)-\(message)" }

    public init(kind: Kind, message: String, subject: String) {
        self.kind = kind
        self.message = message
        self.subject = subject
    }
}

/// The outcome of an import, or of a dry run previewing one.
public struct PsmithImportResult: Sendable, Hashable {
    /// Created profiles, root-to-leaf. Empty for a dry run.
    public let profiles: [PsmithProfile]
    public let warnings: [PsmithImportWarning]
    /// Names the import had to suffix because they collided.
    public let renamed: [String]

    public init(profiles: [PsmithProfile], warnings: [PsmithImportWarning], renamed: [String]) {
        self.profiles = profiles
        self.warnings = warnings
        self.renamed = renamed
    }
}

// MARK: - Proto bridging

extension PsmithImportWarning {
    init(from proto: Psmith_V1_ImportWarning) {
        self.kind =
            switch proto.kind {
            case .providerMissing: .providerMissing
            case .mcpServerMissing: .mcpServerMissing
            case .pluginUnknown: .pluginUnknown
            case .renamed: .renamed
            default: .unspecified
            }
        self.message = proto.message
        self.subject = proto.subject
    }
}
