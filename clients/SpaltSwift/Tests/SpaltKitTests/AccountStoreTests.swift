import Foundation
import Testing
@testable import SpaltKit

/// Pure unit tests for `AccountStore`. Each test gets a fresh
/// UserDefaults suite via a uuid-namespaced name so concurrent
/// runs can't trample each other's state.
@Suite("AccountStore", .serialized)
struct AccountStoreTests {

    /// Build a store backed by an isolated UserDefaults suite.
    /// `removePersistentDomain` on teardown clears the keys so a
    /// later test reusing the same suite name (extremely unlikely
    /// given the UUID) starts clean.
    private func makeStore() -> (AccountStore, UserDefaults) {
        let suiteName = "SpaltTests.AccountStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (AccountStore(defaults: defaults), defaults)
    }

    private func makeAccount(label: String = "test") -> Account {
        Account(
            host: URL(string: "https://spalt.example.com")!,
            username: "u-\(UUID().uuidString.prefix(4))",
            displayLabel: label
        )
    }

    @Test("empty store returns no accounts + no active id")
    func emptyStartState() {
        let (store, _) = makeStore()
        #expect(store.loadAccounts().isEmpty)
        #expect(store.loadActiveID() == nil)
    }

    @Test("saveAccounts + loadAccounts round-trips")
    func saveLoadRoundTrip() {
        let (store, _) = makeStore()
        let a = makeAccount(label: "first")
        let b = makeAccount(label: "second")
        store.saveAccounts([a, b])
        let loaded = store.loadAccounts()
        #expect(loaded.count == 2)
        #expect(loaded.contains(where: { $0.id == a.id }))
        #expect(loaded.contains(where: { $0.id == b.id }))
    }

    @Test("loadAccounts sorts by createdAt ascending")
    func loadSorted() {
        let (store, _) = makeStore()
        let older = Account(
            host: URL(string: "https://x")!, username: "older",
            displayLabel: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let newer = Account(
            host: URL(string: "https://y")!, username: "newer",
            displayLabel: nil,
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        // Save out of order.
        store.saveAccounts([newer, older])
        let loaded = store.loadAccounts()
        #expect(loaded.first?.username == "older")
        #expect(loaded.last?.username == "newer")
    }

    @Test("saveActiveID + loadActiveID round-trip")
    func activeIDRoundTrip() {
        let (store, _) = makeStore()
        let id = UUID()
        store.saveActiveID(id)
        #expect(store.loadActiveID() == id)
    }

    @Test("saveActiveID(nil) clears the persisted id")
    func clearActiveID() {
        let (store, _) = makeStore()
        store.saveActiveID(UUID())
        store.saveActiveID(nil)
        #expect(store.loadActiveID() == nil)
    }

    @Test("append adds account + sets it active by default")
    func appendDefaultsActive() {
        let (store, _) = makeStore()
        let a = makeAccount()
        store.append(a)
        #expect(store.loadAccounts().count == 1)
        #expect(store.loadActiveID() == a.id)
    }

    @Test("append with makeActive=false preserves existing active")
    func appendWithoutActivating() {
        let (store, _) = makeStore()
        let first = makeAccount(label: "first")
        store.append(first) // sets first active
        let second = makeAccount(label: "second")
        store.append(second, makeActive: false)
        #expect(store.loadActiveID() == first.id,
                "should NOT have flipped to second")
        #expect(store.loadAccounts().count == 2)
    }

    @Test("remove drops the matching account")
    func removeAccount() {
        let (store, _) = makeStore()
        let a = makeAccount(label: "A")
        let b = makeAccount(label: "B")
        store.append(a)
        store.append(b)
        let after = store.remove(a.id)
        #expect(after.count == 1)
        #expect(after.first?.id == b.id)
        #expect(store.loadAccounts().count == 1)
    }

    @Test("remove of unknown id is a no-op")
    func removeUnknown() {
        let (store, _) = makeStore()
        let a = makeAccount()
        store.append(a)
        let after = store.remove(UUID())
        #expect(after.count == 1)
        #expect(after.first?.id == a.id)
    }

    @Test("remove of active account falls back to first remaining")
    func removeActiveFallsBack() {
        let (store, _) = makeStore()
        let a = makeAccount(label: "A")
        let b = makeAccount(label: "B")
        store.append(a) // active
        store.append(b, makeActive: false)
        _ = store.remove(a.id)
        // First remaining (b) becomes active.
        #expect(store.loadActiveID() == b.id)
    }

    @Test("remove of last account clears the active id")
    func removeLastClearsActive() {
        let (store, _) = makeStore()
        let a = makeAccount()
        store.append(a)
        _ = store.remove(a.id)
        #expect(store.loadActiveID() == nil)
    }

    @Test("malformed persisted data decodes as empty (no crash)")
    func malformedDataReturnsEmpty() {
        let (store, defaults) = makeStore()
        defaults.set("not json".data(using: .utf8), forKey: "spalt.accounts.v1")
        #expect(store.loadAccounts().isEmpty)
    }

    @Test("malformed active-id decodes as nil (no crash)")
    func malformedActiveID() {
        let (store, defaults) = makeStore()
        defaults.set("not-a-uuid", forKey: "spalt.accounts.active_id.v1")
        #expect(store.loadActiveID() == nil)
    }
}
