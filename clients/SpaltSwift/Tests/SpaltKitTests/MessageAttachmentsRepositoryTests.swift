import Foundation
import Testing
@testable import SpaltKit
import SpaltKitTestHarness

/// Regression: photos uploaded then sent via SendMessage must surface on
/// both the SendMessage userMessage echo AND on a subsequent listMessages
/// call (the path iOS uses to render chat history). The user reports
/// photos visible at compose time but missing in history — this test
/// pins the wire shape end-to-end.
@Suite("MessageAttachments (Layer 1)", .serialized)
struct MessageAttachmentsRepositoryTests {
    let server: TestSpaltdServer

    init() throws {
        self.server = try TestSpaltdServer.shared()
    }

    @Test("listMessages returns attachments on user message")
    func listMessagesReturnsAttachments() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "msg-attach-list")
        let (fake, _, _, profile) = try await Fixtures.seedReadyToChat(client: client)
        _ = fake

        // 1×1 PNG — smallest valid image bytes that pass the server's
        // mime check.
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        let file = try await client.files.upload(
            data: png, mimeType: "image/png", originalFilename: "test.png")

        let conv = try await client.conversations.create(
            profileID: profile.id, title: "attach-test")

        // 1. SendMessage with the file — server should echo attachments
        // on the userMessage.
        let (userMsg, _) = try await client.conversations.sendMessage(
            conversationID: conv.id,
            content: "look at this",
            attachmentFileIDs: [file.id]
        )
        #expect(userMsg.attachments.count == 1,
                "SendMessage userMessage missing attachments")
        #expect(userMsg.attachments.first?.kind == "image",
                "SendMessage attachment kind: got \(userMsg.attachments.first?.kind ?? "?")")
        #expect(userMsg.attachments.first?.fileID == file.id)

        // 2. listMessages on the active context should also surface
        // attachments — this is the path that renders chat history.
        let (_, ctx) = try await client.conversations.get(id: conv.id)
        let history = try await client.conversations.listMessages(contextID: ctx.id)
        guard let historyUser = history.first(where: { $0.role == .user && $0.content == "look at this" }) else {
            Issue.record("user message 'look at this' missing from listMessages history (got \(history.count) rows)")
            return
        }
        #expect(historyUser.attachments.count == 1,
                "listMessages user message missing attachments — this is the chat-history bug")
        #expect(historyUser.attachments.first?.kind == "image")
        #expect(historyUser.attachments.first?.fileID == file.id)

        // 3. listMessages fullTree (branch-switcher path) — should
        // also surface attachments.
        let tree = try await client.conversations.listMessages(
            contextID: ctx.id, fullTree: true)
        guard let treeUser = tree.first(where: { $0.role == .user && $0.content == "look at this" }) else {
            Issue.record("user message missing from fullTree (got \(tree.count) rows)")
            return
        }
        #expect(treeUser.attachments.count == 1,
                "fullTree user message missing attachments")
    }

    @Test("signedURL fetches actual bytes")
    func signedURLFetchesBytes() async throws {
        let (client, _) = try await TestSession.freshUser(
            server: server, usernamePrefix: "msg-attach-signed")
        _ = try await Fixtures.seedReadyToChat(client: client)

        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        let file = try await client.files.upload(
            data: png, mimeType: "image/png", originalFilename: "test.png")

        let url = try await client.files.signedURL(fileID: file.id)
        // Fetch the bytes — this is what AsyncImage does behind the
        // scenes. A failure here means the chip would render an
        // error glyph in the app even when attachments are present.
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            Issue.record("non-HTTP response: \(response)")
            return
        }
        #expect(http.statusCode == 200,
                "signed URL fetch failed: status=\(http.statusCode)")
        #expect(data == png, "bytes mismatch on signed URL fetch")
    }
}
