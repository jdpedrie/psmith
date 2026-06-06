import Foundation
import Connect

/// Client-side mirror of the EmbedderConfig proto. Read via
/// `EmbedderRepository.get`, written via `update`.
///
/// `apiKey` is intentionally not stored on this struct — the
/// server NEVER returns the value, only `apiKeySet: Bool`. Edits
/// send the key as a transient `String?` parameter to `update`.
public struct ReeveEmbedderConfig: Sendable, Hashable, Codable {
    /// Registered driver type. Today only "openai"; future drivers
    /// (voyage, cohere, etc.) drop in the same registry server-
    /// side and show up here via `ListEmbedderTypes`.
    public let type: String
    public let baseURL: String
    public let model: String
    public let dimensions: Int32
    /// True when the server has an encrypted api_key on file. The
    /// settings UI shows a "credentials saved" indicator next to a
    /// Replace button; the editor field stays empty (no value to
    /// round-trip).
    public let apiKeySet: Bool
    public let enabled: Bool
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        type: String,
        baseURL: String,
        model: String,
        dimensions: Int32,
        apiKeySet: Bool,
        enabled: Bool,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.type = type
        self.baseURL = baseURL
        self.model = model
        self.dimensions = dimensions
        self.apiKeySet = apiKeySet
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from p: Reeve_V1_EmbedderConfig) {
        type = p.type
        baseURL = p.baseURL
        model = p.model
        dimensions = p.dimensions
        apiKeySet = p.apiKeySet
        enabled = p.enabled
        createdAt = p.hasCreatedAt ? p.createdAt.date : nil
        updatedAt = p.hasUpdatedAt ? p.updatedAt.date : nil
    }
}

/// Result of an `EmbedderRepository.test` call. ok=false carries
/// the upstream's error string in `errorMessage` so the UI can
/// render it inline.
public struct ReeveEmbedderTestResult: Sendable {
    public let ok: Bool
    public let errorMessage: String
    public let latencyMs: Int64

    public init(ok: Bool, errorMessage: String, latencyMs: Int64) {
        self.ok = ok
        self.errorMessage = errorMessage
        self.latencyMs = latencyMs
    }
}

/// Snapshot of the embedder worker's per-user progress: pending
/// messages plus a flag indicating whether anything is actively
/// processing them. Drives the "X messages embedded" chip on the
/// settings page.
public struct ReeveEmbedderStats: Sendable {
    public let unembeddedCount: Int32
    public let workerActive: Bool

    public init(unembeddedCount: Int32, workerActive: Bool) {
        self.unembeddedCount = unembeddedCount
        self.workerActive = workerActive
    }
}

/// Repository over the generated EmbedderServiceClient. Six RPCs
/// — Get / Update / Delete / Test / ListTypes / Stats — wrapped
/// so views consume `ReeveEmbedderConfig` instead of the raw
/// proto.
public final class EmbedderRepository: Sendable {
    private let client: Reeve_V1_EmbedderServiceClientInterface

    public init(client: Reeve_V1_EmbedderServiceClientInterface) {
        self.client = client
    }

    /// Returns the calling user's saved config, or a zero-value
    /// (enabled=false) shape when none exists. Never throws on
    /// absence.
    public func get() async throws -> ReeveEmbedderConfig {
        let resp = await client.getEmbedderConfig(request: Reeve_V1_GetEmbedderConfigRequest(), headers: [:])
        if let err = resp.error { throw ReeveError.from(err) }
        return ReeveEmbedderConfig(from: resp.message?.config ?? Reeve_V1_EmbedderConfig())
    }

    /// Sparse update. Each parameter is independently optional;
    /// nil leaves the corresponding field alone. `apiKey` is
    /// tri-state matching the server:
    ///
    ///   - nil → don't touch the encrypted blob.
    ///   - ""  → clear the api_key.
    ///   - any other value → encrypt + replace.
    public func update(
        type: String? = nil,
        baseURL: String? = nil,
        model: String? = nil,
        dimensions: Int32? = nil,
        apiKey: String? = nil,
        enabled: Bool? = nil
    ) async throws -> ReeveEmbedderConfig {
        var req = Reeve_V1_UpdateEmbedderConfigRequest()
        if let v = type { req.type = v }
        if let v = baseURL { req.baseURL = v }
        if let v = model { req.model = v }
        if let v = dimensions { req.dimensions = v }
        if let v = apiKey { req.apiKey = v }
        if let v = enabled { req.enabled = v }
        let resp = await client.updateEmbedderConfig(request: req, headers: [:])
        if let err = resp.error { throw ReeveError.from(err) }
        return ReeveEmbedderConfig(from: resp.message?.config ?? Reeve_V1_EmbedderConfig())
    }

    /// Drops the row entirely. The user's existing embeddings stay
    /// in place (we don't drop columns); the worker just stops
    /// picking up new rows and the memory plugin reports "search
    /// not configured" on tool-use. Re-enable by a subsequent
    /// `update`.
    public func delete() async throws {
        let resp = await client.deleteEmbedderConfig(request: Reeve_V1_DeleteEmbedderConfigRequest(), headers: [:])
        if let err = resp.error { throw ReeveError.from(err) }
    }

    /// Fires one synthetic Embed("ping") at the configured endpoint
    /// using the just-saved credentials and reports the outcome.
    /// The settings "Test" button renders this inline; ok=false
    /// carries the upstream's auth / network error string.
    public func test() async throws -> ReeveEmbedderTestResult {
        let resp = await client.testEmbedderConfig(request: Reeve_V1_TestEmbedderConfigRequest(), headers: [:])
        if let err = resp.error { throw ReeveError.from(err) }
        let m = resp.message ?? Reeve_V1_TestEmbedderConfigResponse()
        return ReeveEmbedderTestResult(ok: m.ok, errorMessage: m.errorMessage, latencyMs: m.latencyMs)
    }

    /// Sorted list of every embedder driver the server has
    /// registered. Drives the type-picker dropdown so the client
    /// doesn't hardcode the set.
    public func listTypes() async throws -> [String] {
        let resp = await client.listEmbedderTypes(request: Reeve_V1_ListEmbedderTypesRequest(), headers: [:])
        if let err = resp.error { throw ReeveError.from(err) }
        return resp.message?.types ?? []
    }

    /// Worker progress for the calling user. Polled by the settings
    /// page when a backfill is in flight (every few seconds is
    /// plenty; the count moves on the worker's batch interval).
    public func stats() async throws -> ReeveEmbedderStats {
        let resp = await client.getEmbedderStats(request: Reeve_V1_GetEmbedderStatsRequest(), headers: [:])
        if let err = resp.error { throw ReeveError.from(err) }
        let m = resp.message ?? Reeve_V1_GetEmbedderStatsResponse()
        return ReeveEmbedderStats(unembeddedCount: m.unembeddedCount, workerActive: m.workerActive)
    }
}
