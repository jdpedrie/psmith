import Foundation

/// One reeved login the app remembers across launches. Plural by
/// design — Reeve supports having multiple accounts signed in
/// simultaneously, possibly against different self-hosted servers,
/// and switching between them without re-authenticating.
///
/// `id` is a client-generated UUID, NOT a server-side identity.
/// It exists to namespace per-account state on disk (token file,
/// SwiftData cache, in-memory ViewModels) so two accounts on the
/// same host don't collide.
public struct Account: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// reeved base URL — e.g. `https://reeve.example.com:8080`.
    /// Two accounts can share a host (multiple users on one server)
    /// or live on different hosts (one per self-hosted instance).
    public let host: URL
    /// Username the account authenticated as. Cached client-side so
    /// the account chip can render an identity without an extra
    /// network round-trip.
    public let username: String
    /// Optional human-friendly label the user typed when adding the
    /// account ("Work", "Personal home server"). Falls back to
    /// `username @ host.short` for display when nil.
    public let displayLabel: String?
    /// When the account was first added locally. Used purely for
    /// stable sorting in the switcher UI.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        host: URL,
        username: String,
        displayLabel: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.username = username
        self.displayLabel = displayLabel
        self.createdAt = createdAt
    }

    /// Convenience text the account chip / switcher renders.
    public var resolvedDisplayLabel: String {
        if let s = displayLabel, !s.isEmpty { return s }
        return "\(username) · \(host.host ?? host.absoluteString)"
    }
}
