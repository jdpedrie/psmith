import Foundation
import Network

/// Minimal embedded mock OpenAI-compatible provider. Listens on an ephemeral
/// localhost port and answers two endpoints:
///
///   GET  /v1/models             — `{"data":[{"id":"fake-model-1","object":"model"}]}`
///   POST /v1/chat/completions   — SSE stream emitting one delta + `[DONE]`
///
/// Construct one per test. Call `start()` to bind, `stop()` (or `deinit`)
/// to tear down. Tests register a Reeve provider whose `base_url` points
/// at `baseURL` to exercise discovery + streaming without a real LLM.
///
/// Records every received `/v1/chat/completions` body so tests that need to
/// inspect the request payload (e.g., plugin pipeline tests checking history
/// transformation) can read back the latest body via `lastChatRequest()`.
///
/// Optionally accepts a custom assistant reply (`replyText`) — useful for
/// tests that depend on the assistant emitting specific tokens (e.g., a
/// `<choices>...</choices>` block for the lettered_choices plugin pipeline
/// test).
///
/// Note: deliberately written against `Network.framework`'s NWListener
/// rather than pulling in NIO — it's already in the SDK and avoids growing
/// the test target's dependency surface.
public final class FakeProvider: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "FakeProvider")
    private let modelsJSON: Data
    private let modelID: String

    private let lock = NSLock()
    private var requestBodies: [Data] = []
    private var replyText: String

    public init(modelID: String = "fake-model-1", replyText: String = "hello") {
        self.modelID = modelID
        self.replyText = replyText
        let json = "{\"data\":[{\"id\":\"\(modelID)\",\"object\":\"model\",\"created\":0,\"owned_by\":\"fake\"}],\"object\":\"list\"}"
        self.modelsJSON = Data(json.utf8)
    }

    /// Override the assistant's reply text mid-test. Subsequent
    /// /v1/chat/completions calls return this string instead of "hello".
    public func setReplyText(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        replyText = text
    }

    /// Snapshot of all recorded /v1/chat/completions request bodies in the
    /// order they were received.
    public func recordedChatRequests() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return requestBodies
    }

    /// Most recent chat-completions request body, or nil if none.
    public func lastChatRequest() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return requestBodies.last
    }

    /// Discard all recorded request bodies (e.g., to scope a recording to a
    /// single follow-up turn after seeded history was already in place).
    public func resetRecording() {
        lock.lock(); defer { lock.unlock() }
        requestBodies.removeAll()
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.handle(conn: conn)
        }

        let started = DispatchSemaphore(value: 0)
        let errorBox = StartupErrorBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.signal()
            case .failed(let err):
                errorBox.set(err)
                started.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 5.0)
        if let err = errorBox.get() { throw err }
        guard case .ready = listener.state, let p = listener.port else {
            throw NSError(domain: "FakeProvider", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to bind: state=\(listener.state)"
            ])
        }
        self.port = p.rawValue
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    deinit { stop() }

    // MARK: - Connection handling

    private func handle(conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn: conn, accumulated: Data())
    }

    private func receiveRequest(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                conn.cancel()
                return
            }
            var buf = accumulated
            if let data { buf.append(data) }

            // Look for the end of headers ("\r\n\r\n"). HTTP/1.1; we don't
            // bother with chunked uploads — chat-completions bodies are JSON
            // and small enough to come in one or two reads.
            guard let headersEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    conn.cancel()
                    return
                }
                self.receiveRequest(conn: conn, accumulated: buf)
                return
            }

            let headerBlock = String(data: buf[..<headersEnd.lowerBound], encoding: .utf8) ?? ""
            let lines = headerBlock.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first else {
                conn.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                conn.cancel()
                return
            }
            let method = String(parts[0])
            let path = String(parts[1])

            // Find Content-Length so we can read the full body when present
            // (chat-completions POSTs always carry one). Header parsing is
            // case-insensitive per RFC.
            var contentLength = 0
            for line in lines.dropFirst() {
                let l = String(line)
                let lower = l.lowercased()
                if lower.hasPrefix("content-length:") {
                    let after = l.dropFirst("content-length:".count)
                    contentLength = Int(after.trimmingCharacters(in: .whitespaces)) ?? 0
                    break
                }
            }

            let bodyStart = headersEnd.upperBound
            let bodySoFar = buf.count - bodyStart
            if contentLength > 0 && bodySoFar < contentLength {
                self.receiveBody(conn: conn, accumulated: buf, bodyStart: bodyStart,
                                 contentLength: contentLength, method: method, path: path)
                return
            }

            let body = (contentLength > 0)
                ? buf.subdata(in: bodyStart..<(bodyStart + contentLength))
                : Data()
            self.route(conn: conn, method: method, path: path, body: body)
        }
    }

    private func receiveBody(
        conn: NWConnection,
        accumulated: Data,
        bodyStart: Int,
        contentLength: Int,
        method: String,
        path: String
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buf = accumulated
            if let data { buf.append(data) }
            let bodySoFar = buf.count - bodyStart
            if bodySoFar < contentLength {
                if isComplete { conn.cancel(); return }
                self.receiveBody(conn: conn, accumulated: buf, bodyStart: bodyStart,
                                 contentLength: contentLength, method: method, path: path)
                return
            }
            let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
            self.route(conn: conn, method: method, path: path, body: body)
        }
    }

    private func route(conn: NWConnection, method: String, path: String, body: Data) {
        if method == "GET" && path.hasPrefix("/v1/models") {
            self.respondJSON(conn: conn, status: "200 OK", body: self.modelsJSON)
            return
        }
        if method == "POST" && path.hasPrefix("/v1/chat/completions") {
            self.lock.lock()
            self.requestBodies.append(body)
            let reply = self.replyText
            self.lock.unlock()
            self.respondSSE(conn: conn, replyText: reply)
            return
        }
        let body = Data("{\"error\":\"not found\"}".utf8)
        self.respondJSON(conn: conn, status: "404 Not Found", body: body)
    }

    private func respondJSON(conn: NWConnection, status: String, body: Data) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respondSSE(conn: NWConnection, replyText: String) {
        var headers = "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: text/event-stream\r\n"
        headers += "Cache-Control: no-cache\r\n"
        headers += "Connection: close\r\n\r\n"

        // JSON-escape the user-supplied reply so it survives embedding into
        // the SSE chunk payload. Plus a final usage-bearing chunk that real
        // OpenAI-compatible providers emit so cost computation downstream
        // sees deterministic non-zero token counts.
        let escapedReply = jsonEscape(replyText)
        let deltaPayload = "{\"id\":\"fake-1\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"\(modelID)\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(escapedReply)\"}}]}"
        let usagePayload = "{\"id\":\"fake-1\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"\(modelID)\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
        let chunk1 = "data: " + deltaPayload + "\n\n"
        let chunk2 = "data: " + usagePayload + "\n\n"
        let done = "data: [DONE]\n\n"

        var stream = Data(headers.utf8)
        stream.append(Data(chunk1.utf8))
        stream.append(Data(chunk2.utf8))
        stream.append(Data(done.utf8))
        conn.send(content: stream, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// Minimal JSON string escaper for the SSE payload — handles backslashes,
    /// quotes, and the control chars we'd plausibly embed (newlines, tabs).
    private func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.asciiValue.map({ $0 < 0x20 }) ?? false {
                    out += String(format: "\\u%04x", ch.asciiValue!)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }
}

/// Box for the error captured from the NWListener state-update handler.
/// Threadsafe + Sendable so the closure can mutate without tripping the
/// concurrency checker.
private final class StartupErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var err: Error?
    func set(_ e: Error) { lock.lock(); defer { lock.unlock() }; err = e }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return err }
}
