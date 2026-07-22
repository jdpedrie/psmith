import Foundation
import Testing
@testable import PsmithKit

/// Pure unit tests for `Account` — no UserDefaults, no network.
/// Covers the display-label fallback + Codable round-trip.
@Suite("Account")
struct AccountTests {

    @Test("resolvedDisplayLabel uses displayLabel when set")
    func resolvedUsesDisplayLabel() {
        let a = Account(
            host: URL(string: "https://psmith.example.com:8080")!,
            username: "jdp",
            displayLabel: "Work"
        )
        #expect(a.resolvedDisplayLabel == "Work")
    }

    @Test("resolvedDisplayLabel falls back to username · host when label nil")
    func resolvedFallsBackWhenNil() {
        let a = Account(
            host: URL(string: "https://psmith.example.com:8080")!,
            username: "jdp",
            displayLabel: nil
        )
        #expect(a.resolvedDisplayLabel == "jdp · psmith.example.com")
    }

    @Test("resolvedDisplayLabel falls back to username · host when label empty")
    func resolvedFallsBackWhenEmpty() {
        let a = Account(
            host: URL(string: "https://psmith.example.com:8080")!,
            username: "jdp",
            displayLabel: ""
        )
        #expect(a.resolvedDisplayLabel == "jdp · psmith.example.com")
    }

    @Test("resolvedDisplayLabel uses absoluteString when URL has no host")
    func resolvedNoHostFallsToString() {
        let a = Account(
            host: URL(fileURLWithPath: "/local/somewhere"),
            username: "jdp",
            displayLabel: nil
        )
        // host-component nil → falls through to absoluteString.
        #expect(a.resolvedDisplayLabel.contains("jdp · "))
    }

    @Test("Codable round-trip preserves every field")
    func codableRoundTrip() throws {
        let id = UUID()
        let a = Account(
            id: id,
            host: URL(string: "https://psmith.example.com:8443")!,
            username: "jdp",
            displayLabel: "Personal",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.host == a.host)
        #expect(decoded.username == a.username)
        #expect(decoded.displayLabel == "Personal")
        #expect(decoded.createdAt == a.createdAt)
    }

    @Test("default UUID + Date are populated when omitted")
    func defaultsPopulate() {
        let a = Account(host: URL(string: "https://x")!, username: "u")
        // UUID() never returns nil-bytes
        #expect(a.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        // createdAt should be very recent (within a few seconds of now).
        #expect(abs(a.createdAt.timeIntervalSinceNow) < 2)
    }
}

/// The legacy-import bundle gate. The import reads a USER-level token
/// path on macOS, so it must run only inside the shipping apps — a
/// scratch instance or test runner adopting the user's real session
/// is the failure this guards (docs/todo.md, "AccountManager legacy
/// import"). These tests pin the decision function; the file-touching
/// path is deliberately untested because exercising it would write to
/// the developer's real legacy token location.
@Suite("AccountManager legacy-import gate")
struct LegacyImportGateTests {

    @Test("shipping bundle ids may import")
    func shippingIDsPass() {
        #expect(AccountManager.shouldAttemptLegacyImport(bundleID: "dev.jdpedrie.PsmithMac"))
        #expect(AccountManager.shouldAttemptLegacyImport(bundleID: "dev.jdpedrie.PsmithiOS"))
    }

    @Test("scratch, test-runner, and nil bundle ids are refused")
    func othersRefused() {
        #expect(!AccountManager.shouldAttemptLegacyImport(bundleID: "dev.jdpedrie.PsmithMac.scratch"))
        #expect(!AccountManager.shouldAttemptLegacyImport(bundleID: "com.apple.dt.xctest.tool"))
        #expect(!AccountManager.shouldAttemptLegacyImport(bundleID: ""))
        #expect(!AccountManager.shouldAttemptLegacyImport(bundleID: nil))
    }
}
