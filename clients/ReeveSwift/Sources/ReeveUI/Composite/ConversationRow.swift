import SwiftUI
import ReeveKit

/// Pure content view for a conversation list row: title + optional
/// profile-chain caption. Stateless, no chrome — each platform wraps
/// it with its own delete affordance:
///   - Mac: hover-revealed trash icon overlay (per the macOS 26
///     contextMenu-on-sidebar-rows bug).
///   - iOS: `.swipeActions` trailing-edge Delete + `.contextMenu`
///     long-press menu.
///
/// `profileChainName` is the pre-resolved "Profile (parent, grandparent)"
/// label. Pass nil to hide it (used in By-Profile mode where the
/// section header already names the profile).
public struct ConversationRow: View {
    let conversation: ReeveConversation
    let profileChainName: String?

    public init(conversation: ReeveConversation, profileChainName: String? = nil) {
        self.conversation = conversation
        self.profileChainName = profileChainName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .lineLimit(1)
            if let profileChainName, !profileChainName.isEmpty {
                Text(profileChainName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var displayTitle: String {
        if let t = conversation.title, !t.isEmpty { return t }
        return "Untitled"
    }
}

/// Helper for resolving "Profile (parent, grandparent)" from a
/// conversation's profile id against a `ConversationsModel`'s profile
/// list. Lifted here so both platforms compute it identically. Walks the
/// parent chain with cycle/depth guards.
public func profileChainName(
    for conversation: ReeveConversation,
    profiles: [ReeveProfile]
) -> String? {
    let id = conversation.profileID
    guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
    var ancestors: [String] = []
    var current = profile.parentProfileID
    var seen: Set<String> = [profile.id]
    var depth = 0
    while let pid = current, !seen.contains(pid), depth < 8 {
        seen.insert(pid)
        depth += 1
        guard let parent = profiles.first(where: { $0.id == pid }) else { break }
        ancestors.append(parent.name)
        current = parent.parentProfileID
    }
    return ancestors.isEmpty ? profile.name : "\(profile.name) (\(ancestors.joined(separator: ", ")))"
}
