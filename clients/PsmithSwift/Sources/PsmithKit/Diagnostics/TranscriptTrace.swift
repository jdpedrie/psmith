import Foundation
import os

/// A step-by-step record of how a conversation's transcript changes: each
/// send, the stream's terminal and which path handled it, every load and
/// stale check, with the row counts and ids that decided them. Message text
/// never goes in, only ids and counts.
///
/// Bugs in this area happen between renders: a message that shows, then
/// vanishes until the conversation is reopened. A final screenshot can't
/// see that; this can. Every entry goes to the unified log under category
/// `TranscriptTrace`, so a device capture shows it:
///
///     log stream --predicate 'category == "TranscriptTrace"' --level info
///
/// and the last 2,000 entries stay in memory for tests to read.
@MainActor
public enum TranscriptTrace {
    private static let log = Logger(subsystem: "dev.jdpedrie.psmith", category: "TranscriptTrace")
    private static var ring: [String] = []
    private static let limit = 2_000
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Records one step for a conversation. Ids are shortened to their last
    /// eight characters: UUIDv7s share their leading timestamp, so the
    /// first eight tell rows apart poorly. A draft shows as "draft".
    public static func note(_ conversationID: String, _ event: String) {
        let conv = conversationID.isEmpty ? "draft" : String(conversationID.suffix(8))
        let line = "\(clock.string(from: Date())) \(conv) \(event)"
        log.notice("\(line, privacy: .public)")
        ring.append(line)
        if ring.count > limit { ring.removeFirst(ring.count - limit) }
    }

    /// The entries still in memory, oldest first.
    public static var lines: [String] { ring }

    public static func reset() { ring.removeAll() }

    /// A compact description of a transcript: row count and the last row's
    /// role and id.
    static func rows(_ messages: [PsmithMessage]) -> String {
        guard let last = messages.last else { return "rows=0" }
        return "rows=\(messages.count) last=\(last.role)/\(last.id.suffix(8))"
    }
}
