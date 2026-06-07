import Foundation
import Connect

public enum StreamEvent: Sendable {
    case chunk(ReeveChunk)
    case terminal(ReeveStreamRun)
    case failed(ReeveError)
}

public struct ReeveChunk: Sendable, Hashable {
    public let sequence: Int64
    public let type: ReeveChunkType
    public let payload: Data

    /// Convenience accessor for text/thinking deltas, both of which the
    /// server emits as `{"text":"…"}` (raw UTF-8 is the fallback for any
    /// future provider that emits unwrapped strings). Returns nil for
    /// other chunk types so callers don't have to guard themselves.
    public var textIfDelta: String? {
        guard type == .textDelta || type == .thinkingDelta else { return nil }
        return decodedText
    }

    /// Same JSON-or-raw-UTF-8 unwrap as `textIfDelta`, but type-agnostic.
    /// Used internally; exposed here so the consume-side view-model can
    /// route thinking deltas without re-implementing the unwrap.
    public var decodedText: String? {
        if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let s = obj["text"] as? String {
            return s
        }
        return String(data: payload, encoding: .utf8)
    }

    /// Decoded `{id, name, provider_opaque}` payload for ChunkToolUseStart;
    /// nil when this isn't a start chunk or the payload is malformed.
    public var toolUseStartInfo: ToolUseStartInfo? {
        guard type == .toolUseStart else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = obj["id"] as? String,
              let name = obj["name"] as? String
        else { return nil }
        return ToolUseStartInfo(
            id: id,
            name: name,
            providerOpaque: obj["provider_opaque"] as? String
        )
    }

    /// Decoded `{partial_json}` payload for ChunkToolUseDelta. Nil when this
    /// isn't a delta chunk or the payload is malformed.
    public var toolUseDeltaPartialJSON: String? {
        guard type == .toolUseDelta else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let s = obj["partial_json"] as? String
        else { return nil }
        return s
    }

    /// Decoded `{tool_use_id, output, error, elapsed_ms}` payload for
    /// ChunkToolResult; nil when this isn't a result chunk or the payload
    /// is malformed. `output` carries the plugin's return value as JSON
    /// bytes (re-serialised so consumers can pretty-print without re-parsing).
    public var toolResultInfo: ToolResultInfo? {
        guard type == .toolResult else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = obj["tool_use_id"] as? String
        else { return nil }
        var outputData = Data()
        if let outAny = obj["output"], !(outAny is NSNull) {
            outputData = (try? JSONSerialization.data(withJSONObject: outAny)) ?? Data()
        }
        let errString = obj["error"] as? String
        let elapsed = (obj["elapsed_ms"] as? NSNumber)?.int64Value ?? 0
        return ToolResultInfo(
            toolUseID: id,
            output: outputData,
            error: errString.flatMap { $0.isEmpty ? nil : $0 },
            elapsedMs: elapsed
        )
    }

    public struct ToolUseStartInfo: Sendable, Hashable {
        public let id: String
        public let name: String
        public let providerOpaque: String?
    }

    public struct ToolResultInfo: Sendable, Hashable {
        public let toolUseID: String
        public let output: Data
        public let error: String?
        public let elapsedMs: Int64
    }

    /// Decoded `{elicitation_id, message, requested_schema}` payload for
    /// ChunkElicit. Nil when this isn't an elicit chunk or the payload
    /// is malformed. `schemaJSON` carries the JSON Schema bytes verbatim
    /// so the renderer can introspect format hints (e.g. `password`).
    public var elicitInfo: ElicitInfo? {
        guard type == .elicit else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = obj["elicitation_id"] as? String
        else { return nil }
        let message = obj["message"] as? String ?? ""
        var schemaData = Data()
        if let schema = obj["requested_schema"] {
            schemaData = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data()
        }
        return ElicitInfo(id: id, message: message, schemaJSON: schemaData)
    }

    public struct ElicitInfo: Sendable, Hashable {
        public let id: String
        public let message: String
        public let schemaJSON: Data
    }

