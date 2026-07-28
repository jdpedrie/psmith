import Connect
import Foundation
import Testing

@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 integration tests for profile export and import against a real
/// psmithd subprocess.
///
/// The sharing path crosses an account boundary, which no single-user test can
/// exercise: these spin up two fresh users and move a bundle between them, the
/// way the feature is actually used.
@Suite("ProfileSharing", .serialized)
struct ProfileSharingTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    @Test("a profile exported by one user imports for another")
    func roundTripAcrossAccounts() async throws {
        let (sender, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-src")
        let (recipient, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-dst")

        var patch = Fixtures.minimalProfilePatch(name: "Shared Assistant")
        patch.systemMessage = "be concise"
        let source = try await sender.profiles.create(patch)

        let bundle = try await sender.profiles.exportProfile(id: source.id)
        #expect(!bundle.payload.isEmpty)
        #expect(bundle.suggestedFilename.hasSuffix(".psmithprofile"))

        let result = try await recipient.profiles.importProfile(payload: bundle.payload)
        #expect(result.profiles.count == 1)

        let imported = try #require(result.profiles.first)
        #expect(imported.name == "Shared Assistant")
        #expect(imported.systemMessage == "be concise")
        // A new row in the recipient's account, not a pointer at the sender's.
        #expect(imported.id != source.id)

        let visible = try await recipient.profiles.list()
        #expect(visible.contains { $0.id == imported.id })
    }

    @Test("export flattens the parent chain by default")
    func flattenIsTheDefault() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-flat")

        var basePatch = Fixtures.minimalProfilePatch(name: "Base Layer")
        basePatch.systemMessage = "inherited instruction"
        basePatch.parentOnly = true
        let base = try await client.profiles.create(basePatch)

        var leafPatch = Fixtures.minimalProfilePatch(name: "Leaf Layer")
        leafPatch.parentProfileID = base.id
        let leaf = try await client.profiles.create(leafPatch)

        // Import back into the same account: the names collide, which also
        // exercises the rename path.
        let bundle = try await client.profiles.exportProfile(id: leaf.id)
        let result = try await client.profiles.importProfile(payload: bundle.payload)

        #expect(result.profiles.count == 1)
        let imported = try #require(result.profiles.first)
        // The inherited value came across even though its source profile did not.
        #expect(imported.systemMessage == "inherited instruction")
        #expect(imported.parentProfileID == nil)
        #expect(result.renamed.count == 1)
        #expect(result.warnings.contains { $0.kind == .renamed })
    }

    @Test("preserveChain keeps the ancestors as separate profiles")
    func preserveChainKeepsStructure() async throws {
        let (sender, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-chain-src")
        let (recipient, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-chain-dst")

        var basePatch = Fixtures.minimalProfilePatch(name: "Chain Base")
        basePatch.parentOnly = true
        let base = try await sender.profiles.create(basePatch)

        var leafPatch = Fixtures.minimalProfilePatch(name: "Chain Leaf")
        leafPatch.parentProfileID = base.id
        let leaf = try await sender.profiles.create(leafPatch)

        let bundle = try await sender.profiles.exportProfile(id: leaf.id, preserveChain: true)
        let result = try await recipient.profiles.importProfile(payload: bundle.payload)

        #expect(result.profiles.count == 2)
        let importedBase = try #require(result.profiles.first)
        let importedLeaf = try #require(result.profiles.last)
        #expect(importedBase.name == "Chain Base")
        #expect(importedLeaf.name == "Chain Leaf")
        // Rewired onto the row we just created, not the sender's.
        #expect(importedLeaf.parentProfileID == importedBase.id)
        #expect(importedLeaf.parentProfileID != base.id)
    }

    @Test("a dry run reports outcomes without creating anything")
    func dryRunWritesNothing() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-dry")

        let source = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "Preview Me"))
        let bundle = try await client.profiles.exportProfile(id: source.id)

        let before = try await client.profiles.list().count
        let preview = try await client.profiles.importProfile(payload: bundle.payload, dryRun: true)
        let after = try await client.profiles.list().count

        #expect(preview.profiles.isEmpty)
        #expect(after == before)
        // The name collides with the profile we just made, so the preview
        // should say what it would be renamed to.
        #expect(preview.renamed == ["Preview Me (2)"])
    }

    @Test("importing something that is not a bundle fails clearly")
    func rejectsForeignBytes() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-bad")

        await #expect(throws: (any Error).self) {
            _ = try await client.profiles.importProfile(payload: Data("definitely not a bundle".utf8))
        }
    }

    @Test("one user cannot export another's profile")
    func exportIsOwnerOnly() async throws {
        let (owner, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-owner")
        let (stranger, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-stranger")

        let secret = try await owner.profiles.create(Fixtures.minimalProfilePatch(name: "Private"))

        await #expect(throws: (any Error).self) {
            _ = try await stranger.profiles.exportProfile(id: secret.id)
        }
    }

    @Test("the export tells the sharer which credentials were withheld")
    func noticesNameWhatWasStripped() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "share-notice")

        let profile = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "Searcher"))
        // brave_search's api_key is a Global field, so a profile-level value
        // for it must not travel.
        _ = try await client.profiles.setProfilePlugins(
            profileID: profile.id,
            plugins: [
                PsmithProfilePlugin(
                    pluginName: "brave_search",
                    ordinal: 0,
                    config: Data(#"{"api_key":"BSA-should-not-travel","default_count":5}"#.utf8),
                    disabled: false
                )
            ]
        )

        let bundle = try await client.profiles.exportProfile(id: profile.id)

        let raw = String(decoding: bundle.payload, as: UTF8.self)
        #expect(!raw.contains("BSA-should-not-travel"))
        #expect(!bundle.notices.isEmpty)
    }
}
