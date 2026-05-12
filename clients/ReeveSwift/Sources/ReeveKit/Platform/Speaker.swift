import Foundation
import SwiftUI
import AVFoundation

/// Local text-to-speech playback for assistant messages. Wraps
/// `AVSpeechSynthesizer` behind an `@Observable` class so SwiftUI
/// views can drive their play/stop button state straight off
/// `speakingMessageID`.
///
/// One synth instance per app — the "queue-aware" rule the multimodal
/// plan calls for (tapping a different message stops the prior) falls
/// out automatically because there's only one player.
///
/// `AVSpeechSynthesizer` is main-thread-only at the API level, so the
/// mutating methods are `@MainActor`. The class itself isn't isolated
/// because the SwiftUI `EnvironmentKey.defaultValue` machinery doesn't
/// play nicely with main-actor-isolated initializers.
@Observable
public final class Speaker: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    /// Message id currently being read aloud, or nil when silent.
    /// Views bind their speaker-button icon to this — equality check
    /// against the row's message id flips play↔stop.
    public private(set) var speakingMessageID: String?

    @ObservationIgnored
    private let synth: AVSpeechSynthesizer

    /// Monotonic counter so the delegate callbacks can be matched to
    /// the utterance that spawned them across the actor hop without
    /// capturing the (non-Sendable) `AVSpeechUtterance` reference.
    /// Incremented in `toggle` (new utterance) and `stop` (old one
    /// cancelled) — callbacks from prior generations are ignored.
    @ObservationIgnored
    private var generation: UInt64 = 0

    public override init() {
        self.synth = AVSpeechSynthesizer()
        super.init()
        self.synth.delegate = self
    }

    /// Begin speaking `text` attributed to `messageID`. If a prior
    /// utterance is in flight, it's stopped and the new one starts
    /// immediately. Calling with the currently-speaking id is a stop
    /// (toggle semantics drive the UI's single-button affordance).
    @MainActor
    public func toggle(messageID: String, text: String) {
        if speakingMessageID == messageID {
            stop()
            return
        }
        stop()
        let utter = AVSpeechUtterance(string: sanitised(text))
        utter.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        generation &+= 1
        speakingMessageID = messageID
        synth.speak(utter)
    }

    /// Halt playback. Safe to call when nothing is playing.
    @MainActor
    public func stop() {
        synth.stopSpeaking(at: .immediate)
        generation &+= 1
        speakingMessageID = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        clearIfStale()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        clearIfStale()
    }

    /// Common delegate trail: snapshot the current generation, hop to
    /// the main actor, and only clear `speakingMessageID` if it's
    /// still tied to the same generation. Captures only `UInt64`
    /// (Sendable), no `AVSpeechUtterance` reference crosses actors.
    private nonisolated func clearIfStale() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // If the synth isn't speaking and we still think we are,
            // resolve the mismatch. The generation guard prevents a
            // delayed "didFinish" for utterance N from clearing the
            // state set by a freshly-started utterance N+1 (which
            // bumped `generation` in `toggle`).
            if !self.synth.isSpeaking, self.speakingMessageID != nil {
                self.speakingMessageID = nil
            }
        }
    }

    private func sanitised(_ raw: String) -> String {
        Self.sanitiseForSpeech(raw)
    }

    /// Strip the bits that read aloud poorly: code fences (read as
    /// long pauses + symbol noise), bare URLs, markdown link syntax.
    /// Aggressive trimming is fine — the user asked for a listenable
    /// rendering, not a literal one. `internal` for unit tests; the
    /// instance path goes through `sanitised(_:)`.
    static func sanitiseForSpeech(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " (code block) ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^\\)]+\\)",
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "https?://\\S+",
            with: " (link) ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?m)^[#>*\\-]+\\s+",
            with: "",
            options: .regularExpression
        )
        return text
    }
}

private struct SpeakerEnvironmentKey: EnvironmentKey {
    static let defaultValue: Speaker = Speaker()
}

public extension EnvironmentValues {
    /// Shared TTS player. Reading this in a view body gives access to
    /// `speakingMessageID` (for button state) and `toggle(messageID:text:)`
    /// (for the button action). Default value is a live `Speaker` so
    /// tests / snapshot harnesses that don't inject one still get a
    /// usable instance — silence is the safe failure mode for tests
    /// since `AVSpeechSynthesizer` doesn't error on missing audio.
    var speaker: Speaker {
        get { self[SpeakerEnvironmentKey.self] }
        set { self[SpeakerEnvironmentKey.self] = newValue }
    }
}
