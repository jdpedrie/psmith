import Testing
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// The parent picker offered a profile's own descendants, and choosing one
/// failed on Save (the server refuses an inheritance loop).
@Suite @MainActor struct ParentCandidatesTests {
    @Test func descendantsAreNotOffered() {
        let root = SnapshotFixtures.profile(id: "root", name: "Root")
        let mid = SnapshotFixtures.profile(id: "mid", name: "Mid", parent: root)
        let leaf = SnapshotFixtures.profile(id: "leaf", name: "Leaf", parent: mid)
        let other = SnapshotFixtures.profile(id: "other", name: "Other")
        let all = [root, mid, leaf, other]
        #expect(SKParentCards.candidates(all, for: "root").map(\.id) == ["other"])
        #expect(SKParentCards.candidates(all, for: "mid").map(\.id) == ["root", "other"])
        #expect(SKParentCards.candidates(all, for: "leaf").map(\.id) == ["root", "mid", "other"])
        #expect(SKParentCards.candidates(all, for: nil).count == 4, "a new profile can pick any parent")
    }
}
