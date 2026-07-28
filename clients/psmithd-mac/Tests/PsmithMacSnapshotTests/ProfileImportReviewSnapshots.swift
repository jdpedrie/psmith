import PsmithKit
import PsmithUI
import SnapshotHarness
import SwiftUI
import Testing

/// `ProfileImportReview` is what a user reads before deciding whether to
/// accept an imported profile, and afterwards to learn what still needs
/// configuring. Its whole job is legibility, so the cases that matter are
/// the ones where text wraps or the list gets long.
///
/// Snapshotted at `minColumn` as well as default: warning messages are full
/// sentences composed server-side, and they historically get clipped rather
/// than wrapped when a settings column goes narrow.
@MainActor
struct ProfileImportReviewSnapshots {

    private func warning(
        _ kind: PsmithImportWarning.Kind,
        _ message: String,
        _ subject: String
    ) -> PsmithImportWarning {
        PsmithImportWarning(kind: kind, message: message, subject: subject)
    }

    @Test("clean import reports nothing to do")
    func noWarnings() {
        assertViewSnapshots(
            ProfileImportReview(warnings: [], profileNames: ["Coding Assistant"])
                .padding(),
            sizes: columnSizes
        )
    }

    @Test("every warning kind, longest first")
    func allWarningKinds() {
        let view = ProfileImportReview(
            warnings: [
                warning(.renamed, "You already have a profile named \"Coding Assistant\", so this one was imported as \"Coding Assistant (2)\".", "Coding Assistant"),
                warning(.pluginUnknown, "This server has no plugin called \"experimental_thing\", so it was skipped.", "experimental_thing"),
                warning(.providerMissing, "Model provider \"anthropic\" is not configured, so the default model was left unset.", "anthropic"),
                warning(.mcpServerMissing, "Missing MCP server \"Linear\", so it was not attached. Register a server with that name and add it to the profile.", "Linear"),
            ],
            renamed: ["Coding Assistant (2)"],
            profileNames: ["Coding Assistant (2)"]
        )
        .padding()

        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test("a preserved chain lists every profile it will create")
    func chainImport() {
        let view = ProfileImportReview(
            warnings: [
                warning(.providerMissing, "Model provider \"anthropic\" is not configured, so the compression model was left unset.", "anthropic")
            ],
            profileNames: ["Base Layer", "Research", "Research (Deep)"]
        )
        .padding()

        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test("export notices name what was withheld")
    func exportNotices() {
        let view = ProfileExportNotices(notices: [
            "Brave Search: API key not included (credentials never leave this server). The recipient will need to supply their own.",
            "The MCP server \"Linear\" is referenced by name only. Its command, environment and headers stay on this server, so whoever imports this will need their own \"Linear\" entry.",
        ])
        .padding()

        assertViewSnapshots(view, sizes: columnSizes)
    }
}
