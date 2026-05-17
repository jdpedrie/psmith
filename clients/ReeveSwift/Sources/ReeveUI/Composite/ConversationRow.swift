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
    /// Pre-computed fallback for an unset title. Callers should pass
    /// `conversationDisplayTitle(for:profiles:)` here so untitled rows
    /// surface as "Profile name (YYYY-MM-DD)" instead of "Untitled" —
    /// untitled is silent and gives the user nothing to navigate by.
    /// Optional so call sites without profile context (snapshot tests,
    /// fixtures) keep the legacy "Untitled" fallback.
    let fallbackTitle: String?
    /// When true the row renders a small spinner + "generating" caption,
    /// signalling that the conversation has an active stream the user
    /// can tap into to watch live. Driven by
    /// `StreamHub.activeConversationIDs` at the call site.
    let isGenerating: Bool
    /// When true (and not generating) the row renders a small accent
    /// dot — the assistant's last run terminated while the user wasn't
    /// looking. Driven by `StreamHub.unseenConversationIDs`. Hidden
    /// while generating because the spinner already pulls attention.
    let isUnseen: Bool

    public init(
        conversation: ReeveConversation,
        profileChainName: String? = nil,
        fallbackTitle: String? = nil,
        isGenerating: Bool = false,
        isUnseen: Bool = false
    ) {
        self.conversation = conversation
        self.profileChainName = profileChainName
        self.fallbackTitle = fallbackTitle
        self.isGenerating = isGenerating
        self.isUnseen = isUnseen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(displayTitle)
                    .lineLimit(1)
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Generating")
                } else if isUnseen {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("New message")
                }
            }
            if let profileChainName, !profileChainName.isEmpty {
                Text(profileChainName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if isGenerating {
                Text("Generating…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var displayTitle: String {
        if let t = conversation.title, !t.isEmpty { return t }
        return fallbackTitle ?? "Untitled"
    }
}

/// Shared display-title resolver for a conversation. Returns the
/// model-generated or user-edited title when present, otherwise
/// "ProfileName (YYYY-MM-DD)" so untitled rows stay scannable —
/// which persona, when — without forcing the user to open the
/// conversation to remember it. Falls back further to
/// "Conversation (YYYY-MM-DD)" only when the profile lookup fails
/// (deleted profile, etc.).
public func conversationDisplayTitle(
    for conversation: ReeveConversation,
    profiles: [ReeveProfile]
) -> String {
    if let t = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    let date = isoDateFormatter.string(from: conversation.createdAt)
    if let profile = profiles.first(where: { $0.id == conversation.profileID }) {
        return "\(profile.name) (\(date))"
    }
    return "Conversation (\(date))"
}

/// Force ISO yyyy-MM-dd locale-independently. The format is part of
/// the fallback's contract — locale-shifted variants would look
/// inconsistent across users / installs.
private let isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

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
