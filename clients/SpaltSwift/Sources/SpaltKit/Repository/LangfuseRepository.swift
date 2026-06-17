import Foundation
import Connect

/// Client-side mirror of the LangfuseConfig proto. Read via
/// `LangfuseRepository.get`, written via `update`.
///
/// `secretKey` is intentionally not stored on this struct — the
/// server NEVER returns the value, only `hasSecretKey: Bool`.
/// Edits send the secret as a transient `String?` parameter to
/// `update` instead.
public struct SpaltLangfuseConfig: Sendable, Hashable, Codable {
    public let host: String
    public let publicKey: String
    /// True when the server has an encrypted secret on file. The
    /// settings UI renders a "credentials saved" indicator next to
    /// a Replace button when this is true; the input field is
    /// pre-empty (no value to round-trip).
    public let secretKeySet: Bool
    public let enabled: Bool
    public let createdAt: Date?
    public let updatedAt: Date?
    /// Wall-clock of the last successful POST to Langfuse for the
    /// calling user. nil when no successful emit has happened in
    /// this server process (server restarted recently, or the
    /// integration was just enabled but no turn has fired yet).
    /// The settings UI renders this as "Last emit: N ago" so the
    /// user has confirmation events are flowing.
    public let lastEmittedAt: Date?

    public init(
        host: String,
        publicKey: String,
        secretKeySet: Bool,
        enabled: Bool,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        lastEmittedAt: Date? = nil
    ) {
        self.host = host
        self.publicKey = publicKey
        self.secretKeySet = secretKeySet
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEmittedAt = lastEmittedAt
    }

    init(from p: Spalt_V1_LangfuseConfig) {
        host = p.host
        publicKey = p.publicKey
        secretKeySet = p.secretKeySet
        enabled = p.enabled
        createdAt = p.hasCreatedAt ? p.createdAt.date : nil
        updatedAt = p.hasUpdatedAt ? p.updatedAt.date : nil
        lastEmittedAt = p.hasLastEmittedAt ? p.lastEmittedAt.date : nil
    }
}

/// Result of a `LangfuseRepository.test` call. ok=false carries
/// the upstream's error string in `errorMessage` so the UI can
/// render it inline.
public struct SpaltLangfuseTestResult: Sendable {
    public let ok: Bool
    public let errorMessage: String
    public let latencyMs: Int64

    public init(ok: Bool, errorMessage: String, latencyMs: Int64) {
        self.ok = ok
        self.errorMessage = errorMessage
        self.latencyMs = latencyMs
    }
}

/// Repository over the generated LangfuseServiceClient. The four
/// RPCs (Get / Update / Delete / Test) all map straight through;
/// the wrapper exists so views consume `SpaltLangfuseConfig`
/// instead of the proto type directly.
public final class LangfuseRepository: Sendable {
    private let client: Spalt_V1_LangfuseServiceClientInterface

    public init(client: Spalt_V1_LangfuseServiceClientInterface) {
        self.client = client
    }

    /// Returns the calling user's saved config — or a zero-value
    /// (`enabled=false`) shape when no row exists yet. Never
    /// throws on absence.
    public func get() async throws -> SpaltLangfuseConfig {
        let resp = await client.getLangfuseConfig(request: Spalt_V1_GetLangfuseConfigRequest(), headers: [:])
        if let err = resp.error { throw SpaltError.from(err) }
        return SpaltLangfuseConfig(from: resp.message?.config ?? Spalt_V1_LangfuseConfig())
    }

    /// Sparse update. Each parameter is independently optional;
    /// nil values leave the corresponding column alone. The
    /// `secretKey` parameter has tri-state semantics matching the
    /// server:
    ///
    ///   - nil  → don't touch the encrypted secret blob.
    ///   - ""   → clear the secret.
    ///   - any other value → encrypt + replace.
    public func update(
        host: String? = nil,
        publicKey: String? = nil,
        secretKey: String? = nil,
        enabled: Bool? = nil
    ) async throws -> SpaltLangfuseConfig {
        var req = Spalt_V1_UpdateLangfuseConfigRequest()
        if let v = host { req.host = v }
        if let v = publicKey { req.publicKey = v }
        if let v = secretKey { req.secretKey = v }
        if let v = enabled { req.enabled = v }
        let resp = await client.updateLangfuseConfig(request: req, headers: [:])
        if let err = resp.error { throw SpaltError.from(err) }
        return SpaltLangfuseConfig(from: resp.message?.config ?? Spalt_V1_LangfuseConfig())
    }

    /// Drops the row entirely + tells the server to forget the
    /// emitter cache for this user. Use when the user wants to
    /// fully sever the integration; toggling enabled=false is the
    /// softer alternative that keeps credentials on file.
    public func delete() async throws {
        let resp = await client.deleteLangfuseConfig(request: Spalt_V1_DeleteLangfuseConfigRequest(), headers: [:])
        if let err = resp.error { throw SpaltError.from(err) }
    }

    /// Fires one synthetic trace at the configured host using the
    /// just-saved credentials and returns the outcome. The settings
    /// UI's "Test" button renders this inline — ok=false carries
    /// the upstream's auth / network error string.
    public func test() async throws -> SpaltLangfuseTestResult {
        let resp = await client.testLangfuseConfig(request: Spalt_V1_TestLangfuseConfigRequest(), headers: [:])
        if let err = resp.error { throw SpaltError.from(err) }
        let m = resp.message ?? Spalt_V1_TestLangfuseConfigResponse()
        return SpaltLangfuseTestResult(ok: m.ok, errorMessage: m.errorMessage, latencyMs: m.latencyMs)
    }
}
