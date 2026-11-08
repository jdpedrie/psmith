import UIKit
import Vision
import XCTest
import PsmithKit

/// Records what an end-to-end test's screen did over time, not just where
/// it ended: at each sample, the rendered window (saved as a frame), the
/// text on it (read back with on-device OCR), whether each needle is
/// visible, the navigation depth, and the caller's view-model state. The
/// timeline and frames land in `$PSMITH_SNAP_OUT/e2e/<name>/`, so a failure
/// shows the moment something vanished and what the model held then.
///
/// Streaming bugs live between frames: a message that renders, disappears
/// and comes back on reload is invisible to a test that only looks at the
/// final state.
@MainActor
final class E2ETimeline {
    struct Sample {
        let t: TimeInterval
        let note: String
        let visible: [String: Bool]
        let depth: Int
        let state: String
    }

    let dir: URL
    private let start = Date()
    private(set) var samples: [Sample] = []

    init(name: String) {
        let root = ProcessInfo.processInfo.environment["PSMITH_SNAP_OUT"] ?? NSTemporaryDirectory()
        dir = URL(fileURLWithPath: root).appendingPathComponent("e2e").appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TranscriptTrace.reset()
    }

    /// Renders the window, reads its text and records one sample.
    @discardableResult
    func sample(_ window: UIWindow, _ note: String = "", needles: [String] = [], state: String = "") -> Sample {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let n = samples.count
        try? image.pngData()?.write(to: dir.appendingPathComponent(String(format: "f%03d.png", n)))
        let text = Self.recognize(image).lowercased()
        var visible: [String: Bool] = [:]
        for needle in needles { visible[needle] = text.contains(needle.lowercased()) }
        let s = Sample(t: Date().timeIntervalSince(start), note: note, visible: visible,
                       depth: Self.navigationDepth(window), state: state)
        samples.append(s)
        return s
    }

    /// Samples every `interval` until `until` is true (checked after each
    /// sample) or `timeout` passes. Between samples it suspends rather than
    /// spinning the run loop: a test that blocks the main actor starves the
    /// app's own main-actor work, and the timeline would record that stall
    /// instead of the app.
    func record(_ window: UIWindow, every interval: TimeInterval = 0.25, timeout: TimeInterval,
                needles: [String], state: () -> String, until: () -> Bool = { false }) async {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            sample(window, needles: needles, state: state())
            if until() { break }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while Date() < end
    }

    /// Writes timeline.txt: one line per sample.
    func write() {
        let lines = samples.enumerated().map { i, s in
            let marks = s.visible.keys.sorted().map { "\($0)=\(s.visible[$0]! ? "yes" : "NO")" }.joined(separator: " ")
            return String(format: "f%03d t=%6.2fs depth=%d ", i, s.t, s.depth) + marks
                + (s.note.isEmpty ? "" : " [\(s.note)]") + " | " + s.state
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("timeline.txt"), atomically: true, encoding: .utf8)
        // The view model's own record of the same stretch, for lining up
        // what was on screen with what the transcript code decided.
        try? TranscriptTrace.lines.joined(separator: "\n").write(to: dir.appendingPathComponent("trace.txt"), atomically: true, encoding: .utf8)
    }

    /// The samples, from the first one at or after `from` seconds, where
    /// `needle` was not visible.
    func gaps(_ needle: String, from: TimeInterval) -> [Sample] {
        samples.filter { $0.t >= from && $0.visible[needle] == false }
    }

    func firstSeen(_ needle: String) -> TimeInterval? {
        samples.first { $0.visible[needle] == true }?.t
    }

    static func recognize(_ image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    static func navigationDepth(_ window: UIWindow) -> Int {
        func find(_ vc: UIViewController?) -> UINavigationController? {
            guard let vc else { return nil }
            if let nav = vc as? UINavigationController { return nav }
            for child in vc.children { if let n = find(child) { return n } }
            return find(vc.presentedViewController)
        }
        return find(window.rootViewController)?.viewControllers.count ?? 0
    }
}
