import Foundation
import Observation

/// List of conversations + profiles for the active user.
/// Drives the sidebar conversation list. Reusable across macOS / iOS.
@Observable
@MainActor
public final class ConversationsModel {
    private let client: ClarkClient

    public var conversations: [ClarkConversation] = []
    public var profiles: [ClarkProfile] = []
    public var selectedID: ClarkConversation.ID?
    public var loadError: String?
    public var isLoading = false

    public init(client: ClarkClient) {
        self.client = client
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let convos = client.conversations.list()
            async let profs = client.profiles.list()
            let (cs, ps) = try await (convos, profs)
            self.conversations = cs.items
            self.profiles = ps
            self.loadError = nil
            if selectedID == nil { selectedID = cs.items.first?.id }
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    @discardableResult
    public func newConversation(profileID: String) async -> ClarkConversation? {
        do {
            let c = try await client.conversations.create(profileID: profileID)
            self.conversations.insert(c, at: 0)
            self.selectedID = c.id
            return c
        } catch {
            self.loadError = error.localizedDescription
            return nil
        }
    }

    public func delete(_ id: String) async {
        do {
            try await client.conversations.delete(id: id)
            self.conversations.removeAll { $0.id == id }
            if selectedID == id { selectedID = conversations.first?.id }
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    public var clientRef: ClarkClient { client }
}
