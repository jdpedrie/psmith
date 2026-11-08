import Foundation
import SwiftUI
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The boards' own content: profiles, conversations and times, so a render
/// can be laid over its board. Profile ids are picked so each lands on the
/// board's dot color (ProfileColor hashes the id).
@MainActor
enum Board {
    /// 11:00 today: late enough for the boards' 08:03 to 10:42 rows.
    static var now: Date {
        Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!
    }

    static func today(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: now)!
    }

    static func daysAgo(_ d: Int, _ h: Int = 15, _ m: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: -d, to: today(h, m))!
    }

    static let chief = SnapshotFixtures.profile(id: "p-chief-4", name: "Chief of staff", isDefault: true)
    static let demo = SnapshotFixtures.profile(id: "p-demo-7", name: "Demo")
    static let pirate = SnapshotFixtures.profile(id: "p-pirate-0", name: "Pirate tutor")
    static let council = SnapshotFixtures.profile(id: "p-council-3", name: "Council")
    static var profiles: [PsmithProfile] { [chief, demo, pirate, council] }

    static func conversation(_ id: String, _ title: String, _ profile: PsmithProfile, at: Date,
                             pinned: Bool = false, archived: Date? = nil) -> PsmithConversation {
        PsmithConversation(
            id: id, profileID: profile.id, title: title, activeContextID: "ctx-\(id)",
            ownerUserID: "user-fixed-1", createdAt: at, updatedAt: at, lastActivityAt: at,
            settings: nil, archivedAt: archived, pinnedAt: pinned ? at : nil
        )
    }

    /// The Main board's list.
    static var mainList: [PsmithConversation] {
        [
            conversation("c-weekly", "Weekly planning", chief, at: today(7, 30), pinned: true),
            conversation("c-scroll", "Scroll architecture review", demo, at: today(10, 42)),
            conversation("c-vacuum", "Postgres vacuum tuning", chief, at: today(10, 51)),
            conversation("c-pirate", "Pirate tutor: fractions", pirate, at: today(9, 15)),
            conversation("c-council", "Council: pricing debate", council, at: today(8, 3)),
            conversation("c-swift", "Swift 6 concurrency errors", demo, at: daysAgo(1)),
            conversation("c-lisbon", "Trip to Lisbon in May", chief, at: daysAgo(1, 9)),
        ]
    }

    static let user = PsmithUser(id: "user-fixed-1", username: "john", displayName: "John", isAdmin: true)
}
