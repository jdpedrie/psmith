import Testing
import AppKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// The new conversation's start screen with more profiles than fit: it
/// has to scroll. Driven with real scroll-wheel events offscreen.
@Suite(.serialized)
@MainActor
struct DraftStartScrollTests {
    private static let profiles: [PsmithProfile] = (1...40).map {
        SnapshotFixtures.profile(id: "p-\($0)", name: "Profile \($0)", description: "Profile number \($0).", favorite: false)
    }

    private func mount(height: CGFloat) async -> LiveProbe.Rig {
        let app = SnapshotStubs.makeAppModel(profiles: Self.profiles)
        let rig = LiveProbe.Rig(app: app, size: CGSize(width: 900, height: height), keyed: false)
        let model = ConversationViewModel.draft(client: app.client, hub: app.streamHub, onTerminal: {})
        rig.mount(DraftStartView(model: model, profiles: Self.profiles).frame(maxWidth: .infinity, maxHeight: .infinity))
        await rig.pump(0.6)
        return rig
    }

    private func scrollView(_ rig: LiveProbe.Rig) throws -> NSScrollView {
        func all(_ v: NSView) -> [NSScrollView] {
            (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all)
        }
        return try #require(all(rig.window.contentView!).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
    }

    private func wheel(_ sv: NSScrollView, dy: Int32, rig: LiveProbe.Rig) async {
        for (phase, delta) in [(CGScrollPhase.began, dy / 4), (.changed, dy / 4), (.changed, dy / 4), (.changed, dy / 4), (.ended, 0)] {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            sv.scrollWheel(with: NSEvent(cgEvent: cg)!)
            await rig.pump(0.05)
        }
        await rig.pump(0.4)
    }

    @Test
    func tooManyProfilesScrollToTheLast() async throws {
        let rig = await mount(height: 520)
        defer { rig.window.orderOut(nil) }
        let sv = try scrollView(rig)
        let doc = sv.documentView?.frame.height ?? 0
        let clip = sv.contentView.bounds.height
        #expect(doc > clip + 200, "the grid is clipped to the window (document \(doc), viewport \(clip))")

        let before = sv.contentView.bounds.origin.y
        await wheel(sv, dy: -2400, rig: rig)
        let after = sv.contentView.bounds.origin.y
        #expect(after - before > 200, "a scroll didn't move the profiles (\(before) to \(after))")
    }

    @Test
    func aFewProfilesStayCentered() async throws {
        let app = SnapshotStubs.makeAppModel(profiles: Array(Self.profiles.prefix(3)))
        let rig = LiveProbe.Rig(app: app, size: CGSize(width: 900, height: 700), keyed: false)
        defer { rig.window.orderOut(nil) }
        let model = ConversationViewModel.draft(client: app.client, hub: app.streamHub, onTerminal: {})
        rig.mount(DraftStartView(model: model, profiles: Array(Self.profiles.prefix(3))).frame(maxWidth: .infinity, maxHeight: .infinity))
        await rig.pump(0.6)
        let sv = try scrollView(rig)
        // It fits, so a scroll leaves it where it is.
        let before = sv.contentView.bounds.origin.y
        await wheel(sv, dy: -800, rig: rig)
        #expect(abs(sv.contentView.bounds.origin.y - before) < 1, "a list that fits still scrolled")
    }
}
