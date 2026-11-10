import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Conversations driven end to end: the real conversation screen in a real
/// navigation stack, signed in to a real psmithd whose model is a fake that
/// streams word by word. `make ios-e2e` starts both on a fresh database and
/// passes their addresses in; without it these tests skip.
///
/// Controls are driven through the calls their buttons make (a unit-test
/// host builds no accessibility tree), but everything after the call is
/// real: navigation pushes and pops, the server creates and streams, the
/// screen renders. Each test records an `E2ETimeline` of what was on screen
/// every quarter second, so a message that flickers out mid-stream fails
/// the test and leaves frames showing when.
@MainActor
final class NewConversationE2ETests: E2ETestCase {
    // MARK: Tests

    /// Choose a profile, change the model on the pushed model page, come
    /// back: the draft keeps both. Then the first send creates the
    /// conversation on the server with that profile and that model.
    func testChangingTheModelKeepsTheChosenProfileAndModel() async throws {
        let (app, convos, seeded) = try await signedIn()
        let w = mountStack(.newConversation(UUID()), app: app, convos: convos)
        let tl = E2ETimeline(name: "draft-model-change")
        defer { tl.write() }

        await waitFor("the draft never opened on the default profile and its model") {
            built.last?.0.draftProfile?.id == seeded.alpha.id && built.last?.0.selectedModelID == "model-one"
        }
        tl.sample(w, "opened", state: state())
        let (vm, ui) = built.last!

        await vm.chooseDraftProfile(seeded.beta)  // the profile card's tap
        tl.sample(w, "chose Beta", state: state())

        ui.page = .models  // the model chip's tap
        await waitFor("the model page never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        await spin(0.6)
        tl.sample(w, "model page", state: state())

        // A row's tap: select, then dismiss, which pops the page.
        await vm.selectModel(providerID: seeded.provider.id, modelID: "model-two")
        ui.page = nil
        await waitFor("the model page never popped") { E2ETimeline.navigationDepth(w) == 2 }
        await tl.record(w, timeout: 1.5, needles: [], state: state)

        XCTAssertEqual(built.count, 1, "coming back from the model page rebuilt the draft. \(state())")
        let current = built.last!.0
        XCTAssertTrue(current === vm, "the screen is showing a different view model")
        XCTAssertEqual(current.draftProfile?.id, seeded.beta.id, "the draft went back to another profile")
        XCTAssertEqual(current.selectedModelID, "model-two", "the draft dropped the model just picked")

        // The first send creates the conversation with what was chosen.
        current.draft = "Hello from the end-to-end test"
        Composer(model: current, ui: built.last!.1).send()
        await waitFor("the first send never created the conversation") { !current.isDraft }
        let (created, _) = try await app.client.conversations.get(id: current.conversation.id)
        XCTAssertEqual(created.profileID, seeded.beta.id)
        XCTAssertEqual(created.settings?.defaultProviderID, seeded.provider.id)
        XCTAssertEqual(created.settings?.defaultModelID, "model-two")
    }

    /// The user's message and the streamed reply stay on screen from the
    /// moment they appear: through the stream, its end, and the reload
    /// that follows. Recorded frame by frame.
    func testSendShowsBothMessagesThroughoutInAnExistingConversation() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await app.client.conversations.create(
            profileID: seeded.alpha.id, title: "Streaming probe",
            settings: PsmithConversationSettings(defaultProviderID: seeded.provider.id, defaultModelID: "model-one"))
        await convos.refresh()
        let w = mountStack(.conversation(conv), app: app, convos: convos)
        await waitFor("the conversation never loaded", timeout: 20) { built.last.map { !$0.0.loading && !$0.0.conversation.id.isEmpty } ?? false }
        guard !built.isEmpty else { return }
        try await sendAndWatch(w, name: "send-existing")
    }

    /// The same with history: twenty long turns already in the transcript,
    /// so the new turn lands below everything the screen loaded, where the
    /// scroll machinery has to follow it.
    func testSendShowsBothMessagesThroughoutInALongConversation() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await app.client.conversations.create(
            profileID: seeded.alpha.id, title: "Long streaming probe",
            settings: PsmithConversationSettings(defaultProviderID: seeded.provider.id, defaultModelID: "model-one"))
        // The fake streams "filler" replies (several paragraphs) in a few
        // milliseconds; wait for each to land before the next send.
        for i in 1...20 {
            _ = try await app.client.conversations.sendMessage(conversationID: conv.id, content: "filler turn \(i)")
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                let (_, ctx) = try await app.client.conversations.get(id: conv.id)
                let msgs = try await app.client.conversations.listMessages(contextID: ctx.id)
                if msgs.filter({ $0.role == .assistant }).count >= i { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await convos.refresh()
        let w = mountStack(.conversation(conv), app: app, convos: convos)
        await waitFor("the conversation never loaded", timeout: 20) {
            built.last.map { !$0.0.loading && $0.0.messages.count >= 40 } ?? false
        }
        guard !built.isEmpty else { return }
        await spin(1)
        try await sendAndWatch(w, name: "send-long")
    }

    /// The same, for the first message of a new conversation, which also
    /// creates it.
    func testSendShowsBothMessagesThroughoutInANewConversation() async throws {
        let (app, convos, seeded) = try await signedIn()
        let w = mountStack(.newConversation(UUID()), app: app, convos: convos)
        await waitFor("the draft never opened") { built.last?.0.draftProfile?.id == seeded.alpha.id }
        await waitFor("the draft never resolved its model") { built.last?.0.selectedModelID != nil }
        guard built.last?.0.selectedModelID != nil else { return }
        try await sendAndWatch(w, name: "send-new")
    }
}
