import Testing
import AppKit
@testable import PsmithMac
import PsmithKit

/// A conversation in the main window end to end: sending (watched frame
/// by frame), the message actions from each row's own context menu, and
/// what each does on the server. The fake model answers "echo <word>"
/// with "Heard <word> …", streaming word by word.
@Suite(.serialized, .enabled(if: MacE2E.enabled))
@MainActor
struct ConversationE2ETests {
    @Test func aSendShowsTheMessageAndTheReplyThroughout() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Send")
            await e.mountHome()
            await e.open(conv)
            await e.sendAndWatch("mac-send")
            await e.eventually("the turn isn't on the server") {
                try await e.messages(conv).contains { $0.role == .assistant }
            }
        }
    }

    @Test func twoTurnsInARowBothStay() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Two turns")
            await e.mountHome()
            await e.open(conv)
            await e.sendAndWatch("mac-turn-1", text: "echo amber", user: "echo amber", reply: "heard amber")
            await e.sendAndWatch("mac-turn-2", text: "echo cobalt", user: "echo cobalt", reply: "heard cobalt")
            let msgs = try await e.messages(conv)
            #expect(msgs.filter { $0.role == .user }.map(\.content) == ["echo amber", "echo cobalt"])
        }
    }

    @Test func deleteFromHereRemovesTheMessageAndEverythingAfter() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Delete from here")
            try await e.seedTurn(conv, "echo maple")
            try await e.seedTurn(conv, "echo cedar")
            await e.mountHome()
            await e.open(conv, minMessages: 4)
            await e.waitFor("the tree never loaded") {
                guard let m = e.model, let first = m.messages.first(where: { $0.content == "echo cedar" }) else { return false }
                return m.hasDescendants(first.id)
            }
            await e.contextMenu(on: "echo cedar", containing: false, choose: "Delete From Here…")
            await e.waitFor("no confirm strip") { e.labels().contains { $0.contains("Delete from here?") } }
            await e.press("Delete")
            await e.eventually("the server still has the turn") {
                let msgs = try await e.messages(conv)
                return msgs.map(\.content) .contains("echo maple") && !msgs.contains { $0.content == "echo cedar" || $0.content.lowercased().contains("heard cedar") }
            }
            await e.waitFor("the transcript still shows the deleted turn") {
                !(e.model?.messages.contains { $0.content == "echo cedar" } ?? true)
            }
        }
    }

    @Test func deleteOneMessageStitchesTheRest() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Delete one")
            try await e.seedTurn(conv, "echo maple")
            try await e.seedTurn(conv, "echo cedar")
            await e.mountHome()
            await e.open(conv, minMessages: 4)
            let reply = try #require(e.model?.messages.first { $0.content.lowercased().hasPrefix("heard maple") })
            await e.contextMenu(on: String(reply.content.prefix(30)), choose: "Delete…")
            await e.waitFor("no confirm strip") { e.labels().contains { $0.contains("Delete this reply?") } }
            await e.press("Delete")
            await e.eventually("the reply is still on the server") {
                let msgs = try await e.messages(conv)
                return !msgs.contains { $0.id == reply.id } && msgs.contains { $0.content == "echo cedar" }
            }
        }
    }

    @Test func editAndSaveRewritesInPlace() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Edit save")
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)
            let user = try #require(e.model?.messages.first { $0.content == "echo maple" })
            await e.contextMenu(on: "echo maple", containing: false, choose: "Edit")
            await e.waitFor("the editor never opened") { e.model?.editingMessage?.id == user.id || editor(e) != nil }
            let view = try #require(editor(e), "no editor holding the message")
            view.window?.makeFirstResponder(view)
            view.selectAll(nil)
            view.insertText("echo willow", replacementRange: view.selectedRange())
            await e.press("Save")
            await e.eventually("the edit never reached the server") {
                try await e.messages(conv).first { $0.id == user.id }?.content == "echo willow"
            }
        }
    }

    @Test func editAndResendForksFromTheMessage() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Edit resend")
            try await e.seedTurn(conv, "echo maple")
            try await e.seedTurn(conv, "echo cedar")
            await e.mountHome()
            await e.open(conv, minMessages: 4)
            let original = try #require(e.model?.messages.first { $0.content == "echo cedar" })
            await e.contextMenu(on: "echo cedar", containing: false, choose: "Edit")
            let view = try #require(await waitForEditor(e), "no editor holding the message")
            view.window?.makeFirstResponder(view)
            view.selectAll(nil)
            view.insertText("echo birch", replacementRange: view.selectedRange())
            await e.press(containing: "Resend")
            await e.waitFor("the fork never streamed its reply", timeout: 25) {
                guard let m = e.model else { return false }
                return !m.isStreaming && m.messages.contains { $0.content.lowercased().contains("heard birch") }
            }
            let forked = try #require(e.model?.messages.first { $0.content == "echo birch" })
            #expect(forked.parentID == original.parentID)
            #expect(!(e.model?.messages.contains { $0.content == "echo cedar" } ?? true))
        }
    }

    @Test func regenerateMakesABranchAndTheSwitcherMovesBetweenThem() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Regenerate")
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)
            let first = try #require(e.model?.messages.last { $0.role == .assistant })
            await e.press("Regenerate from here (a new branch)")
            await e.waitFor("no second reply", timeout: 25) {
                guard let m = e.model, let last = m.messages.last else { return false }
                return last.role == .assistant && last.id != first.id && !m.isStreaming
            }
            await e.waitFor("no branch switcher") { e.model.flatMap { m in m.messages.last.flatMap { m.branchInfo(for: $0.id) } } != nil }
            await e.press("Previous branch")
            await e.waitFor("the switcher didn't go back to the first reply") {
                e.model?.messages.last?.id == first.id
            }
        }
    }

    @Test func unsentTextSurvivesSwitchingAway() async throws {
        try await MacE2E.run { e in
            let first = try await e.makeConversation("Draft keeper")
            let other = try await e.makeConversation("Elsewhere")
            defer { DraftStore.clear(conversationID: first.id) }
            await e.mountHome()
            await e.open(first)
            let view = try #require(e.composer(), "no composer")
            view.window?.makeFirstResponder(view)
            view.insertText("a reply I haven't finished", replacementRange: view.selectedRange())
            await e.spin(0.3)
            await e.open(other)
            await e.open(first)
            await e.waitFor("the unsent text didn't come back") { e.composer()?.string == "a reply I haven't finished" }
        }
    }

    @Test func stopEndsTheReplyEarly() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Stop")
            await e.mountHome()
            await e.open(conv)
            await e.typeAndSend("echo hemlock")
            await e.waitFor("the reply never started", timeout: 15) { e.model?.isStreaming == true }
            await e.press(containing: "Stop")
            await e.waitFor("Stop didn't end the stream", timeout: 10) { e.model?.isStreaming == false }
        }
    }

    private func editor(_ e: MacE2E) -> NSTextView? {
        guard let root = e.window?.contentView else { return nil }
        return (LiveProbe.Rig.find(root) {
            ($0 as? NSTextView)?.isEditable == true && !($0 is ComposerNSTextView) && !$0.isHiddenOrHasHiddenAncestor
        }).first as? NSTextView
    }

    private func waitForEditor(_ e: MacE2E) async -> NSTextView? {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let v = editor(e) { return v }
            await e.spin(0.1)
        }
        return nil
    }
}
