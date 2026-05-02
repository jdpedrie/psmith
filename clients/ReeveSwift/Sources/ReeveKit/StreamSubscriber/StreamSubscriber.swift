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
}

public enum ReeveChunkType: Sendable, Hashable {
    case textDelta, thinkingDelta
    case toolUseStart, toolUseDelta, toolUseEnd, toolResult
    case thinkingSignature
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

public struct ReeveStreamRun: Sendable, Hashable, Identifiable {
    public let id: String
    public let conversationID: String
    public let contextID: String
    public let status: ReeveStreamStatus
    public let resultMessageID: String?
    public let resultContextID: String?
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
    /// terminal event, then finishes. Transient stream drops aren't handled
    /// yet — see Open Threads in clients/architecture.md (StreamSubscriber
    /// resilience). For now the consumer must restart the subscription if it
    /// ends without a terminal event.
    public func subscribe(streamRunID: String, fromSequence: Int64 = 0) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let stream = client.subscribeStream(headers: [:])
            let task = Task {
                do {
                    var req = Reeve_V1_SubscribeStreamRequest()
                    req.streamRunID = streamRunID
                    req.fromSequence = fromSequence
                    try stream.send(req)
                } catch {
                    continuation.yield(.failed(.rpc(code: .internalError, message: "send: \(error.localizedDescription)")))
                    continuation.finish()
                    return
                }

                for await result in stream.results() {
                    switch result {
                    case .headers:
                        continue
                    case .message(let resp):
                        switch resp.event {
                        case .chunk(let c):
                            continuation.yield(.chunk(ReeveChunk(from: c)))
                        case .terminal(let run):
                            continuation.yield(.terminal(ReeveStreamRun(from: run)))
                        case .none:
                            continue
                        }
                    case .complete(let code, let error, _):
                        if code != .ok {
                            continuation.yield(.failed(.rpc(
                                code: code,
                                message: (error as? ConnectError)?.message ?? code.name
                            )))
                        }
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                stream.cancel()
            }
        }
    }

    public func cancel(streamRunID: String) async throws {
        var req = Reeve_V1_CancelStreamRequest()
        req.streamRunID = streamRunID
        let resp = await client.cancelStream(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ReeveError.from(err) }
    }
}