    /// Decoded `{call_id, tool_name, input, issued_at}` payload for a
    /// `ChunkDeviceToolUse`. Nil when this isn't a device-tool chunk
    /// or the payload is malformed. `inputJSON` carries the input
    /// bytes verbatim so the per-tool handler can decode them with
    /// its own Codable schema.
    public var deviceToolUseInfo: DeviceToolUseInfo? {
        guard type == .deviceToolUse else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let callID = obj["call_id"] as? String,
              let toolName = obj["tool_name"] as? String
        else { return nil }
        var inputData = Data()
        if let input = obj["input"] {
            inputData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
        }
        return DeviceToolUseInfo(callID: callID, toolName: toolName, inputJSON: inputData)
    }

    public struct DeviceToolUseInfo: Sendable, Hashable {
        public let callID: String
        public let toolName: String
        public let inputJSON: Data
    }
}

public enum ReeveChunkType: Sendable, Hashable {
    case textDelta, thinkingDelta
    case toolUseStart, toolUseDelta, toolUseEnd, toolResult
    case thinkingSignature
    case elicit
    case deviceToolUse
    case error, done, usage, unknown

    init(from p: Reeve_V1_ChunkType) {
        switch p {
        case .textDelta: self = .textDelta
        case .thinkingDelta: self = .thinkingDelta
        case .toolUseStart: self = .toolUseStart
        case .toolUseDelta: self = .toolUseDelta
        case .toolUseEnd: self = .toolUseEnd
        case .toolResult: self = .toolResult
        case .thinkingSignature: self = .thinkingSignature
        case .elicit: self = .elicit
        case .deviceToolUse: self = .deviceToolUse
        case .error: self = .error
        case .done: self = .done
        case .usage: self = .usage
        default: self = .unknown
        }
    }
}

public enum ReeveStreamStatus: Sendable, Hashable {
    case running, completed, errored, cancelled, interrupted, unknown

    init(from p: Reeve_V1_StreamRunStatus) {
        switch p {
        case .running: self = .running
        case .completed: self = .completed
        case .errored: self = .errored
        case .cancelled: self = .cancelled
        case .interrupted: self = .interrupted
        default: self = .unknown
        }
    }
}

public enum ReeveStreamPurpose: Sendable, Hashable {
    case unspecified
    case assistantResponse
    case compression

    init(from p: Reeve_V1_StreamRunPurpose) {
        switch p {
        case .assistantResponse: self = .assistantResponse
        case .compression:       self = .compression
        default:                 self = .unspecified
        }
    }
}

public struct ReeveStreamRun: Sendable, Hashable, Identifiable {
    public let id: String
    public let conversationID: String
    public let contextID: String
    public let status: ReeveStreamStatus
    public let purpose: ReeveStreamPurpose
    public let resultMessageID: String?
    public let resultContextID: String?

    public init(
        id: String,
        conversationID: String,
        contextID: String,
        status: ReeveStreamStatus,
        purpose: ReeveStreamPurpose = .unspecified,
        resultMessageID: String? = nil,
        resultContextID: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.contextID = contextID
        self.status = status
        self.purpose = purpose
        self.resultMessageID = resultMessageID
        self.resultContextID = resultContextID
    }
}

extension ReeveChunk {
    init(from p: Reeve_V1_Chunk) {
        self.init(sequence: p.sequence, type: ReeveChunkType(from: p.type), payload: p.payload)
    }
}

extension ReeveStreamRun {
    init(from p: Reeve_V1_StreamRun) {
        self.init(
            id: p.id,
            conversationID: p.conversationID,
            contextID: p.contextID,
            status: ReeveStreamStatus(from: p.status),
            purpose: ReeveStreamPurpose(from: p.purpose),
            resultMessageID: p.hasResultMessageID ? p.resultMessageID : nil,
            resultContextID: p.hasResultContextID ? p.resultContextID : nil
        )
    }
}

public final class StreamSubscriber: Sendable {
    private let client: Reeve_V1_StreamsServiceClientInterface

    public init(client: Reeve_V1_StreamsServiceClientInterface) {
        self.client = client
    }

    /// Subscribe to a stream_run starting at fromSequence (inclusive). Returns
    /// an `AsyncStream<StreamEvent>` that yields chunks, then exactly one
    /// terminal event, then finishes.
    ///
    /// Transparently retries on transport drop (URLSession timeout, network
    /// blip, app suspend/resume): if the underlying gRPC stream ends without
    /// having delivered a Terminal event, we re-subscribe from `lastSeen + 1`
    /// up to `maxRetries` times with exponential backoff. The server's
    /// Subscribe handler replays persisted chunks + the terminal event from
    /// DB, so the resume is correct-by-construction. Without this, a
    /// long-thinking turn could materialise server-side but never appear in
    /// iOS — the row sat in the DB until the next app launch / chain reload.
    public func subscribe(streamRunID: String, fromSequence: Int64 = 0) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                let maxRetries = 5
                var attempt = 0
                var nextSequence = fromSequence
                var sawTerminal = false

