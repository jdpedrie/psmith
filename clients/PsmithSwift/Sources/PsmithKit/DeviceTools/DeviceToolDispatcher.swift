import Foundation
import os.log

/// Closure each device-tool handler exposes: takes the raw input
/// JSON bytes (whatever the model sent), returns the result JSON
/// the model should see on the next round.
///
/// Handlers throw to signal a tool-level failure ("calendar access
/// denied", "note doesn't exist"). The dispatcher turns thrown
/// errors into the `error` field of the POSTed response, which the
/// server-side broker turns into a tool error the model sees.
public typealias DeviceToolHandler = @Sendable (_ inputJSON: Data) async throws -> Data

/// Per-app registry of device-tool handlers. iOS / Mac code calls
/// `register(name:handler:)` from each capability module
/// (CalendarTools, ObsidianTools, …) at app bootstrap; the
/// dispatcher reads from here to look up the handler for an
/// incoming `ChunkDeviceToolUse`.
///
/// Thread-safe; `register` is intended to be called only during
/// bootstrap but tolerates late registration in tests.
public final class DeviceToolRegistry: @unchecked Sendable {
    public static let shared = DeviceToolRegistry()

    private let lock = NSLock()
    private var handlers: [String: DeviceToolHandler] = [:]

    public init() {}

    public func register(name: String, handler: @escaping DeviceToolHandler) {
        lock.lock(); defer { lock.unlock() }
        handlers[name] = handler
    }

    /// Drop a handler. Used by capabilities that come and go at
    /// runtime — e.g. Obsidian, which only advertises its tools
    /// when the user has bookmarked a vault folder.
    public func unregister(name: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: name)
    }

    public func handler(for name: String) -> DeviceToolHandler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[name]
    }

    /// Snapshot of registered tool names. Used by the dispatcher
    /// to call RegisterCapabilities on connect.
    public func registeredNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(handlers.keys).sorted()
    }
}

/// Watches stream chunks for `deviceToolUse` events, dispatches each
/// to the matching handler from `DeviceToolRegistry`, and POSTs the
/// result back via `DeviceToolsRepository`. One instance per
/// connected PsmithClient — typically held on the AppModel.
///
/// Lifecycle:
///
///   1. App boots, each capability module (CalendarTools etc.)
///      registers handlers into `DeviceToolRegistry.shared`.
///   2. AppModel constructs the dispatcher with the client + a
///      PsmithClient handle.
///   3. `start()` calls RegisterCapabilities with the registered
///      names, then begins observing chunks (delivered by whichever
///      conversation observer the app wires — typically StreamHub).
///   4. For each `deviceToolUse` chunk, look up the handler, run it
///      off-actor, POST the result.
///
/// The dispatcher is NOT a stream subscriber itself — the existing
/// StreamHub already manages subscriptions per conversation. The
/// app calls `handleChunk(_:in:)` from its hub-observation glue.
@MainActor
public final class DeviceToolDispatcher {
    private let client: PsmithClient
    private let registry: DeviceToolRegistry
    private let log = Logger(subsystem: "dev.jdpedrie.psmith", category: "DeviceTools")

    public init(client: PsmithClient, registry: DeviceToolRegistry = .shared) {
        self.client = client
        self.registry = registry
    }

    /// Called once per StreamSubscriber connection (which in
    /// practice is once per app launch — the subscriber lifetime
    /// spans the session). Tells the server what tools this
    /// device can fulfill right now so the model's tool list is
    /// filtered to match.
    ///
    /// `attributes` rides along as metadata the server can use for
    /// gating (`os`, `os_version`, `app_version`, …).
    public func registerWithServer(attributes: [String: String] = [:]) async {
        let names = registry.registeredNames()
        do {
            try await client.deviceTools.registerCapabilities(
                supportedToolNames: names,
                attributes: attributes
            )
            // Notice level so this lands in persistent logs — without
            // confirmation of THIS line, the server's tool-filter
            // can't know what the device offers. The bullets list
            // every name we sent so a missing tool stands out.
            let joined = names.joined(separator: ",")
            log.notice("registerCapabilities OK: count=\(names.count, privacy: .public) names=[\(joined, privacy: .public)]")
        } catch {
            log.error("registerCapabilities failed: \(String(describing: error))")
        }
    }

    /// Hook the app's stream observer calls for every chunk it
    /// sees. Non-deviceToolUse chunks are ignored; deviceToolUse
    /// chunks fire the matching handler in a detached Task and
    /// POST the result. Each call is independent — multiple
    /// concurrent device-tool calls in the same run interleave
    /// freely.
    public func handleChunk(_ chunk: PsmithChunk, conversationID: String) {
        guard chunk.type == .deviceToolUse,
              let info = chunk.deviceToolUseInfo
        else { return }

        // Notice-level so it survives the default os_log filter — the
        // "did the chunk even reach the device?" question is the
        // first thing we ask when a tool call times out at the broker.
        log.notice("dispatcher: received chunk for tool=\(info.toolName, privacy: .public) call=\(info.callID, privacy: .public)")

        let handler = registry.handler(for: info.toolName)
        // Move off the main actor for the handler invocation +
        // result post — handlers may do heavy work (geocoding,
        // file IO, full-vault search).
        Task.detached(priority: .userInitiated) { [client, log] in
            let resp: (output: Data?, error: String?) = await runHandler(
                handler: handler,
                info: info,
                log: log
            )
            do {
                try await client.deviceTools.respond(
                    conversationID: conversationID,
                    callID: info.callID,
                    output: resp.output,
                    errorMessage: resp.error
                )
            } catch {
                // Posting the result back failed — the server's
                // broker will time out the waiting tool dispatch
                // after 60s. Log so the issue is surfaced; nothing
                // more we can do client-side.
                log.error("device-tool respond failed for \(info.toolName): \(String(describing: error))")
            }
        }
    }
}

/// Runs a single handler invocation with structured error mapping.
/// Lifted out of the dispatcher's Task so the file's API surface
/// stays small.
private func runHandler(
    handler: DeviceToolHandler?,
    info: PsmithChunk.DeviceToolUseInfo,
    log: Logger
) async -> (output: Data?, error: String?) {
    guard let handler else {
        log.warning("no handler registered for device tool '\(info.toolName)'")
        return (nil, "no handler registered for tool '\(info.toolName)'")
    }
    do {
        let out = try await handler(info.inputJSON)
        return (out, nil)
    } catch {
        log.warning("device tool '\(info.toolName)' failed: \(String(describing: error))")
        return (nil, String(describing: error))
    }
}
