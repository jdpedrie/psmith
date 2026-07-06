import Foundation

/// Per-conversation composer-draft persistence. Backed by
/// UserDefaults — the payload is short text the user typed but
/// hasn't sent, and we want zero round-trip friction reading it
/// back when they reopen the conversation. SwiftData would be
/// overkill: there's no querying, no migration shape, and the
/// per-key write is already memory-mapped and trivially cheap.
///
/// Keyed on conversation ID so each conversation keeps its own
/// scratchpad. Cleared on send() success so the user doesn't see
/// a stale draft after the message goes out.
public enum DraftStore {
    private static func key(for conversationID: String) -> String {
        "psmith.draft." + conversationID
    }

    public static func load(conversationID: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key(for: conversationID))
        // Treat empty saved drafts as absence — the composer's
        // restore path skips the assignment, leaving its own empty
        // initial value alone (cosmetic; same end result).
        return (v?.isEmpty ?? true) ? nil : v
    }

    public static func save(conversationID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty draft = no draft. Removing the key keeps
            // UserDefaults from accumulating one entry per
            // conversation the user ever opened.
            clear(conversationID: conversationID)
        } else {
            UserDefaults.standard.set(text, forKey: key(for: conversationID))
        }
    }

    public static func clear(conversationID: String) {
        UserDefaults.standard.removeObject(forKey: key(for: conversationID))
    }
}
