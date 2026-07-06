import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runtime check for Apple's on-device `FoundationModels` framework
/// (iOS 26 / macOS 26 — Apple Intelligence-capable devices). The same
/// check covers both shells: the framework's availability semantics
/// are uniform across platforms and depend on the device + OS + the
/// user's Apple Intelligence opt-in state.
///
/// Lives in PsmithKit so the Mac and iOS settings UIs can reach the
/// same source of truth without each shell re-implementing the
/// `canImport` / `@available` dance. View code reads
/// `AppleFoundation.availability` and renders disabled / enabled
/// accordingly; the actual `LocalTitler` impls (`AppleFoundationTitler`
/// in each shell) defer to this for their own `isAvailable` answer.
public enum AppleFoundation {
    /// Three-way result: explicitly available, explicitly unavailable
    /// with a system-supplied reason, or "this device / OS doesn't
    /// support FoundationModels at all" (older OS, or built against
    /// an SDK predating the framework).
    ///
    /// Distinguishing `unavailable(reason:)` from `notSupported` lets
    /// the UI message be specific — "Apple Intelligence isn't enabled"
    /// reads better than "not available" when the user could fix it
    /// in System Settings.
    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(reason: String)
        case notSupported
    }

    /// Snapshot read on every callsite. Cheap — the underlying
    /// `SystemLanguageModel.default.availability` is an in-process
    /// flag the framework keeps current as Apple Intelligence
    /// downloads / settings change.
    public static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reason: String(describing: reason))
            }
        } else {
            return .notSupported
        }
        #else
        return .notSupported
        #endif
    }

    /// Convenience for the common "is it usable right now" question.
    public static var isAvailable: Bool {
        availability == .available
    }

    /// Short user-facing label describing the current state. Used by
    /// settings views to render "not available on this device" / "not
    /// available — Apple Intelligence is downloading" / etc. Returns
    /// nil when available (no message needed).
    public static var unavailabilityMessage: String? {
        switch availability {
        case .available:
            return nil
        case .notSupported:
            return "Not available on this device"
        case .unavailable(let reason):
            return "Not available — \(reason)"
        }
    }
}
