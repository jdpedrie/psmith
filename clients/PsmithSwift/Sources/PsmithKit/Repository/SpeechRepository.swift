import Foundation
import Connect

/// Client-side mirror of the SpeechConfig proto. `apiKey` is never
/// stored here — the server only reports `apiKeySet`; edits send the
/// key as a transient parameter to `update`.
public struct PsmithSpeechConfig: Sendable, Hashable, Codable {
    /// "apple_local" (on-device, the default), "grok",
    /// "openai-compatible".
    public let kind: String
    public let voice: String
    public let model: String
    public let speed: Double
    /// openai-compatible only: self-hosted server base URL.
    public let baseURL: String
    public let apiKeySet: Bool
    /// Chat-provider row whose credential the speech driver reuses.
    public let providerRef: String
    public let enabled: Bool
    /// Server-side normalizer version — part of the replay-cache key.
    public let normalizerVersion: Int32
    public let createdAt: Date?
    public let updatedAt: Date?

    public static let kindAppleLocal = "apple_local"

    public var isAppleLocal: Bool { kind == Self.kindAppleLocal }

    public init(
        kind: String,
        voice: String = "",
        model: String = "",
        speed: Double = 0,
        baseURL: String = "",
        apiKeySet: Bool = false,
        providerRef: String = "",
        enabled: Bool = true,
        normalizerVersion: Int32 = 1,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.kind = kind
        self.voice = voice
        self.model = model
        self.speed = speed
        self.baseURL = baseURL
        self.apiKeySet = apiKeySet
        self.providerRef = providerRef
        self.enabled = enabled
        self.normalizerVersion = normalizerVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from p: Psmith_V1_SpeechConfig) {
        kind = p.kind
        voice = p.voice
        model = p.model
        speed = p.speed
        baseURL = p.baseURL
        apiKeySet = p.apiKeySet
        providerRef = p.providerRef
        enabled = p.enabled
        normalizerVersion = p.normalizerVersion
        createdAt = p.hasCreatedAt ? p.createdAt.date : nil
        updatedAt = p.hasUpdatedAt ? p.updatedAt.date : nil
    }
}

public struct PsmithSpeechTestResult: Sendable, Hashable {
    public let ok: Bool
    public let errorMessage: String
    public let latencyMs: Int64
    public let audioBytes: Int64
}

/// SpeechService RPCs plus the raw-bytes POST /tts fetch. The audio
/// endpoint bypasses Connect framing (chunked PCM), so it rides a
/// plain URLSession with the same bearer token — the
/// ElicitationsRepository pattern.
public final class SpeechRepository: Sendable {
    private let client: Psmith_V1_SpeechServiceClientInterface
    private let host: URL
    private let tokenStore: TokenStore
    private let session: URLSession

    public init(
        client: Psmith_V1_SpeechServiceClientInterface,
        host: URL,
        tokenStore: TokenStore,
        session: URLSession = .shared
    ) {
        self.client = client
        self.host = host
        self.tokenStore = tokenStore
        self.session = session
    }

    public func get() async throws -> PsmithSpeechConfig {
        let resp = await client.getSpeechConfig(request: Psmith_V1_GetSpeechConfigRequest(), headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(PsmithError.from) ?? .missingPayload("speech config")
        }
        return PsmithSpeechConfig(from: msg.config)
    }

    /// Sparse update: nil leaves a field unchanged. apiKey/providerRef
    /// use the server's tri-state (nil = unchanged, "" = clear).
    public func update(
        kind: String? = nil,
        voice: String? = nil,
        model: String? = nil,
        speed: Double? = nil,
        baseURL: String? = nil,
        apiKey: String? = nil,
        providerRef: String? = nil,
        enabled: Bool? = nil
    ) async throws -> PsmithSpeechConfig {
        var req = Psmith_V1_UpdateSpeechConfigRequest()
        if let kind { req.kind = kind }
        if let voice { req.voice = voice }
        if let model { req.model = model }
        if let speed { req.speed = speed }
        if let baseURL { req.baseURL = baseURL }
        if let apiKey { req.apiKey = apiKey }
        if let providerRef { req.providerRef = providerRef }
        if let enabled { req.enabled = enabled }
        let resp = await client.updateSpeechConfig(request: req, headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(PsmithError.from) ?? .missingPayload("speech config")
        }
        return PsmithSpeechConfig(from: msg.config)
    }

    public func delete() async throws {
        let resp = await client.deleteSpeechConfig(request: Psmith_V1_DeleteSpeechConfigRequest(), headers: [:])
        if let err = resp.error { throw PsmithError.from(err) }
    }

    public func test() async throws -> PsmithSpeechTestResult {
        let resp = await client.testSpeechConfig(request: Psmith_V1_TestSpeechConfigRequest(), headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(PsmithError.from) ?? .missingPayload("speech test")
        }
        return PsmithSpeechTestResult(
            ok: msg.ok, errorMessage: msg.errorMessage,
            latencyMs: msg.latencyMs, audioBytes: msg.audioBytes
        )
    }

    public func listKinds() async throws -> [String] {
        let resp = await client.listSpeechKinds(request: Psmith_V1_ListSpeechKindsRequest(), headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(PsmithError.from) ?? .missingPayload("speech kinds")
        }
        return msg.kinds
    }

    /// Streams synthesized PCM (s16le mono 24kHz) for one message via
    /// POST /tts. Chunks arrive as the server synthesizes segments, so
    /// playback can start on the first one. Throws PsmithError.rpc with
    /// a mapped code on a non-200 (412 = apple_local, synthesize
    /// on-device instead).
    public func synthesize(messageID: String) async throws -> AsyncThrowingStream<Data, Error> {
        var req = URLRequest(url: host.appendingPathComponent("tts"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try tokenStore.load(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(["message_id": messageID])

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw PsmithError.missingPayload("tts response")
        }
        guard http.statusCode == 200 else {
            var detail = "speech synthesis failed (\(http.statusCode))"
            // The error body is small JSON; drain a bounded amount.
            var collected = Data()
            for try await b in bytes {
                collected.append(b)
                if collected.count > 512 { break }
            }
            if let obj = try? JSONDecoder().decode([String: String].self, from: collected),
               let msg = obj["error"] {
                detail = msg
            }
            throw PsmithError.rpc(code: codeFor(status: http.statusCode), message: detail)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Hand off in ~16KB slabs; per-byte yields are
                        // pure overhead at 48KB/s.
                        if buffer.count >= 16 << 10 {
                            continuation.yield(buffer)
                            buffer = Data()
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func codeFor(status: Int) -> Code {
        switch status {
        case 401: return .unauthenticated
        case 404: return .notFound
        case 412: return .failedPrecondition
        case 422: return .invalidArgument
        // 502 relays a synthesis-provider failure; .internalError
        // renders as "Server error: <provider detail>" rather than
        // the misleading "Server unreachable".
        case 502: return .internalError
        default: return .unavailable
        }
    }
}
