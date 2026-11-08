import Foundation

/// Date sections for a conversation list (Mac sidebar, iOS Chats), newest first: Pinned, Today, Yesterday,
/// the last 7 and 30 days, then one per month.
public enum ConversationSections {
    public struct Section: Identifiable, Equatable, Sendable {
        public let title: String
        public let conversations: [PsmithConversation]
        public var id: String { title }

        public init(title: String, conversations: [PsmithConversation]) {
            self.title = title
            self.conversations = conversations
        }

        public static func == (a: Section, b: Section) -> Bool {
            a.title == b.title && a.conversations.map(\.id) == b.conversations.map(\.id)
        }
    }

    public static func date(of c: PsmithConversation, by order: PsmithConversationOrder) -> Date {
        order == .recentlyCreated ? c.createdAt : c.lastActivityAt
    }

    public static func group(
        _ conversations: [PsmithConversation],
        by order: PsmithConversationOrder,
        now: Date,
        calendar: Calendar = .current
    ) -> [Section] {
        var pinned: [PsmithConversation] = []
        var buckets: [(key: String, rank: Int, items: [PsmithConversation])] = []
        func add(_ c: PsmithConversation, _ title: String, _ rank: Int) {
            if let i = buckets.firstIndex(where: { $0.key == title }) {
                buckets[i].items.append(c)
            } else {
                buckets.append((title, rank, [c]))
            }
        }
        let today = calendar.startOfDay(for: now)
        let monthFormat = Date.FormatStyle().month(.wide).year()
        for c in conversations {
            if c.pinnedAt != nil {
                pinned.append(c)
                continue
            }
            let d = date(of: c, by: order)
            let day = calendar.startOfDay(for: d)
            let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            switch daysAgo {
            case ..<1: add(c, "Today", 0)
            case 1: add(c, "Yesterday", 1)
            case 2...7: add(c, "Previous 7 Days", 2)
            case 8...30: add(c, "Previous 30 Days", 3)
            default:
                let months = calendar.dateComponents([.month], from: d, to: now).month ?? 0
                add(c, d.formatted(monthFormat), 4 + months)
            }
        }
        var out: [Section] = []
        if !pinned.isEmpty {
            out.append(Section(title: "Pinned", conversations: pinned.sorted { date(of: $0, by: order) > date(of: $1, by: order) }))
        }
        for b in buckets.sorted(by: { $0.rank < $1.rank }) {
            out.append(Section(title: b.key, conversations: b.items.sorted { date(of: $0, by: order) > date(of: $1, by: order) }))
        }
        return out
    }
}

