import Foundation
import Testing
import Connect
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 coverage for the capability probe: the RPC round-trip and the rule
/// that makes it safe to run, which is that it can only ever switch a
/// capability on.
@Suite("CapabilityProbe", .serialized)
struct CapabilityProbeTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    /// A dry run reports what it would do and writes nothing. This is the
    /// default, so it is the behaviour most users will actually get.
    @Test("a dry run changes nothing")
    func dryRunWritesNothing() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "probe-dry")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "ok")

        let (_, before) = try await client.modelProviders.get(id: seeded.provider.id)
        let target = try #require(before.first)

        let probe = try await client.modelProviders.probeModelCapabilities(
            providerID: seeded.provider.id,
            modelID: target.modelID
        )
        #expect(!probe.results.isEmpty)

        let (_, after) = try await client.modelProviders.get(id: seeded.provider.id)
        let same = try #require(after.first(where: { $0.modelID == target.modelID }))
        #expect(same.capabilities?.toolUse == target.capabilities?.toolUse)
        #expect(same.capabilities?.vision == target.capabilities?.vision)
    }

    /// Every capability is accounted for. A capability with no probe and no
    /// stated skip would silently never be checked, which reads to a user as
    /// "we checked and found nothing".
    @Test("every capability is reported")
    func everyCapabilityReported() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "probe-cover")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "ok")
        let (_, models) = try await client.modelProviders.get(id: seeded.provider.id)
        let target = try #require(models.first)

        let probe = try await client.modelProviders.probeModelCapabilities(
            providerID: seeded.provider.id, modelID: target.modelID
        )
        let reported = Set(probe.results.map(\.capability))
        for name in ["streaming", "thinking", "tool_use", "vision", "prompt_caching", "generates_images"] {
            #expect(reported.contains(name), "no result for \(name)")
        }
    }

    /// The two capabilities we decline to probe say so, rather than coming
    /// back as an ordinary negative.
    @Test("skipped capabilities are labelled skipped")
    func skippedAreLabelled() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "probe-skip")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "ok")
        let (_, models) = try await client.modelProviders.get(id: seeded.provider.id)
        let target = try #require(models.first)

        let probe = try await client.modelProviders.probeModelCapabilities(
            providerID: seeded.provider.id, modelID: target.modelID
        )
        for name in ["prompt_caching", "generates_images"] {
            let r = try #require(probe.results.first(where: { $0.capability == name }))
            #expect(r.outcome == .skipped)
            #expect(!r.detail.isEmpty, "\(name) should say why it was skipped")
        }
    }

    @Test("probing a model that is not enabled fails")
    func unknownModelFails() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "probe-404")
        let seeded = try await Fixtures.seedReadyToChat(client: client, replyText: "ok")

        await #expect(throws: (any Error).self) {
            _ = try await client.modelProviders.probeModelCapabilities(
                providerID: seeded.provider.id,
                modelID: "no-such-model"
            )
        }
    }
}
