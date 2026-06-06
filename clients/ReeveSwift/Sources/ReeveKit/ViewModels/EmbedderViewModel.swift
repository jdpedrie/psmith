import Foundation

/// Drives the Embedder settings panel on Mac + iOS. Holds a draft
/// of the form fields, the saved-on-server snapshot for compare,
/// and the asynchronous outcomes of save / test / delete actions
/// so the views can render inline status without owning the async
/// machinery themselves.
///
/// Mirrors LangfuseViewModel's shape so the two settings pages can
/// share a mental model. Per Reeve's Swift conventions this lives
/// in the shared ReeveKit package; views are platform-specific.
@Observable
@MainActor
public final class EmbedderViewModel {
    private let client: ReeveClient

    /// Snapshot of the server-side row, refreshed by `load`. nil
    /// until the first load completes — UI shows a spinner during
    /// that window.
    public private(set) var saved: ReeveEmbedderConfig?

    /// True once `load` has returned at least once. Distinct from
    /// `saved == nil` because a default-disabled config is a
    /// successful load (the row genuinely doesn't exist server-
    /// side for users who haven't touched the page yet).
    public private(set) var didLoad: Bool = false

    /// Available driver types — populated by `loadTypes` before
    /// the form renders so the type picker has options.
    public private(set) var availableTypes: [String] = []

    /// Drafted form fields. `apiKeyDraft` is the WRITE buffer —
    /// empty by default (the server never returns the saved
    /// value) and only sent when the user explicitly types into
    /// the field.
    public var typeDraft: String = "openai"
    public var baseURLDraft: String = "http://localhost:11434/v1"
    public var modelDraft: String = "nomic-embed-text"
    public var dimensionsDraft: Int32 = 768
    public var apiKeyDraft: String = ""
    public var enabledDraft: Bool = false

    /// Outcomes of async actions; views render status inline.
    public private(set) var saving: Bool = false
    public private(set) var testing: Bool = false
    public private(set) var deleting: Bool = false
    public private(set) var saveError: String?
    public private(set) var testResult: ReeveEmbedderTestResult?

    /// Latest stats snapshot — drives the "X messages embedded"
    /// chip. Populated by `refreshStats`.
    public private(set) var stats: ReeveEmbedderStats?

    public init(client: ReeveClient) {
        self.client = client
    }

    /// True iff the draft differs from the saved snapshot (or no
    /// snapshot exists yet and the draft has any non-default
    /// field). Gates the Save button + the "discard?" prompt.
    public var isDirty: Bool {
        guard let saved else {
            return typeDraft != "openai"
                || baseURLDraft != "http://localhost:11434/v1"
                || modelDraft != "nomic-embed-text"
                || dimensionsDraft != 768
                || !apiKeyDraft.isEmpty
                || enabledDraft
        }
        if typeDraft != saved.type { return true }
        if baseURLDraft != saved.baseURL { return true }
        if modelDraft != saved.model { return true }
        if dimensionsDraft != saved.dimensions { return true }
        if !apiKeyDraft.isEmpty { return true }
        if enabledDraft != saved.enabled { return true }
        return false
    }

    /// Refresh the saved snapshot + reset draft fields to match.
    /// Also primes the available-types list and the stats chip.
    public func load() async {
        async let typesTask = loadTypesQuietly()
        async let statsTask = refreshStatsQuietly()
        do {
            let cfg = try await client.embedder.get()
            saved = cfg
            typeDraft = cfg.type
            baseURLDraft = cfg.baseURL
            modelDraft = cfg.model
            dimensionsDraft = cfg.dimensions
            apiKeyDraft = ""
            enabledDraft = cfg.enabled
            didLoad = true
        } catch {
            saveError = ReeveError.display(error)
        }
        _ = await (typesTask, statsTask)
    }

    /// Refresh just the stats — settings page polls this every few
    /// seconds while a backfill is in flight so the chip stays
    /// live without a full reload.
    public func refreshStats() async {
        await refreshStatsQuietly()
    }

    private func loadTypesQuietly() async {
        if let types = try? await client.embedder.listTypes() {
            availableTypes = types.sorted()
        }
    }

    private func refreshStatsQuietly() async {
        if let s = try? await client.embedder.stats() {
            stats = s
        }
    }

    /// Persist the current draft. `apiKey` has tri-state semantics
    /// — empty draft sends nil ("leave alone"), non-empty draft
    /// sends the value ("encrypt + replace"). Returns true on
    /// success so callers can route / dismiss.
    @discardableResult
    public func save() async -> Bool {
        saving = true
        defer { saving = false }
        saveError = nil
        let apiKeyParam: String? = apiKeyDraft.isEmpty ? nil : apiKeyDraft
        do {
            let cfg = try await client.embedder.update(
                type: typeDraft,
                baseURL: baseURLDraft,
                model: modelDraft,
                dimensions: dimensionsDraft,
                apiKey: apiKeyParam,
                enabled: enabledDraft
            )
            saved = cfg
            apiKeyDraft = ""
            // Stats may have flipped (worker_active toggles with
            // enabled), so pull a fresh snapshot.
            await refreshStatsQuietly()
            return true
        } catch {
            saveError = ReeveError.display(error)
            return false
        }
    }

    /// Fire a synthetic Embed call against the saved config and
    /// surface the outcome on `testResult`. Reads the server-side
    /// row; unsaved drafts are NOT honoured — the UI should
    /// disable Test until isDirty is false.
    public func test() async {
        testing = true
        defer { testing = false }
        testResult = nil
        do {
            testResult = try await client.embedder.test()
        } catch {
            testResult = ReeveEmbedderTestResult(
                ok: false,
                errorMessage: ReeveError.display(error),
                latencyMs: 0
            )
        }
    }

    /// Drop the row + snap drafts back to defaults.
    public func delete() async {
        deleting = true
        defer { deleting = false }
        saveError = nil
        do {
            try await client.embedder.delete()
            saved = nil
            typeDraft = "openai"
            baseURLDraft = "http://localhost:11434/v1"
            modelDraft = "nomic-embed-text"
            dimensionsDraft = 768
            apiKeyDraft = ""
            enabledDraft = false
            testResult = nil
            await refreshStatsQuietly()
        } catch {
            saveError = ReeveError.display(error)
        }
    }

    /// Reset draft fields to the saved snapshot (or to the default
    /// shape when no row exists). Used by "Discard changes."
    public func discardChanges() {
        guard let saved else {
            typeDraft = "openai"
            baseURLDraft = "http://localhost:11434/v1"
            modelDraft = "nomic-embed-text"
            dimensionsDraft = 768
            apiKeyDraft = ""
            enabledDraft = false
            return
        }
        typeDraft = saved.type
        baseURLDraft = saved.baseURL
        modelDraft = saved.model
        dimensionsDraft = saved.dimensions
        apiKeyDraft = ""
        enabledDraft = saved.enabled
    }
}
