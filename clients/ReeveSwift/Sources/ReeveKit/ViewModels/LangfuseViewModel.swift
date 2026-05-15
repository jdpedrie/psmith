import Foundation

/// Drives the Langfuse settings panel on Mac + iOS. Holds a draft
/// of the form fields, the saved-on-server snapshot for compare,
/// and the asynchronous outcomes of save / test / delete actions
/// so the views can render inline status without owning the
/// async machinery themselves.
///
/// Per Reeve's Swift conventions, this ViewModel lives in the
/// shared ReeveKit package so iOS can reuse it. Views are
/// platform-specific (Mac uses the three-column Settings shell,
/// iOS pushes a navigation screen).
@Observable
@MainActor
public final class LangfuseViewModel {
    private let client: ReeveClient

    /// Snapshot of the server-side row, refreshed by `load`. nil
    /// until the first load completes — UI shows a spinner during
    /// that window.
    public private(set) var saved: ReeveLangfuseConfig?

    /// True once `load` has returned at least once. Distinct from
    /// `saved == nil` because a default-disabled config is a
    /// successful load (the row genuinely doesn't exist server-side
    /// for users who haven't touched the page yet).
    public private(set) var didLoad: Bool = false

    /// Drafted form fields. `secretKeyDraft` is the WRITE buffer —
    /// empty by default (the server never returns the saved value)
    /// and only sent when the user explicitly types into the field.
    public var hostDraft: String = "https://us.cloud.langfuse.com"
    public var publicKeyDraft: String = ""
    public var secretKeyDraft: String = ""
    public var enabledDraft: Bool = false

    /// Outcomes of the async actions, surfaced inline so the view
    /// can render status without owning Task lifecycle.
    public private(set) var saving: Bool = false
    public private(set) var testing: Bool = false
    public private(set) var deleting: Bool = false
    public private(set) var saveError: String?
    public private(set) var testResult: ReeveLangfuseTestResult?

    public init(client: ReeveClient) {
        self.client = client
    }

    /// True iff the draft differs from the saved snapshot (or no
    /// snapshot exists yet and the draft has any field set). The
    /// settings view uses this to gate the Save button + the
    /// "discard?" prompt on dismiss.
    public var isDirty: Bool {
        guard let saved else {
            // No row on server: dirty when any draft field is non-default.
            return hostDraft != "https://us.cloud.langfuse.com"
                || !publicKeyDraft.isEmpty
                || !secretKeyDraft.isEmpty
                || enabledDraft
        }
        if hostDraft != saved.host { return true }
        if publicKeyDraft != saved.publicKey { return true }
        if !secretKeyDraft.isEmpty { return true }
        if enabledDraft != saved.enabled { return true }
        return false
    }

    /// Refresh the saved snapshot + reset draft fields to match.
    /// Idempotent; called by the view's `.task` modifier.
    public func load() async {
        do {
            let cfg = try await client.langfuse.get()
            saved = cfg
            hostDraft = cfg.host
            publicKeyDraft = cfg.publicKey
            secretKeyDraft = ""
            enabledDraft = cfg.enabled
            didLoad = true
        } catch {
            saveError = ReeveError.display(error)
        }
    }

    /// Persist the current draft. secret_key has tri-state semantics
    /// (matching the server): when the field is left empty, we send
    /// nil = "leave alone" if the user already had a key; "" =
    /// "clear" if they had no key (so toggling enabled off + saving
    /// is consistent). Returns true on success so the caller can
    /// dismiss / route.
    @discardableResult
    public func save() async -> Bool {
        saving = true
        defer { saving = false }
        saveError = nil
        let secretParam: String?
        if secretKeyDraft.isEmpty {
            // Empty draft: nil = leave-alone (preserves existing
            // saved secret) when the user is editing other fields.
            secretParam = nil
        } else {
            secretParam = secretKeyDraft
        }
        do {
            let cfg = try await client.langfuse.update(
                host: hostDraft,
                publicKey: publicKeyDraft,
                secretKey: secretParam,
                enabled: enabledDraft
            )
            saved = cfg
            secretKeyDraft = ""  // clear write-buffer; saved indicator now reflects server state
            return true
        } catch {
            saveError = ReeveError.display(error)
            return false
        }
    }

    /// Fires a synthetic trace at Langfuse using the just-saved
    /// credentials. Surfaces the outcome on `testResult`. Caller
    /// may call this without saving first; the test reads the
    /// server-side row, so unsaved drafts are NOT honoured — the
    /// UI should disable Test until isDirty is false.
    public func test() async {
        testing = true
        defer { testing = false }
        testResult = nil
        do {
            testResult = try await client.langfuse.test()
        } catch {
            testResult = ReeveLangfuseTestResult(
                ok: false,
                errorMessage: ReeveError.display(error),
                latencyMs: 0
            )
        }
    }

    /// Drop the row entirely. Resets draft + saved so the UI snaps
    /// back to the default-disabled shape.
    public func delete() async {
        deleting = true
        defer { deleting = false }
        saveError = nil
        do {
            try await client.langfuse.delete()
            saved = nil
            hostDraft = "https://us.cloud.langfuse.com"
            publicKeyDraft = ""
            secretKeyDraft = ""
            enabledDraft = false
            testResult = nil
        } catch {
            saveError = ReeveError.display(error)
        }
    }

    /// Reset draft fields to the saved snapshot. Used by the
    /// "Discard changes" affordance on the form.
    public func discardChanges() {
        guard let saved else {
            hostDraft = "https://us.cloud.langfuse.com"
            publicKeyDraft = ""
            secretKeyDraft = ""
            enabledDraft = false
            return
        }
        hostDraft = saved.host
        publicKeyDraft = saved.publicKey
        secretKeyDraft = ""
        enabledDraft = saved.enabled
    }
}
