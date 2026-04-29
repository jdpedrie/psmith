import Testing
import Foundation
@testable import ClarkKit

// Note: ConversationViewModel is @MainActor, so these tests are too.
// Swift Testing supports an actor-isolated context for any test that
// touches main-actor types.

@Suite("LocalTitleResolution")
@MainActor
struct LocalTitleResolutionTests {

    // MARK: helpers

    /// Constructs a ConversationViewModel without exercising the network.
    /// We don't run `load()` — these tests only exercise the parent-chain
    /// walk + transcript shape, which are pure functions.
    private func makeVM(
        conversationProfileID: String,
        title: String? = nil
    ) -> ConversationViewModel {
        let conv = ClarkConversation(
            id: "conv-id",
            profileID: conversationProfileID,
            title: title,
            activeContextID: "ctx-id",
            ownerUserID: "user",
            createdAt: Date(),
            updatedAt: Date()
        )
        // ClarkClient requires a real URL but we never call it.
        let client = ClarkClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(),
            authState: AuthState()
        )
        return ConversationViewModel(
            conversation: conv,
            client: client,
            onTerminal: { },
            localTitler: nil
        )
    }

    // MARK: parent-chain resolver

    @Test
    func resolvesKindFromOwnProfile() {
        let p = ClarkProfile(
            id: "p1",
            name: "p1",
            titleProviderKind: ClarkTitleProviderKind.appleFoundation
        )
        let vm = makeVM(conversationProfileID: "p1")
        #expect(vm.resolvedTitleProviderKind(profilesByID: ["p1": p]) == ClarkTitleProviderKind.appleFoundation)
    }

    @Test
    func resolvesKindFromParentChain() {
        let parent = ClarkProfile(
            id: "parent",
            name: "Parent",
            titleProviderKind: ClarkTitleProviderKind.appleFoundation
        )
        let child = ClarkProfile(
            id: "child",
            name: "Child",
            parentProfileID: "parent"
        )
        let vm = makeVM(conversationProfileID: "child")
        let map: [String: ClarkProfile] = ["parent": parent, "child": child]
        #expect(vm.resolvedTitleProviderKind(profilesByID: map) == ClarkTitleProviderKind.appleFoundation)
    }

    @Test
    func childOverridesParent() {
        let parent = ClarkProfile(
            id: "parent",
            name: "Parent",
            titleProviderKind: "some_other_kind"
        )
        let child = ClarkProfile(
            id: "child",
            name: "Child",
            parentProfileID: "parent",
            titleProviderKind: ClarkTitleProviderKind.appleFoundation
        )
        let vm = makeVM(conversationProfileID: "child")
        let map: [String: ClarkProfile] = ["parent": parent, "child": child]
        #expect(vm.resolvedTitleProviderKind(profilesByID: map) == ClarkTitleProviderKind.appleFoundation)
    }

    @Test
    func returnsNilWhenNoneSet() {
        let p = ClarkProfile(id: "p1", name: "p1")
        let vm = makeVM(conversationProfileID: "p1")
        #expect(vm.resolvedTitleProviderKind(profilesByID: ["p1": p]) == nil)
    }

    @Test
    func cycleSafe() {
        // a -> b -> a; resolve must not loop forever.
        let a = ClarkProfile(id: "a", name: "a", parentProfileID: "b")
        let b = ClarkProfile(id: "b", name: "b", parentProfileID: "a")
        let vm = makeVM(conversationProfileID: "a")
        // Neither has the kind set, so we expect nil — and the call must return.
        #expect(vm.resolvedTitleProviderKind(profilesByID: ["a": a, "b": b]) == nil)
    }
}
