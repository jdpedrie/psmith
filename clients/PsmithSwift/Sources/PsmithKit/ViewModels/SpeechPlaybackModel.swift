import Foundation
import AVFoundation
import CryptoKit

/// Drives read-aloud for assistant messages. One playback at a time,
/// app-wide: starting a message stops whatever else is speaking.
///
/// Two synthesis paths, chosen by the user's speech config:
/// - apple_local (the zero-config default): AVSpeechSynthesizer,
///   entirely on-device, with a lightweight client-side markdown
///   strip standing in for the server normalizer.
/// - cloud / self-hosted kinds: POST /tts streams PCM (s16le mono
///   24kHz); playback starts on the first chunk via AVAudioEngine.
///   The complete PCM is written into the replay cache so tapping
///   play again is free — audio is never stored server-side.
@Observable
@MainActor
public final class SpeechPlaybackModel {
    private let client: PsmithClient

    /// Message currently being spoken (either path). nil = silent.
    public private(set) var playingMessageID: String?
    /// Message whose audio is still being fetched/decoded — lets the
    /// UI show a spinner between tap and first sound.
    public private(set) var loadingMessageID: String?
    public private(set) var playbackError: String?

    public func clearError() { playbackError = nil }

    private var streamTask: Task<Void, Never>?
    private var player: PCMStreamPlayer?
    private let localSpeaker = LocalSpeaker()

    /// Last successfully fetched config — reused when the config
    /// RPC fails mid-session so playback degrades gracefully
    /// instead of erroring on a blip.
    private var lastConfig: PsmithSpeechConfig?

    public init(client: PsmithClient) {
        self.client = client
        localSpeaker.onFinish = { [weak self] in
            guard let self, self.playingMessageID != nil else { return }
            self.playingMessageID = nil
        }
    }

    public func isPlaying(messageID: String) -> Bool { playingMessageID == messageID }
    public func isLoading(messageID: String) -> Bool { loadingMessageID == messageID }

    /// Tap handler: stop if this message is already playing or
    /// loading, otherwise stop everything and start it.
    public func toggle(messageID: String, content: String) {
        if playingMessageID == messageID || loadingMessageID == messageID {
            stop()
            return
        }
        stop()
        playbackError = nil
        loadingMessageID = messageID
        streamTask = Task { [weak self] in
            await self?.start(messageID: messageID, content: content)
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        player?.stop()
        player = nil
        localSpeaker.stop()
        playingMessageID = nil
        loadingMessageID = nil
    }

    // MARK: - Playback paths

    private func start(messageID: String, content: String) async {
        let config = await resolveConfig()
        guard !Task.isCancelled else { return }

        if config.isAppleLocal {
            configureAudioSession()
            loadingMessageID = nil
            playingMessageID = messageID
            localSpeaker.speak(
                SpeechText.liteNormalize(content),
                voice: config.voice,
                speed: config.speed
            )
            return
        }

        // Cloud path. Replay cache first — an exact hit skips the
        // network (and the bill) entirely.
        let cacheID = Self.cacheID(messageID: messageID, content: content, config: config)
        if let cache = client.cache,
           let pcm = await cache.get(Data.self, kind: CacheKind.speechAudio, id: cacheID),
           !pcm.isEmpty {
            guard !Task.isCancelled else { return }
            playPCM(pcm, messageID: messageID)
            return
        }

        do {
            let stream = try await client.speech.synthesize(messageID: messageID)
            guard !Task.isCancelled else { return }
            configureAudioSession()
            let player = PCMStreamPlayer()
            self.player = player
            player.onFinished = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.playingMessageID == messageID else { return }
                    self.playingMessageID = nil
                    self.player = nil
                }
            }
            var full = Data()
            var started = false
            for try await chunk in stream {
                if Task.isCancelled { return }
                full.append(chunk)
                player.feed(chunk)
                if !started {
                    started = true
                    try player.start()
                    loadingMessageID = nil
                    playingMessageID = messageID
                }
            }
            player.finish()
            if let cache = client.cache, !full.isEmpty {
                try? await cache.set(full, kind: CacheKind.speechAudio, id: cacheID, capBytes: CachePreferences.capBytes)
            }
        } catch {
            guard !Task.isCancelled, !PsmithError.isCancellation(error) else { return }
            // 412 = server says the config is apple_local (raced a
            // config change); speak on-device rather than failing.
            if case let PsmithError.rpc(code, _) = error, code == .failedPrecondition {
                configureAudioSession()
                loadingMessageID = nil
                playingMessageID = messageID
                localSpeaker.speak(SpeechText.liteNormalize(content), voice: "", speed: 0)
                return
            }
            stop()
            playbackError = PsmithError.display(error)
        }
    }

    private func playPCM(_ pcm: Data, messageID: String) {
        configureAudioSession()
        let player = PCMStreamPlayer()
        self.player = player
        player.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playingMessageID == messageID else { return }
                self.playingMessageID = nil
                self.player = nil
            }
        }
        player.feed(pcm)
        player.finish()
        do {
            try player.start()
            loadingMessageID = nil
            playingMessageID = messageID
        } catch {
            stop()
            playbackError = PsmithError.display(error)
        }
    }

    private func resolveConfig() async -> PsmithSpeechConfig {
        if let cfg = try? await client.speech.get() {
            lastConfig = cfg
            return cfg
        }
        return lastConfig ?? PsmithSpeechConfig(kind: PsmithSpeechConfig.kindAppleLocal)
    }

    /// Replay-cache identity: any input that changes the audio
    /// changes the key. Content is hashed (message bodies are big;
    /// keys are indexed).
    static func cacheID(messageID: String, content: String, config: PsmithSpeechConfig) -> String {
        let contentHash = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [
            messageID, contentHash, config.kind, config.voice,
            config.model, String(config.normalizerVersion),
        ].joined(separator: "|")
    }

    private func configureAudioSession() {
        #if os(iOS)
        // .playback so speech keeps going with the ringer switch
        // muted and ducks properly; spoken-audio mode gets the
        // system's long-form routing behavior.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

// MARK: - On-device synthesis (apple_local)

/// Thin AVSpeechSynthesizer wrapper. Exists because the delegate
/// must be an NSObject and the model itself is @Observable.
/// Main-actor isolated; the delegate callbacks (which AVFoundation
/// may deliver off-main) are nonisolated and hop back.
@MainActor
private final class LocalSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onFinish: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: String, speed: Double) {
        let utterance = AVSpeechUtterance(string: text)
        if !voice.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voice)
                ?? AVSpeechSynthesisVoice(language: voice)
        }
        if speed > 0 {
            // AVSpeech rate is 0…1 around a 0.5 default; treat the
            // config speed as a multiplier on the default.
            let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
            utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}

