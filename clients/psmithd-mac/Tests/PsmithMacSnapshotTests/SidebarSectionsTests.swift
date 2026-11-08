import Testing
import Foundation
@testable import PsmithMac
import PsmithKit

/// The sidebar's date grouping: pinned on top, then Today, Yesterday,
/// the last week, the last month, then one section per month.
struct SidebarSectionsTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    /// Noon on Friday 6 November 2026, Chicago.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
    }

    private func conv(_ id: String, daysAgo: Double, created: Double? = nil, pinned: Bool = false) -> PsmithConversation {
        let used = now.addingTimeInterval(-daysAgo * 86_400)
        return PsmithConversation(
            id: id, profileID: "p", title: id, activeContextID: "c", ownerUserID: "u",
            createdAt: now.addingTimeInterval(-(created ?? daysAgo) * 86_400),
            updatedAt: used, lastActivityAt: used,
            pinnedAt: pinned ? now : nil
        )
    }

    @Test
    func groupsByLastActivity() {
        let sections = SidebarSections.group([
            conv("today", daysAgo: 0.1),
            conv("yesterday", daysAgo: 1),
            conv("week", daysAgo: 4),
            conv("month", daysAgo: 20),
            conv("august", daysAgo: 80),
            conv("pinned", daysAgo: 200, pinned: true),
        ], by: .recentlyUsed, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August 2026"])
        #expect(sections.map { $0.conversations.map(\.id) } == [["pinned"], ["today"], ["yesterday"], ["week"], ["month"], ["august"]])
    }

    @Test
    func newestFirstWithinASection() {
        let sections = SidebarSections.group([
            conv("older", daysAgo: 0.4),
            conv("newer", daysAgo: 0.05),
        ], by: .recentlyUsed, now: now, calendar: calendar)
        #expect(sections.first?.conversations.map(\.id) == ["newer", "older"])
    }

    @Test
    func dateCreatedOrderGroupsByCreation() {
        // Used today, created two months back: it files under its month
        // when the list is sorted by creation.
        let sections = SidebarSections.group([conv("old", daysAgo: 0.1, created: 60)], by: .recentlyCreated, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["September 2026"])
    }

    @Test
    func olderMonthsComeAfterNewerOnes() {
        let sections = SidebarSections.group([
            conv("july", daysAgo: 110),
            conv("september", daysAgo: 50),
        ], by: .recentlyUsed, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["September 2026", "July 2026"])
    }
}
