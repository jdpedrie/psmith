import Foundation
import SwiftData

/// Opaque cache row: one record per (kind, id) pair, with the value
/// stored as a JSON-encoded Data blob. We deliberately avoid a
/// per-domain-type SwiftData schema — Spalt* domain types evolve as
/// the proto evolves, and re-running migrations against every shape
/// change is a maintenance tax we don't need just to get offline
/// reads. The blob shape lives next to the call site (the encoder
/// types are the cache's contract; mismatched decode = cache miss).
///
/// Eviction is per-row by `lastUsedAt`. `byteCount` is the encoded
/// blob size — used by the LRU walk so we don't have to re-measure
/// every row at eviction time.
@Model
public final class CacheEntry {
    /// Composite logical key: e.g. ("messages", contextID) or
    /// ("conversations", "all"). Stored as two columns rather than a
    /// single composite string so a kind-only query (`evict messages`,
    /// `purge providers`) is index-scannable.
    @Attribute(.unique) public var compositeKey: String

    public var kind: String
    public var id: String
    public var blob: Data
    public var lastUsedAt: Date
    public var byteCount: Int

    public init(kind: String, id: String, blob: Data, lastUsedAt: Date = Date()) {
        self.kind = kind
        self.id = id
        self.blob = blob
        self.byteCount = blob.count
        self.lastUsedAt = lastUsedAt
        self.compositeKey = Self.makeKey(kind: kind, id: id)
    }

    public static func makeKey(kind: String, id: String) -> String {
        kind + "/" + id
    }
}
