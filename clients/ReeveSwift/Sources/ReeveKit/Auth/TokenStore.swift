import Foundation
import Security

public protocol TokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}

public enum TokenStoreError: Error {
    case unhandled(OSStatus)
    case encoding
}

/// Keychain-backed token store. Uses kSecAttrAccessibleAfterFirstUnlock so the
/// token survives reboots but isn't accessible when the device is locked first
/// boot — matches the doc'd posture in docs/clients/client-spec.md.
public final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(service: String = "reeve.session", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.encoding
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.unhandled(status)
        }
    }

    public func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw TokenStoreError.encoding }
        try clear()
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw TokenStoreError.unhandled(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unhandled(status)
        }
    }
}

/// File-backed token store. Writes a single 0600 file under
/// ~/Library/Application Support/<directoryName>/<filename>.
///
/// Use this when the app isn't code-signed with a stable identity — Keychain
/// re-prompts for password on every signature change (i.e. every ad-hoc rebuild),
/// which is intolerable during development. The file lives in the user's home
/// directory and is owner-only readable; for a self-hosted personal tool it's
/// no more exposed than SSH keys or `~/.config/*`.
///
/// On iOS the Application Support directory is sandboxed per-app, so the
/// posix-permissions step is a no-op but still safe.
public final class FileTokenStore: TokenStore {
    private let url: URL

    public init(directoryName: String = "ReeveMac", filename: String = "session.token") throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename, isDirectory: false)
    }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.encoding
        }
        return str.isEmpty ? nil : str
    }

    public func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw TokenStoreError.encoding }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// In-memory token store for tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(initial: String? = nil) {
        self.token = initial
    }

    public func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func save(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        self.token = nil
    }
}
