import Foundation
import Testing
@testable import PsmithKit

/// AccountManager's local bookkeeping, against a throwaway defaults
/// suite. No server: sign-out's logout call fails and is ignored by
/// design, which is what these tests rely on.
@Suite("AccountManager")
@MainActor
struct AccountManagerTests {
    private func manager(_ accounts: [Account]) -> (AccountManager, AccountStore) {
        let defaults = UserDefaults(suiteName: "psmith.test.accounts.\(UUID().uuidString)")!
        let store = AccountStore(defaults: defaults)
        store.saveAccounts(accounts)
        store.saveActiveID(accounts.first?.id)
        return (AccountManager(store: store), store)
    }

    private let work = Account(host: URL(string: "https://work.psmith.dev")!, username: "jdp")
    private let home = Account(host: URL(string: "https://psmith.home.arpa")!, username: "jdp")

    @Test("renaming an account saves it and keeps everything else")
    func rename() {
        let (m, store) = manager([home, work])
        m.setDisplayLabel("  Work  ", for: work.id)
        let saved = store.loadAccounts().first { $0.id == work.id }
        #expect(saved?.displayLabel == "Work")
        #expect(saved?.host == work.host)
        #expect(saved?.createdAt == work.createdAt)
        #expect(m.accounts.first { $0.id == work.id }?.resolvedDisplayLabel == "Work")
    }

    @Test("a blank name clears it")
    func clearName() {
        let named = Account(host: work.host, username: "jdp", displayLabel: "Work")
        let (m, store) = manager([named])
        m.setDisplayLabel("   ", for: named.id)
        #expect(store.loadAccounts().first?.displayLabel == nil)
    }

    @Test("signing out an account that isn't active keeps it, and the active one")
    func signOutOther() async {
        let (m, _) = manager([home, work])
        await m.signOut(id: work.id)
        #expect(Set(m.accounts.map(\.id)) == [home.id, work.id])
        #expect(m.activeAccountID == home.id)
        #expect(m.appModel(for: work.id)?.authState.phase != .signedIn)
        #expect(!m.isSignedIn(work.id))
    }

    @Test("an account with no session token isn't signed in, and an unknown one isn't either")
    func notSignedIn() {
        let (m, _) = manager([home])
        #expect(!m.isSignedIn(home.id))
        #expect(!m.isSignedIn(UUID()))
    }
}