                while !Task.isCancelled, !sawTerminal {
                    let stream = self.client.subscribeStream(headers: [:])
                    do {
                        var req = Reeve_V1_SubscribeStreamRequest()
                        req.streamRunID = streamRunID
                        req.fromSequence = nextSequence
                        try stream.send(req)
                    } catch {
                        if attempt >= maxRetries {
                            continuation.yield(.failed(.rpc(code: .internalError, message: "send: \(error.localizedDescription)")))
                            continuation.finish()
                            return
                        }
                        await Self.backoff(attempt: attempt)
                        attempt += 1
                        continue
                    }

                    var endedNormally = false
                    for await result in stream.results() {
                        switch result {
                        case .headers:
                            continue
                        case .message(let resp):
                            switch resp.event {
                            case .chunk(let c):
                                let chunk = ReeveChunk(from: c)
                                if chunk.sequence >= nextSequence {
                                    nextSequence = chunk.sequence + 1
                                }
                                continuation.yield(.chunk(chunk))
                            case .terminal(let run):
                                sawTerminal = true
                                continuation.yield(.terminal(ReeveStreamRun(from: run)))
                            case .none:
                                continue
                            }
                        case .complete(let code, let error, _):
                            // OK with no Terminal seen → server cleanly
                            // closed without saying done. Treat as transport
                            // drop and retry from the next sequence.
                            // Non-OK is also a transport drop — retry.
                            if code == .ok {
                                endedNormally = true
                            } else if attempt >= maxRetries {
                                continuation.yield(.failed(.rpc(
                                    code: code,
                                    message: (error as? ConnectError)?.message ?? code.name
                                )))
                                continuation.finish()
                                return
                            }
                            // Bail out of the inner for-await; the outer
                            // while reconnects (or exits if sawTerminal).
                            break
                        }
                        // After a Terminal yield we want to exit the
                        // results loop so the outer while sees sawTerminal.
                        if sawTerminal { break }
                    }

                    stream.cancel()

                    if sawTerminal { break }
                    // Re-subscribe (transport drop or clean-close-without-
                    // terminal). Backoff scales with attempt count.
                    await Self.backoff(attempt: attempt)
                    attempt += 1
                    if attempt > maxRetries {
                        continuation.yield(.failed(.rpc(
                            code: .deadlineExceeded,
                            message: "stream subscription exhausted retries without terminal event"
                        )))
                        continuation.finish()
                        return
                    }
                    _ = endedNormally
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Exponential backoff between resubscribes. 250ms, 500ms, 1s, 2s, 4s.
    /// Capped so the user-visible retry latency stays under ~8s before the
    /// final failure surfaces.
    private static func backoff(attempt: Int) async {
        let baseMs: UInt64 = 250
        let factor: UInt64 = 1 << UInt64(min(attempt, 4))
        let waitMs = baseMs * factor
        try? await Task.sleep(nanoseconds: waitMs * 1_000_000)
    }

    public func cancel(streamRunID: String) async throws {
        var req = Reeve_V1_CancelStreamRequest()
        req.streamRunID = streamRunID
        let resp = await client.cancelStream(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ReeveError.from(err) }
    }

    /// Returns every currently-running stream_run the caller owns.
    /// Optional `conversationID` filter scopes to one conversation;
    /// nil returns every active run for the caller. Used by the
    /// iOS `StreamHub` to discover and adopt in-flight runs on app
    /// launch / conversations-list refresh / conversation entry.
    public func listActiveRuns(conversationID: String? = nil) async throws -> [ReeveStreamRun] {
        var req = Reeve_V1_ListActiveRunsRequest()
        if let conversationID, !conversationID.isEmpty {
            req.conversationID = conversationID
        }
        let resp = await client.listActiveRuns(request: req, headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(ReeveError.from) ?? ReeveError.missingPayload("list active runs")
        }
        return msg.runs.map(ReeveStreamRun.init(from:))
    }
}
