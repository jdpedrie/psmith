import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for synced user preferences and the context warning
/// they drive.
@Suite("Preferences", .serialized)
@MainActor
struct PreferencesTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    @Test("a user who never changed a setting gets the defaults")
    func defaults() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prefs-default")
        let prefs = try await client.preferences.get()
        #expect(prefs == .defaults)
        #expect(prefs.contextWarningTokens == 0)
    }

    @Test("an update is stored and seen by the user's other devices")
    func updateSyncsAcrossClients() async throws {
        let (phone, user) = try await TestSession.freshUser(server: server, usernamePrefix: "prefs-sync")
        let written = try await phone.preferences.update(contextWarningTokens: 75_000)
        #expect(written.contextWarningTokens == 75_000)

        let mac = try await TestSession.secondClient(server: server, for: user)
        #expect(try await mac.preferences.get().contextWarningTokens == 75_000)
    }

    @Test("an update that sets nothing keeps what's stored")
    func emptyUpdateKeepsValue() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prefs-sparse")
        _ = try await client.preferences.update(contextWarningTokens: 200_000)
        #expect(try await client.preferences.update().contextWarningTokens == 200_000)
    }

    @Test("a negative threshold is refused")
    func negativeRefused() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prefs-neg")
        await #expect(throws: (any Error).self) {
            _ = try await client.preferences.update(contextWarningTokens: -1)
        }
    }

    @Test("the view model loads, sets optimistically, and keeps the server's answer")
    func viewModelRoundTrip() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prefs-vm")
        let vm = PreferencesViewModel(client: client)
        #expect(vm.preferences == .defaults)
        await vm.load()
        #expect(vm.hasLoaded)
        await vm.setContextWarningTokens(50_000)
        #expect(vm.preferences.contextWarningTokens == 50_000)
        #expect(vm.error == nil)

        let fresh = PreferencesViewModel(client: client)
        await fresh.load()
        #expect(fresh.preferences.contextWarningTokens == 50_000)
    }

    @Test("a failed write rolls the view model back and reports it")
    func failedWriteRollsBack() async throws {
        let dead = PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(initial: "token"),
            authState: AuthState()
        )
        let vm = PreferencesViewModel(client: dead)
        await vm.setContextWarningTokens(75_000)
        #expect(vm.preferences.contextWarningTokens == 0)
        #expect(vm.error != nil)
    }

    @Test("offline, the last synced preferences come from cache")
    func offlineUsesCache() async throws {
        let (live, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prefs-cache", withCache: true)
        _ = try await live.preferences.update(contextWarningTokens: 120_000)
        let dead = PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(initial: "token"),
            authState: AuthState(),
            cache: live.cache
        )
        let vm = PreferencesViewModel(client: dead)
        await vm.load()
        #expect(vm.preferences.contextWarningTokens == 120_000)
    }

    // MARK: - ContextWarning (pure)

    @Test("no warning under the threshold, or with it off")
    func underOrOff() {
        #expect(ContextWarning.evaluate(tokens: 74_999, threshold: 75_000, window: 200_000) == nil)
        #expect(ContextWarning.evaluate(tokens: 150_000, threshold: 0, window: 200_000) == nil)
        #expect(ContextWarning.evaluate(tokens: nil, threshold: 75_000, window: nil) == nil)
    }

    @Test("past the threshold warns")
    func overThreshold() {
        #expect(ContextWarning.evaluate(tokens: 82_000, threshold: 75_000, window: 200_000)
                == .overThreshold(tokens: 82_000))
    }

    @Test("near the model's window warns even with the threshold off")
    func nearWindowWinsRegardless() {
        #expect(ContextWarning.evaluate(tokens: 181_000, threshold: 0, window: 200_000)
                == .nearWindow(tokens: 181_000, window: 200_000))
        #expect(ContextWarning.evaluate(tokens: 181_000, threshold: 75_000, window: 200_000)
                == .nearWindow(tokens: 181_000, window: 200_000))
    }

    @Test("compact counts read like the chip shows them")
    func compactFormatting() {
        #expect(ContextWarning.compact(950) == "950")
        #expect(ContextWarning.compact(8_400) == "8.4k")
        #expect(ContextWarning.compact(82_431) == "82k")
        #expect(ContextWarning.compact(1_250_000) == "1.2M")
    }

    @Test("without a server count, context size is the last reply's prompt plus its output")
    func contextTokensFallback() {
        let client = PsmithClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(),
            authState: AuthState()
        )
        let vm = ConversationViewModel.draft(client: client, hub: StreamHub(subscriber: client.streams), onTerminal: { })
        vm.messages = [
            PsmithMessage(id: "a1", contextID: "c", role: .assistant, content: "",
                          usage: PsmithMessageUsage(inputTokens: 1_000, outputTokens: 200, cacheReadTokens: 9_000)),
        ]
        #expect(vm.contextTokens == 10_200)
        vm.tokenCount = 12_345
        #expect(vm.contextTokens == 12_345, "the server's count wins when there is one")
    }
}
