import Foundation
import Connect

/// Per-user preferences stored on the server, so every device the user
/// signs in on reads the same values. Mirror of `UserPreferences`.
public struct PsmithUserPreferences: Sendable, Hashable, Codable {
    /// Conversation context size past which the clients warn; 0 = off.
    public var contextWarningTokens: Int32

    public init(contextWarningTokens: Int32 = 0) {
        self.contextWarningTokens = contextWarningTokens
    }

    public static let defaults = PsmithUserPreferences()
}

extension PsmithUserPreferences {
    init(from p: Psmith_V1_UserPreferences) {
        self.init(contextWarningTokens: p.contextWarningTokens)
    }
}

public final class PreferencesRepository: Sendable {
    private let client: Psmith_V1_PreferencesServiceClientInterface
    private let cache: PsmithCache?

    public init(client: Psmith_V1_PreferencesServiceClientInterface, cache: PsmithCache? = nil) {
        self.client = client
        self.cache = cache
    }

    /// The server's values (cached on success), falling back to the
    /// last cached copy when the server can't be reached.
    public func get() async throws -> PsmithUserPreferences {
        // Read at launch alongside the other launch loads, so bounded
        // like them (see RPCTimeout.swift).
        let resp = try? await withRPCTimeout(seconds: 6) { [client] in
            await client.getPreferences(request: Psmith_V1_GetPreferencesRequest(), headers: [:])
        }
        if let msg = resp?.message {
            let prefs = PsmithUserPreferences(from: msg.preferences)
            await store(prefs)
            return prefs
        }
        if let cached = await cachedGet() { return cached }
        throw resp?.error.map(PsmithError.from) ?? .missingPayload("get preferences")
    }

    public func cachedGet() async -> PsmithUserPreferences? {
        guard let cache else { return nil }
        return await cache.get(PsmithUserPreferences.self, kind: CacheKind.preferences, id: "me")
    }

    /// Sparse: nil leaves the stored value alone. Returns everything
    /// stored after the write.
    public func update(contextWarningTokens: Int32? = nil) async throws -> PsmithUserPreferences {
        var req = Psmith_V1_UpdatePreferencesRequest()
        if let v = contextWarningTokens { req.contextWarningTokens = v }
        let resp = await client.updatePreferences(request: req, headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(PsmithError.from) ?? .missingPayload("update preferences")
        }
        let prefs = PsmithUserPreferences(from: msg.preferences)
        await store(prefs)
        return prefs
    }

    private func store(_ prefs: PsmithUserPreferences) async {
        guard let cache else { return }
        try? await cache.set(prefs, kind: CacheKind.preferences, id: "me", capBytes: CachePreferences.capBytes)
    }
}
