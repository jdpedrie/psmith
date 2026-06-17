import Foundation
import SwiftData

/// SwiftData-backed read-through cache for Spalt* domain types.
///
/// Conceptually a key/value store: callers `set` a `Codable` value
/// under a `(kind, id)` pair, `get` it back later. The cache is
/// strictly write-through — repositories that successfully fetch
/// from the server upsert the result here so the next launch (or
/// the next offline read) finds the data ready.
///
/// **Cap & eviction.** A user-tunable cap (default 100 MB, see
/// `CachePreferences.cacheCapBytes`) bounds the total blob size.
/// On every successful insert that pushes the cache past the cap,
/// the oldest rows by `lastUsedAt` are dropped until under cap.
/// Eviction is opportunistic — we don't run a periodic sweeper.
///
/// **Concurrency.** Wrapped as an actor so mutations from arbitrary
/// repository tasks serialize without a mutex. SwiftData's
/// `ModelContainer` is itself thread-safe; the actor wrapping is
/// for the byte-count + eviction bookkeeping, which would race
/// without a single owner.
public actor SpaltCache {
    private let container: ModelContainer
    private let context: ModelContext

    /// Resolved at init from the host app's bundle ID + a fixed
    /// directory under Application Support. Surfaced so settings
    /// UI can render "Database at …" / open in Files.
    public let storeURL: URL

    /// Default location, used by the convenience `init`. Wrapped in
    /// a function (not a property) so test instantiation can pick a
    /// temp path without dragging the file-system access into init.
    public static func defaultStoreURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("Spalt", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.sqlite", isDirectory: false)
    }

    /// Initialize against an explicit store URL. Public so tests
    /// can spin up a fresh cache in a temp dir.
    public init(storeURL: URL) throws {
        self.storeURL = storeURL
        let schema = Schema([CacheEntry.self])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: config)
        self.container = container
        self.context = ModelContext(container)
    }

    /// Convenience init using the default store URL. Throws on
    /// SwiftData container creation failure (corrupt store, disk
    /// full, etc.) — caller decides whether to nuke the file or
    /// run cacheless.
    public init() throws {
        try self.init(storeURL: try Self.defaultStoreURL())
    }

    // MARK: - Set / Get

    /// Encode `value` and upsert into the cache at `(kind, id)`. Bumps
    /// `lastUsedAt` to now even on update (writes count as a use —
    /// the recently-written entry is also the most likely to be
    /// read). Triggers eviction if the cache crosses `capBytes`.
    public func set<T: Encodable>(_ value: T, kind: String, id: String, capBytes: Int) throws {
        let blob = try JSONEncoder().encode(value)
        let key = CacheEntry.makeKey(kind: kind, id: id)
        let descriptor = FetchDescriptor<CacheEntry>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.blob = blob
            existing.byteCount = blob.count
            existing.lastUsedAt = Date()
        } else {
            context.insert(CacheEntry(kind: kind, id: id, blob: blob))
        }
        try context.save()
        try evictIfOverCap(capBytes)
    }

    /// Decode the value previously set under `(kind, id)`. Returns
    /// nil for cache misses (no entry, decode failure, type
    /// mismatch). On hit, bumps `lastUsedAt` so the entry survives
    /// LRU eviction longer — reading is a use.
    public func get<T: Decodable>(_ type: T.Type, kind: String, id: String) -> T? {
        let key = CacheEntry.makeKey(kind: kind, id: id)
        let descriptor = FetchDescriptor<CacheEntry>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: entry.blob) else { return nil }
        entry.lastUsedAt = Date()
        try? context.save()
        return value
    }

    // MARK: - Eviction + size

    public func totalBytes() -> Int {
        let descriptor = FetchDescriptor<CacheEntry>()
        guard let rows = try? context.fetch(descriptor) else { return 0 }
        return rows.reduce(0) { $0 + $1.byteCount }
    }

    /// Drop oldest-by-lastUsedAt rows until the total is under
    /// `capBytes`. No-op when already under cap. Public so the
    /// settings screen's "lower the cap" affordance can immediately
    /// reclaim space when the user moves the slider down.
    public func evictIfOverCap(_ capBytes: Int) throws {
        var total = totalBytes()
        if total <= capBytes { return }
        let descriptor = FetchDescriptor<CacheEntry>(
            sortBy: [SortDescriptor(\CacheEntry.lastUsedAt, order: .forward)]
        )
        let rows = try context.fetch(descriptor)
        for row in rows {
            if total <= capBytes { break }
            total -= row.byteCount
            context.delete(row)
        }
        try context.save()
    }

    /// Wipes every cached entry. Used by the "Clear cache" button
    /// in General settings and on user logout (to make sure another
    /// user logging into the same device doesn't see leftover data).
    public func clear() throws {
        let descriptor = FetchDescriptor<CacheEntry>()
        let rows = try context.fetch(descriptor)
        for r in rows { context.delete(r) }
        try context.save()
    }
}

// MARK: - Cache kind constants

/// Stable string identifiers for the cached domains. Centralised so
/// the wire-up sites don't sprout typos that silently miss the
/// cache. Picked to be short — they're written into every row.
public enum CacheKind {
    public static let conversationsList = "conversationsList"
    public static let conversation = "conversation"
    public static let activeContext = "activeContext"
    public static let contextsByConversation = "contextsByConversation"
    public static let messagesByContext = "messagesByContext"
    public static let providers = "providers"
    public static let availableModels = "availableModels"
    public static let profiles = "profiles"
    /// Cached identity from the most recent successful WhoAmI. Used
    /// by restoreSession to land the user inside the app even when
    /// the server is unreachable on launch (otherwise they'd be
    /// bounced to Login and never see their cached conversations).
    public static let currentUser = "currentUser"
}
