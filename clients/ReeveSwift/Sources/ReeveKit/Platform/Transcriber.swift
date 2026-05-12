import Foundation
import SwiftUI
import Speech
import AVFoundation

/// Local speech-to-text dictation. Drives the composer mic button:
/// press-and-hold to record, release to stop; the running transcript
/// is published live so the composer can render interim text as the
/// user speaks.
///
/// Routes audio through `AVAudioEngine` into `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true` whenever the system reports
/// on-device support (current Apple Silicon Macs + recent iPhones all
/// do). Audio bytes never leave the device — this is the cheap path
/// the multimodal plan calls "Phase 0".
@Observable
public final class Transcriber: NSObject, @unchecked Sendable {
    public enum State: Sendable, Hashable {
        case idle
        case requestingAuthorization
        case unauthorized(reason: String)
        case recording
        case stopped
        case failed(message: String)
    }

    /// Current lifecycle phase. Views key their mic-button rendering
    /// off this — `.recording` flips the icon to a stop indicator.
    public private(set) var state: State = .idle

    /// Live transcript, updated as the recognizer emits partial
    /// results. Reset at the start of each recording.
    public private(set) var transcript: String = ""

    @ObservationIgnored
    private let audioEngine = AVAudioEngine()
    @ObservationIgnored
    private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored
    private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored
    private var task: SFSpeechRecognitionTask?

    public override init() {
        super.init()
        // Locale-pick: prefer the user's current locale; fall back to
        // en_US if no recognizer is available for it. Avoids a silent
        // failure on locales where SFSpeechRecognizer never returns
        // text.
        self.recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    }

    /// Begin recording + recognition. Idempotent — calling while
    /// already recording is a no-op (it doesn't restart). Permissions
    /// are requested lazily on the first start; the user sees the
    /// system prompt in the same beat as their first press-and-hold.
    @MainActor
    public func start() async {
        guard state != .recording else { return }
        state = .requestingAuthorization
        let speechOK = await Self.requestSpeechAuthorization()
        guard speechOK else {
            state = .unauthorized(reason: "Speech recognition permission denied. Enable it in Settings.")
            return
        }
        let micOK = await Self.requestMicrophoneAuthorization()
        guard micOK else {
            state = .unauthorized(reason: "Microphone permission denied. Enable it in Settings.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .failed(message: "Speech recognition is unavailable for the current locale.")
            return
        }
        do {
            try beginRecognition(recognizer: recognizer)
            transcript = ""
            state = .recording
        } catch {
            stopInternal()
            state = .failed(message: error.localizedDescription)
        }
    }

    /// Halt recording. Safe to call when idle. Final transcript value
    /// remains in `transcript` so the caller can commit it to a
    /// composer draft after the gesture ends.
    @MainActor
    public func stop() {
        stopInternal()
        if state == .recording {
            state = .stopped
        }
    }

    /// Reset back to idle without changing the transcript. Used after
    /// the caller has consumed the final value.
    @MainActor
    public func reset() {
        stopInternal()
        state = .idle
        transcript = ""
    }

    // MARK: - Internals

    @MainActor
    private func beginRecognition(recognizer: SFSpeechRecognizer) throws {
        // Tear down any prior session first — defensive against a
        // start-stop-start sequence that overlapped the engine
        // shutdown.
        stopInternal()

        #if os(iOS)
        // On iOS the audio session needs to be configured for record
        // before tapping the input node. Mac's AVAudioEngine doesn't
        // need this dance.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        self.request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // 1024-frame buffer is the standard sweet spot — small enough
        // for ~20ms latency, large enough to keep CPU low.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stopInternal()
                        if self.state == .recording {
                            self.state = .stopped
                        }
                    }
                }
                if error != nil {
                    // SFSpeechRecognizer sometimes reports a cancellation
                    // as an error when we stop the task ourselves —
                    // don't surface those. A genuine failure leaves
                    // the recording state, which we treat as stop.
                    self.stopInternal()
                }
            }
        }
    }

    @MainActor
    private func stopInternal() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    private static func requestMicrophoneAuthorization() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            case .undetermined:
                return await AVAudioApplication.requestRecordPermission()
            @unknown default: return false
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return true
            case .denied: return false
            case .undetermined:
                return await withCheckedContinuation { cont in
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        cont.resume(returning: granted)
                    }
                }
            @unknown default: return false
            }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
        #endif
    }
}

private struct TranscriberEnvironmentKey: EnvironmentKey {
    static let defaultValue: Transcriber = Transcriber()
}

public extension EnvironmentValues {
    /// Shared dictation engine. Reading this in a view body gives
    /// access to `state` + `transcript` for the live preview and
    /// `start()` / `stop()` for the press-and-hold gesture.
    var transcriber: Transcriber {
        get { self[TranscriberEnvironmentKey.self] }
        set { self[TranscriberEnvironmentKey.self] = newValue }
    }
}
