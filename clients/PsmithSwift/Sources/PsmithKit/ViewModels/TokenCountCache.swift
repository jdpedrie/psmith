import Foundation

/// Process-wide cache for CountContextTokens results.
///
/// The server answers that RPC by rebuilding the full wire prefix from
/// the chain and shipping it to the provider's token-count endpoint —
/// cost linear in conversation size, paid on every conversation open
/// and terminal reload. The result is fully determined by the key
/// below, and the chain tip only moves on send / terminal /
/// branch-switch, so most opens are cache hits and skip the RPC (and
/// its full-history upload) entirely.
///
/// Mid-chain edits change content without moving the tip — the edit
/// and delete paths call `invalidate(contextID:)`.
@MainActor
public final class TokenCountCache {
    public static let shared = TokenCountCache()

    public struct Key: Hashable {
        public let contextID: String
        public let leafID: String
        public let providerID: String
        public let modelID: String

        public init(contextID: String, leafID: String, providerID: String, modelID: String) {
            self.contextID = contextID
            self.leafID = leafID
            self.providerID = providerID
            self.modelID = modelID
        }
    }

    private var store: [Key: (tokenCount: Int32, contextWindow: Int32)] = [:]
    /// Insertion order for the eviction sweep. Bounded so a long
    /// session across many conversations can't grow without limit.
    private var order: [Key] = []
    private let cap = 128

    private init() {}

    public func lookup(_ key: Key) -> (tokenCount: Int32, contextWindow: Int32)? {
        store[key]
    }

    public func store(_ key: Key, tokenCount: Int32, contextWindow: Int32) {
        if store[key] == nil {
            order.append(key)
            if order.count > cap {
                let evicted = order.removeFirst()
                store.removeValue(forKey: evicted)
            }
        }
        store[key] = (tokenCount, contextWindow)
    }

    /// Drop every entry for a context — content changed under an
    /// unchanged tip (message edit, message delete).
    public func invalidate(contextID: String) {
        let doomed = order.filter { $0.contextID == contextID }
        for key in doomed {
            store.removeValue(forKey: key)
        }
        order.removeAll { $0.contextID == contextID }
    }
}