// MARK: - Streaming PCM playback (cloud kinds)

/// Plays a stream of s16le mono 24kHz PCM through AVAudioEngine,
/// accepting chunks incrementally so audio starts before the fetch
/// completes. Main-actor isolated: the audio queue's completion
/// callbacks hop back here, so all bookkeeping stays serialized.
@MainActor
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    /// Byte carried over when a chunk ends mid-sample (odd length).
    private var remainder = Data()
    private var pendingBuffers = 0
    private var inputFinished = false
    var onFinished: (() -> Void)?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        try engine.start()
        node.play()
    }

    /// Convert s16le bytes to a float buffer and schedule it. Safe
    /// to call before start(); buffers queue on the node.
    func feed(_ data: Data) {
        var bytes = remainder
        bytes.append(data)
        let sampleCount = bytes.count / 2
        remainder = sampleCount * 2 < bytes.count ? bytes.suffix(bytes.count - sampleCount * 2) : Data()
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))
        else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let out = buffer.floatChannelData![0]
        bytes.prefix(sampleCount * 2).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<sampleCount {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let sample = Int16(bitPattern: hi << 8 | lo)
                out[i] = Float(sample) / 32768.0
            }
        }
        pendingBuffers += 1
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in self?.bufferDone() }
        }
    }

    /// No more input coming; fire onFinished when the queue drains.
    func finish() {
        inputFinished = true
        if pendingBuffers == 0 { onFinished?() }
    }

    func stop() {
        onFinished = nil
        node.stop()
        engine.stop()
    }

    private func bufferDone() {
        pendingBuffers -= 1
        if inputFinished && pendingBuffers == 0 {
            onFinished?()
        }
    }
}

// MARK: - Client-side text prep for apple_local

/// Lightweight markdown strip for on-device synthesis. The server
/// normalizer (goldmark AST) only runs for cloud kinds; apple_local
/// never round-trips, so this regex pass covers the worst speech
/// offenders. Kept intentionally simpler than the server's — the
/// two don't need to match byte-for-byte because apple_local audio
/// is never cached against NormalizerVersion.
public enum SpeechText {
    public static func liteNormalize(_ markdown: String) -> String {
        var text = markdown

        // Fenced code blocks → announcement.
        text = text.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: "Code omitted.",
            options: .regularExpression
        )
        // Table blocks (consecutive |-prefixed lines) → announcement.
        text = text.replacingOccurrences(
            of: #"(?m)^\|.*\|[ \t]*$\n?(^\|.*\|[ \t]*$\n?)*"#,
            with: "Table omitted.\n",
            options: .regularExpression
        )
        // Images before links (the syntaxes nest).
        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#,
            with: "Image.",
            options: .regularExpression
        )
        // Links speak their label.
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        // Headings, blockquotes, list markers at line starts.
        text = text.replacingOccurrences(
            of: #"(?m)^[ \t]*(#{1,6}|>|[-*+]|\d+\.)[ \t]+"#,
            with: "",
            options: .regularExpression
        )
        // Emphasis + inline code markers.
        text = text.replacingOccurrences(
            of: #"(\*\*|__|\*|_|`)"#,
            with: "",
            options: .regularExpression
        )
        // Collapse the whitespace the strips leave behind.
        text = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
