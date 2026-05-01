import Foundation
import Observation

/// Observable wrapper around the current authentication posture.
///
/// `isAuthenticated` flips to true after a successful Login (token saved),
/// false after Logout or a 401-driven `flagNeedsReauth`. Views observe this
/// via `@Observable` to route between Login and Main.
@Observable
@MainActor
public final class AuthState {
    public private(set) var isAuthenticated: Bool
    public private(set) var currentUser: ReeveUser?

    public init(isAuthenticated: Bool = false, currentUser: ReeveUser? = nil) {
        self.isAuthenticated = isAuthenticated
        self.currentUser = currentUser
    }

    public func setAuthenticated(_ user: ReeveUser) {
        self.currentUser = user
        self.isAuthenticated = true
    }

    public func clear() {
        self.currentUser = nil
        self.isAuthenticated = false
    }

    nonisolated public func flagNeedsReauth() {
        Task { @MainActor in self.clear() }
    }
}

/// Plain Swift mirror of clark.v1.User. Decoupled from generated types so
/// views don't import SwiftProtobuf.
public struct ReeveUser: Sendable, Hashable, Identifiable {
    public let id: String
    public let username: String
    public let displayName: String?
    public let isAdmin: Bool

    public init(id: String, username: String, displayName: String?, isAdmin: Bool) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.isAdmin = isAdmin
    }
}
