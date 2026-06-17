import Testing
import Foundation
@testable import SpaltKit

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
        let conv = SpaltConversation(
            id: "conv-id",
            profileID: conversationProfileID,
            title: title,
            activeContextID: "ctx-id",
            ownerUserID: "user",
            createdAt: Date(),
            updatedAt: Date()
        )
        // SpaltClient requires a real URL but we never call it.
        let client = SpaltClient(
            host: URL(string: "http://127.0.0.1:1")!,
            tokenStore: InMemoryTokenStore(),
            authState: AuthState()
        )
        return ConversationViewModel(
            conversation: conv,
            client: client,
            hub: StreamHub(subscriber: client.streams),
            onTerminal: { },
            localTitler: nil
        )
    }

    // MARK: parent-chain resolver

    @Test
    func resolvesKindFromOwnProfile() {
        let p = SpaltProfile(
            id: "p1",
            name: "p1",
            titleProviderKind: SpaltTitleProviderKind.appleFoundation
        )
        let vm = makeVM(conversationProfileID: "p1")
        #expect(vm.resolvedTitleProviderKind(profilesByID: ["p1": p]) == SpaltTitleProviderKind.appleFoundation)
    }

    @Test
    func resolvesKindFromParentChain() {
        let parent = SpaltProfile(
            id: "parent",
            name: "Parent",
            titleProviderKind: SpaltTitleProviderKind.appleFoundation
        )
        let child = SpaltProfile(
            id: "child",
            name: "Child",
            parentProfileID: "parent"
        )
        let vm = makeVM(conversationProfileID: "child")
        let map: [String: SpaltProfile] = ["parent": parent, "child": child]
        #expect(vm.resolvedTitleProviderKind(profilesByID: map) == SpaltTitleProviderKind.appleFoundation)
    }

    @Test
    func childOverridesParent() {
        let parent = SpaltProfile(
            id: "parent",
            name: "Parent",
            titleProviderKind: "some_other_kind"
        )
        let child = SpaltProfile(
            id: "child",
            name: "Child",
            parentProfileID: "parent",
            titleProviderKind: SpaltTitleProviderKind.appleFoundation
        )
        let vm = makeVM(conversationProfileID: "child")
        let map: [String: SpaltProfile] = ["parent": parent, "child": child]
        #expect(vm.resolvedTitleProviderKind(profilesByID: map) == SpaltTitleProviderKind.appleFoundation)
    }

    @Test
    func returnsNilWhenNoneSet() {
        let p = SpaltProfile(id: "p1", name: "p1")
        let vm = makeVM(conversationProfileID: "p1")
        #expect(vm.resolvedTitleProviderKind(profilesByID: ["p1": p]) == nil)
    }

    @Test
    func cycleSafe() {
        // a -> b -> a; resolve must not loop forever.
        let a = SpaltProfile(id: "a", name: "a", parentProfileID: "b")
        let b = SpaltProfile(id: "b", name: "b", parentProfileID: "a")
        let vm = makeVM(conversationProfileID: "a")
        // Neither has the kind set, so we expect nil — and the call must return.
        #expect(vm.resolvedTitleProviderKind(profilesByID: ["a": a, "b": b]) == nil)
    }
}
