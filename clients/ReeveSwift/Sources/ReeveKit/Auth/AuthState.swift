import Foundation
import Observation

/// Three-state authentication posture.
///   - `.resolving`: app just launched; the on-disk token (if any) is still
///     being validated against the server via WhoAmI. Views render an
///     interstitial here — neither LoginView nor the authed shell, since
///     either would flash on transition.
///   - `.signedIn`: WhoAmI succeeded (or cached identity was restored under
///     a transport failure). `currentUser` is non-nil.
///   - `.signedOut`: bootstrap finished with no usable session. Login is
///     the right surface. Also reached by explicit Logout and by the
///     AuthInterceptor's 401-driven `flagNeedsReauth`.
public enum AuthPhase: Sendable, Hashable {
    case resolving
    case signedIn
    case signedOut
}

/// Observable wrapper around the current authentication posture.
///
/// Views switch on `phase` to render the right surface. `isAuthenticated`
/// is preserved as a derived flag for older call sites that just want a
/// "definitely signed in" check.
@Observable
@MainActor
public final class AuthState {
    public private(set) var phase: AuthPhase
    public private(set) var currentUser: ReeveUser?

    public var isAuthenticated: Bool { phase == .signedIn }

    public init(phase: AuthPhase = .resolving, currentUser: ReeveUser? = nil) {
        self.phase = phase
        self.currentUser = currentUser
    }

    /// Test-friendly bool initializer. Maps `true` → `.signedIn`,
    /// `false` → `.signedOut`. `.resolving` isn't reachable through this
    /// path — tests that want the interstitial state instantiate with
    /// `init(phase: .resolving)` directly.
    public convenience init(isAuthenticated: Bool, currentUser: ReeveUser? = nil) {
        self.init(
            phase: isAuthenticated ? .signedIn : .signedOut,
            currentUser: currentUser
        )
    }

    public func setAuthenticated(_ user: ReeveUser) {
        self.currentUser = user
        self.phase = .signedIn
    }

    public func clear() {
        self.currentUser = nil
        self.phase = .signedOut
    }

    nonisolated public func flagNeedsReauth() {
        Task { @MainActor in self.clear() }
    }
}

/// Plain Swift mirror of reeve.v1.User. Decoupled from generated types so
/// views don't import SwiftProtobuf.
public struct ReeveUser: Sendable, Hashable, Identifiable, Codable {
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
