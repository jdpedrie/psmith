import Testing
import SwiftUI
@testable import ReeveMac
import ReeveKit
import SnapshotHarness

/// LoginView snapshots. Only the empty / default state is covered by Layer 2.
///
/// The typing / submitting / error variants live behind `@State private`
/// fields (`username`, `password`, `inFlight`, `errorMessage`) that LoginView
/// doesn't expose through any public init or environment seam. Reaching them
/// would require either:
///   - adding a test-only init parameterised on those fields (production
///     surgery just for snapshots), or
///   - simulating the full login RPC against the harness's null host (which
///     hangs forever — there's no real server on `snapshot.invalid`).
///
/// Both options trade a real production-code change for snapshots that
/// would mostly catch typography drift on a single TextField. Punting on
/// them is the right call until Layer 3 (XCUITest) lands and the same
/// states fall out of an end-to-end "user types into LoginView" test.
@MainActor
struct LoginViewSnapshots {

    @Test
    func empty() {
        let env = SnapshotEnvironment.standard()
        let view = ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { LoginView() }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    // SKIP: typing — needs `@State private` exposure on LoginView. TODO: Layer 3 (XCUITest).
    // SKIP: submitting — same. TODO: Layer 3 (XCUITest).
    // SKIP: error — same. TODO: Layer 3 (XCUITest).
}
