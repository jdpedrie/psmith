import Foundation

/// Drives the Speech settings panel on Mac + iOS. Same shape as
/// EmbedderViewModel: draft fields, the saved server snapshot for
/// compare, and async save/test/delete outcomes rendered inline.
///
/// The default kind is apple_local (on-device synthesis, zero
/// config) — the panel exists for users who want a cloud or
/// self-hosted voice instead.
@Observable
@MainActor
public final class SpeechSettingsModel {
    private let client: PsmithClient

    public private(set) var saved: PsmithSpeechConfig?
    public private(set) var didLoad: Bool = false

    /// Registered kinds from the server (apple_local, grok,
    /// openai-compatible, …) — drives the kind picker.
    public private(set) var availableKinds: [String] = []

    /// Chat providers the user could point provider_ref at, for the
    /// credential-reuse picker. (id, label) pairs.
    public private(set) var availableProviders: [(id: String, label: String)] = []

    /// Drafted form fields. `apiKeyDraft` is the write buffer —
    /// the server only ever reports apiKeySet, never the value.
    public var kindDraft: String = PsmithSpeechConfig.kindAppleLocal
    public var voiceDraft: String = ""
    public var modelDraft: String = ""
    public var speedDraft: Double = 1.0
    public var baseURLDraft: String = ""
    public var apiKeyDraft: String = ""
    public var providerRefDraft: String = ""
    public var enabledDraft: Bool = true

    public private(set) var saving: Bool = false
    public private(set) var testing: Bool = false
    public private(set) var deleting: Bool = false
    public private(set) var saveError: String?
    public private(set) var testResult: PsmithSpeechTestResult?

    public init(client: PsmithClient) {
        self.client = client
    }

    public var isAppleLocalDraft: Bool { kindDraft == PsmithSpeechConfig.kindAppleLocal }

    public var isDirty: Bool {
        guard let saved else {
            return kindDraft != PsmithSpeechConfig.kindAppleLocal
                || !voiceDraft.isEmpty
                || !modelDraft.isEmpty
                || speedDraft != 1.0
                || !baseURLDraft.isEmpty
                || !apiKeyDraft.isEmpty
                || !providerRefDraft.isEmpty
        }
        if kindDraft != saved.kind { return true }
        if voiceDraft != saved.voice { return true }
        if modelDraft != saved.model { return true }
        if speedDraft != savedSpeed { return true }
        if baseURLDraft != saved.baseURL { return true }
        if !apiKeyDraft.isEmpty { return true }
        if providerRefDraft != saved.providerRef { return true }
        if enabledDraft != saved.enabled { return true }
        return false
    }

    /// The saved speed for compare, mapping the server's "0 = driver
    /// default" onto the slider's 1.0 resting point.
    private var savedSpeed: Double {
        guard let saved, saved.speed != 0 else { return 1.0 }
        return saved.speed
    }

    public func load() async {
        async let kindsTask = loadKindsQuietly()
        async let providersTask = loadProvidersQuietly()
        do {
            let cfg = try await client.speech.get()
            saved = cfg
            applyDrafts(from: cfg)
            didLoad = true
        } catch {
            saveError = PsmithError.display(error)
        }
        _ = await (kindsTask, providersTask)
    }

    private func loadKindsQuietly() async {
        if let kinds = try? await client.speech.listKinds() {
            availableKinds = kinds
        }
    }

    private func loadProvidersQuietly() async {
        if let provs = try? await client.modelProviders.list() {
            availableProviders = provs.map { (id: $0.id, label: $0.label) }
        }
    }

    private func applyDrafts(from cfg: PsmithSpeechConfig) {
        kindDraft = cfg.kind
        voiceDraft = cfg.voice
        modelDraft = cfg.model
        speedDraft = cfg.speed == 0 ? 1.0 : cfg.speed
        baseURLDraft = cfg.baseURL
        apiKeyDraft = ""
        providerRefDraft = cfg.providerRef
        enabledDraft = cfg.enabled
    }

    /// Persist the current draft. apiKey and providerRef are
    /// tri-state on the wire: empty draft that matches the saved
    /// state sends nil (leave alone); an explicit clear sends "".
    @discardableResult
    public func save() async -> Bool {
        saving = true
        defer { saving = false }
        saveError = nil
        // apiKey: only send when the user typed something, or when
        // clearing (handled by clearAPIKey below).
        let apiKeyParam: String? = apiKeyDraft.isEmpty ? nil : apiKeyDraft
        // providerRef: send whenever it differs from saved so both
        // set ("uuid") and clear ("") flow through.
        let providerRefParam: String? = providerRefDraft == (saved?.providerRef ?? "") ? nil : providerRefDraft
        do {
            let cfg = try await client.speech.update(
                kind: kindDraft,
                voice: voiceDraft,
                model: modelDraft,
                speed: speedDraft,
                baseURL: baseURLDraft,
                apiKey: apiKeyParam,
                providerRef: providerRefParam,
                enabled: enabledDraft
            )
            saved = cfg
            applyDrafts(from: cfg)
            return true
        } catch {
            saveError = PsmithError.display(error)
            return false
        }
    }

    /// Remove the stored standalone key ("" on the wire clears).
    public func clearAPIKey() async {
        saveError = nil
        do {
            let cfg = try await client.speech.update(apiKey: "")
            saved = cfg
            applyDrafts(from: cfg)
        } catch {
            saveError = PsmithError.display(error)
        }
    }

    /// Fire a synthesis round-trip against the SAVED config (unsaved
    /// drafts are not honoured — UI disables Test while isDirty).
    public func test() async {
        testing = true
        defer { testing = false }
        testResult = nil
        do {
            testResult = try await client.speech.test()
        } catch {
            testResult = PsmithSpeechTestResult(
                ok: false,
                errorMessage: PsmithError.display(error),
                latencyMs: 0,
                audioBytes: 0
            )
        }
    }

    /// Drop the row: back to the apple_local default.
    public func delete() async {
        deleting = true
        defer { deleting = false }
        saveError = nil
        do {
            try await client.speech.delete()
            let cfg = try await client.speech.get()
            saved = cfg
            applyDrafts(from: cfg)
            testResult = nil
        } catch {
            saveError = PsmithError.display(error)
        }
    }

    public func discardChanges() {
        guard let saved else {
            kindDraft = PsmithSpeechConfig.kindAppleLocal
            voiceDraft = ""
            modelDraft = ""
            speedDraft = 1.0
            baseURLDraft = ""
            apiKeyDraft = ""
            providerRefDraft = ""
            enabledDraft = true
            return
        }
        applyDrafts(from: saved)
    }
}
