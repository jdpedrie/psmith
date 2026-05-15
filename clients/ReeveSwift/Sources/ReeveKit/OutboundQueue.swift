import Foundation
import Observation

/// One pending SendMessage request that hasn't been delivered to
/// the server yet — typically because connectivity dropped between
/// the user tapping Send and the RPC firing. Holds the verbatim
/// args the repo needs so a drain attempt is identical to the
/// original send. Codable for UserDefaults persistence across
/// relaunches.
public struct OutboundQueueEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let conversationID: String
    public let content: String
    public let providerID: String?
    public let modelID: String?
    public let parentMessageID: String?
    public let attachmentFileIDs: [String]
    public let deviceFacts: [ReeveDeviceFact]
    public let queuedAt: Date

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        content: String,
        providerID: String?,
        modelID: String?,
        parentMessageID: String?,
        attachmentFileIDs: [String],
        deviceFacts: [ReeveDeviceFact],
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.content = content
        self.providerID = providerID
        self.modelID = modelID
        self.parentMessageID = parentMessageID
        self.attachmentFileIDs = attachmentFileIDs
        self.deviceFacts = deviceFacts
        self.queuedAt = queuedAt
    }
}

extension ReeveDeviceFact: Codable {
    enum CodingKeys: String, CodingKey { case key, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .key)
        guard let key = ReeveDeviceFactKey(rawString: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .key, in: c,
                debugDescription: "unknown ReeveDeviceFactKey: \(raw)"
            )
        }
        let value = try c.decode(String.self, forKey: .value)
        self.init(key: key, value: value)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key.rawString, forKey: .key)
        try c.encode(value, forKey: .value)
    }
}

extension ReeveDeviceFactKey {
    /// Stable string id for persistence (UserDefaults JSON). Decoupled
    /// from `case` names so renaming a case doesn't invalidate
    /// already-queued entries on disk.
    var rawString: String {
        switch self {
        case .locale: return "locale"
        case .timezone: return "timezone"
        case .platform: return "platform"
        case .locationCity: return "location_city"
        case .locationCoords: return "location_coords"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "locale": self = .locale
        case "timezone": self = .timezone
        case "platform": self = .platform
        case "location_city": self = .locationCity
        case "location_coords": self = .locationCoords
        default: return nil
        }
    }
}

/// App-wide outbound send queue. Holds `SendMessage` requests
/// that couldn't reach the server (typically because connectivity
/// flipped between the user tapping Send and the RPC firing) and
/// drains them once the server is reachable.
///
/// Persisted to UserDefaults as a JSON array. Small messages stay
/// well under the 1MB-per-key envelope iOS allows; if the queue
/// ever grows large enough to matter we'll move to sqlite, but
/// the realistic ceiling (a handful of unsent turns from a flaky
/// drive) sits comfortably here.
///
/// Drain behavior: walks entries in order, calls
/// `client.conversations.sendMessage` for each, removes on
/// success. On the first failure (network error, RPC error)
/// drain stops and the remaining entries stay queued for the
/// next attempt — preserves user-typed order and avoids
/// reordering optimistically.
@Observable
@MainActor
public final class OutboundQueue {
    public private(set) var entries: [OutboundQueueEntry] = []

    /// Notification fired after every queue mutation (enqueue,
    /// drain success, manual remove). ConnectivityMonitor
    /// subscribes to flip its backoff cadence the moment the
    /// queue size changes.
    public static let didChangeNotification = Notification.Name("dev.jdpedrie.reeve.OutboundQueue.didChange")

    private let userDefaults: UserDefaults
    private let storageKey: String
    /// Set to true while a drain is in flight so concurrent
    /// triggers (connectivity flip + manual retry + scenePhase)
    /// don't fire overlapping drains.
    private var draining: Bool = false

    public init(userDefaults: UserDefaults = .standard, storageKey: String = "reeve.outboundQueue") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.entries = Self.load(from: userDefaults, key: storageKey)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Returns all queued entries scoped to one conversation —
    /// the ConversationViewModel uses this to render queued
    /// bubbles in chronological order alongside settled history.
    public func entries(forConversation conversationID: String) -> [OutboundQueueEntry] {
        entries.filter { $0.conversationID == conversationID }
    }

    public func enqueue(_ entry: OutboundQueueEntry) {
        entries.append(entry)
        persist()
    }

    /// Walk the queue, send each entry via the repo, remove on
    /// success. Stops on the first failure so partial-drain
    /// preserves order. Returns the (sent, failed) pair so the
    /// caller can decide whether to keep retrying.
    public func drain(client: ReeveClient) async -> (sent: [OutboundQueueEntry], failed: OutboundQueueEntry?) {
        if draining { return ([], nil) }
        draining = true
        defer { draining = false }

        var sent: [OutboundQueueEntry] = []
        // Snapshot at start so concurrent enqueues during drain
        // wait for the next tick — drain() is FIFO over what was
        // already queued.
        let snapshot = entries
        for entry in snapshot {
            do {
                _ = try await client.conversations.sendMessage(
                    conversationID: entry.conversationID,
                    content: entry.content,
                    parentMessageID: entry.parentMessageID,
                    providerID: entry.providerID,
                    modelID: entry.modelID,
                    attachmentFileIDs: entry.attachmentFileIDs,
                    deviceFacts: entry.deviceFacts
                )
                entries.removeAll { $0.id == entry.id }
                persist()
                sent.append(entry)
            } catch {
                // Stop draining on first failure. The next
                // ConnectivityMonitor tick (or a manual retry)
                // picks up where we left off.
                return (sent, entry)
            }
        }
        return (sent, nil)
    }

    /// Drop one entry — used when the user explicitly cancels a
    /// queued message before it sends.
    public func remove(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            userDefaults.set(data, forKey: storageKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [OutboundQueueEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([OutboundQueueEntry].self, from: data)) ?? []
    }
}
