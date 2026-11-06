import Foundation
import Network

/// Accepts TCP connections and never answers them: what an asleep or
/// half-reachable server looks like from the client. Requests against
/// it hang until something times them out, which is the behaviour the
/// launch-path deadlines exist for. (A closed port fails fast and
/// can't exercise them.)
public final class SilentServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "SilentServer")

    public init() {}

    public func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // Hold the connection open; read nothing, send nothing.
            self.connections.append(conn)
            conn.start(queue: self.queue)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard case .ready = listener.state, let p = listener.port else {
            throw NSError(domain: "SilentServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to bind: state=\(listener.state)"
            ])
        }
        port = p.rawValue
    }

    public func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
        listener?.cancel()
        listener = nil
    }

    deinit { stop() }
}
