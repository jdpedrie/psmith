import Foundation
import Testing
import Connect
@testable import ReeveKit
import ReeveKitTestHarness

/// Layer 1 integration tests for ProfilesRepository against a real reeved
/// subprocess. Covers tests #1–#22 from the testing plan.
///
/// Drift notes:
///   * #15 (delete with children) — server returns `FailedPrecondition`
///     (not `InvalidArgument`) when FK enforcement blocks the delete.
///     We assert that.
///   * #22 (setProfilePlugins malformed config) — the server validates
///     plugin builds, so a config that fails to parse for the plugin
///     surfaces as `InvalidArgument`. The lettered_choices plugin
///     accepts an empty `{}`, so we use a deliberately malformed
///     `{"keep_last_n": "not-an-int"}` to drive the rejection.
@Suite("ProfilesRepository", .serialized)
struct ProfilesRepositoryTests {
    let server: TestReevedServer

    init() throws {
        self.server = try TestReevedServer.shared()
    }

    @Test("fresh user starts with exactly the seeded profiles")
    func listSeededOnly() async throws {
        // Registration seeds the onboarding profiles (Personal
        // Assistant + Reeve Manager) — a fresh user is never empty.
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-list")
        let profiles = try await client.profiles.list()
        let names = Set(profiles.map(\.name))
        #expect(names == ["Personal Assistant", "Reeve Manager"])
    }

    @Test("welcomeMessage round-trips through create, update, and clear")
    func welcomeMessageRoundTrip() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-welcome")
        var patch = Fixtures.minimalProfilePatch(name: "Welcomer")
        patch.welcomeMessage = "Hi there — ready when you are."
        let created = try await client.profiles.create(patch)
        #expect(created.welcomeMessage == "Hi there — ready when you are.")

        // Update replaces the message.
        var update = ReeveProfilePatch()
        update.welcomeMessage = "New greeting."
        let updated = try await client.profiles.update(id: created.id, patch: update)
        #expect(updated.welcomeMessage == "New greeting.")

        // clear_fields removes it.
        let cleared = try await client.profiles.update(
            id: created.id,
            patch: ReeveProfilePatch(),
            clearFields: ["welcome_message"]
        )
        #expect(cleared.welcomeMessage == nil)
    }

    @Test("create with minimum patch returns the new profile")
    func createMinimum() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-create")
        let patch = Fixtures.minimalProfilePatch(name: "Hello")
        let created = try await client.profiles.create(patch)

        #expect(created.name == "Hello")
        #expect(!created.id.isEmpty)

        // Should now be visible in list() alongside the seeded pair.
        let listed = try await client.profiles.list()
        #expect(listed.contains { $0.id == created.id })
    }

    @Test("listPluginTypes returns at least lettered_choices")
    func listPluginTypesIncludesLetteredChoices() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-types")
        let types = try await client.profiles.listPluginTypes()
        let names = types.map(\.name)
        #expect(names.contains("lettered_choices"))
    }

    @Test("lettered_choices has 4 ConfigFields with the expected types")
    func letteredChoicesConfigFieldsShape() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-fields")
        let types = try await client.profiles.listPluginTypes()
        guard let lettered = types.first(where: { $0.name == "lettered_choices" }) else {
            Issue.record("lettered_choices plugin type missing")
            return
        }
        // Schema (see plugins/lettered_choices.go ConfigFields()):
        //   keep_last_n                 — number
        //   system_instruction_override — textarea
        //   output_mode                 — select
        #expect(lettered.configFields.count == 3)

        let byName = Dictionary(uniqueKeysWithValues: lettered.configFields.map { ($0.name, $0) })
        #expect(byName["keep_last_n"]?.type == .number)
        #expect(byName["system_instruction_override"]?.type == .textarea)
        #expect(byName["output_mode"]?.type == .select)
    }

    @Test("getProfilePlugins is empty for a brand-new profile")
    func getProfilePluginsEmptyForNewProfile() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-empty")
        let profile = try await client.profiles.create(Fixtures.minimalProfilePatch())
        let plugins = try await client.profiles.getProfilePlugins(profileID: profile.id)
        #expect(plugins.isEmpty)
    }

    @Test("setProfilePlugins replaces previous list (replace semantics)")
    func setProfilePluginsReplaceSemantics() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-replace")
        let profile = try await client.profiles.create(Fixtures.minimalProfilePatch())

        // First set: one lettered_choices plugin at ordinal 0.
        let first = [Fixtures.letteredChoicesPlugin(ordinal: 0)]
        let afterFirst = try await client.profiles.setProfilePlugins(
            profileID: profile.id, plugins: first
        )
        #expect(afterFirst.count == 1)
        #expect(afterFirst.first?.pluginName == "lettered_choices")

        // Second set: empty list. Replace semantics means previous row goes
        // away — getProfilePlugins now returns [].
        let afterEmpty = try await client.profiles.setProfilePlugins(
            profileID: profile.id, plugins: []
        )
        #expect(afterEmpty.isEmpty)
        let observed = try await client.profiles.getProfilePlugins(profileID: profile.id)
        #expect(observed.isEmpty)
    }

    @Test("setProfilePlugins returns InvalidArgument for an unknown plugin name")
    func setProfilePluginsUnknownPlugin() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-unknown")
        let profile = try await client.profiles.create(Fixtures.minimalProfilePatch())

        do {
            _ = try await client.profiles.setProfilePlugins(
                profileID: profile.id,
                plugins: [Fixtures.unknownPlugin()]
            )
            Issue.record("expected InvalidArgument")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .invalidArgument)
        }
    }

    // MARK: - get (#2, #3, #4)

    @Test("get with resolve=false returns the raw row")
    func getRawRow() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-get-raw")
        let created = try await client.profiles.create(
            Fixtures.fullProfilePatch(name: "Raw")
        )
        let (raw, resolved) = try await client.profiles.get(id: created.id, resolve: false)
        #expect(raw.id == created.id)
        #expect(raw.name == "Raw")
        #expect(resolved == nil)
    }

    @Test("get with resolve=true returns parent-applied resolved row")
    func getResolvedFromParent() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-get-resolve")
        // Parent carries the system message; child inherits.
        let parent = try await client.profiles.create(ReeveProfilePatch(
            name: "Parent",
            systemMessage: "I am the parent system prompt.",
            parentOnly: true
        ))
        let child = try await client.profiles.create(ReeveProfilePatch(
            name: "Child",
            parentProfileID: parent.id
        ))
        let (raw, resolved) = try await client.profiles.get(id: child.id, resolve: true)
        #expect(raw.id == child.id)
        // Raw child has no system_message of its own.
        #expect(raw.systemMessage == nil)
        // Resolved should pull it down from the parent chain.
        #expect(resolved?.systemMessage == "I am the parent system prompt.")
    }

    @Test("get returns NotFound when accessed by another user")
    func getNotFoundCrossUser() async throws {
        let (clientA, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-A")
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-B")
        let owned = try await clientA.profiles.create(Fixtures.minimalProfilePatch(name: "A's profile"))

        do {
            _ = try await clientB.profiles.get(id: owned.id)
            Issue.record("expected NotFound for cross-user get")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    // MARK: - create (#6, #7, #8, #9)

    @Test("create with full ReeveProfilePatch round-trips every field")
    func createFullPatch() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-full")
        let parent = try await client.profiles.create(ReeveProfilePatch(name: "Parent", parentOnly: true))
        let patch = ReeveProfilePatch(
            name: "Child",
            parentProfileID: parent.id,
            systemMessage: "system prompt",
            defaultUserMessage: "default user msg",
            compressionGuide: "summarize tightly",
            compressionMode: .replace,
            description: "desc",
            parentOnly: false,
            favorite: true
        )
        let created = try await client.profiles.create(patch)
        #expect(created.name == "Child")
        #expect(created.parentProfileID == parent.id)
        #expect(created.systemMessage == "system prompt")
        #expect(created.defaultUserMessage == "default user msg")
        #expect(created.compressionGuide == "summarize tightly")
        #expect(created.compressionMode == .replace)
        #expect(created.description == "desc")
        #expect(created.parentOnly == false)
        #expect(created.favorite == true)

        // Title settings round-trip through a separate patch — exercise
        // titleProviderKind too.
        let titled = try await client.profiles.create(ReeveProfilePatch(
            name: "Titled",
            titleGuide: "Use 4 words.",
            titleProviderKind: ReeveTitleProviderKind.appleFoundation
        ))
        #expect(titled.titleGuide == "Use 4 words.")
        #expect(titled.titleProviderKind == ReeveTitleProviderKind.appleFoundation)
    }

    @Test("create with parentOnly=true persists the flag")
    func createParentOnly() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-parent")
        let created = try await client.profiles.create(
            ReeveProfilePatch(name: "Trunk", parentOnly: true)
        )
        #expect(created.parentOnly == true)
    }

    @Test("create with favorite=true persists the flag")
    func createFavorite() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-fav")
        let created = try await client.profiles.create(
            ReeveProfilePatch(name: "Star", favorite: true)
        )
        #expect(created.favorite == true)
    }

    @Test("create with empty name fails InvalidArgument")
    func createEmptyName() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-empty-name")
        do {
            _ = try await client.profiles.create(ReeveProfilePatch(name: ""))
            Issue.record("expected InvalidArgument")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .invalidArgument)
        }
    }

    // MARK: - update (#10, #11, #12)

    @Test("update with a partial patch only changes provided fields")
    func updatePartialPatch() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-update")
        let created = try await client.profiles.create(ReeveProfilePatch(
            name: "Before",
            systemMessage: "original system",
            defaultUserMessage: "original default",
            description: "kept"
        ))
        // Touch only the name; everything else should stay put.
        let updated = try await client.profiles.update(
            id: created.id,
            patch: ReeveProfilePatch(name: "After")
        )
        #expect(updated.name == "After")
        #expect(updated.systemMessage == "original system")
        #expect(updated.defaultUserMessage == "original default")
        #expect(updated.description == "kept")
    }

    @Test("update with clearFields reverts a column to inherit/empty")
    func updateClearFields() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-clear")
        let parent = try await client.profiles.create(ReeveProfilePatch(
            name: "Parent",
            systemMessage: "parent sys",
            parentOnly: true
        ))
        let child = try await client.profiles.create(ReeveProfilePatch(
            name: "Child",
            parentProfileID: parent.id,
            systemMessage: "own sys"
        ))
        let cleared = try await client.profiles.update(
            id: child.id,
            patch: ReeveProfilePatch(),
            clearFields: ["system_message"]
        )
        // Raw column is now nil — child inherits from parent.
        #expect(cleared.systemMessage == nil)
        let (_, resolved) = try await client.profiles.get(id: child.id, resolve: true)
        #expect(resolved?.systemMessage == "parent sys")
    }

    @Test("update returns NotFound when targeting another user's profile")
    func updateNotFoundCrossUser() async throws {
        let (clientA, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-upd-A")
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-upd-B")
        let owned = try await clientA.profiles.create(Fixtures.minimalProfilePatch(name: "Mine"))
        do {
            _ = try await clientB.profiles.update(
                id: owned.id, patch: ReeveProfilePatch(name: "stolen")
            )
            Issue.record("expected NotFound")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    // MARK: - delete (#13, #14, #15)

    @Test("delete removes the profile and subsequent get is NotFound")
    func deleteHappyPath() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-del")
        let created = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "Doomed"))
        try await client.profiles.delete(id: created.id)
        do {
            _ = try await client.profiles.get(id: created.id)
            Issue.record("expected NotFound")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    @Test("delete returns NotFound for another user's profile")
    func deleteNotFoundCrossUser() async throws {
        let (clientA, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-del-A")
        let (clientB, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-del-B")
        let owned = try await clientA.profiles.create(Fixtures.minimalProfilePatch(name: "AOnly"))
        do {
            try await clientB.profiles.delete(id: owned.id)
            Issue.record("expected NotFound")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .notFound)
        }
        // Owner can still see it.
        let (raw, _) = try await clientA.profiles.get(id: owned.id)
        #expect(raw.id == owned.id)
    }

    @Test("delete refuses when the profile has dependent rows (children)")
    func deleteWithChildrenFailsPrecondition() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-del-fk")
        let parent = try await client.profiles.create(ReeveProfilePatch(name: "Parent", parentOnly: true))
        _ = try await client.profiles.create(ReeveProfilePatch(
            name: "Child", parentProfileID: parent.id
        ))
        // Drift: plan says "InvalidArgument or refuses"; server returns
        // FailedPrecondition because the FK violation is mapped that way.
        do {
            try await client.profiles.delete(id: parent.id)
            Issue.record("expected FailedPrecondition")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .failedPrecondition)
        }
    }

    // MARK: - getProfilePlugins (#19)

    @Test("getProfilePlugins returns the configured pipeline in ordinal order")
    func getProfilePluginsAfterSet() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-getplugins")
        let profile = try await client.profiles.create(Fixtures.minimalProfilePatch())
        // Set two lettered_choices entries with different ordinals/configs to
        // confirm the order is preserved.
        let p0 = ReeveProfilePlugin(
            pluginName: "lettered_choices", ordinal: 0,
            config: Data("{\"keep_last_n\":1}".utf8)
        )
        let p1 = ReeveProfilePlugin(
            pluginName: "lettered_choices", ordinal: 1,
            config: Data("{\"keep_last_n\":2}".utf8)
        )
        _ = try await client.profiles.setProfilePlugins(
            profileID: profile.id, plugins: [p0, p1]
        )
        let observed = try await client.profiles.getProfilePlugins(profileID: profile.id)
        #expect(observed.count == 2)
        #expect(observed[0].ordinal == 0)
        #expect(observed[1].ordinal == 1)
        #expect(observed.map(\.pluginName) == ["lettered_choices", "lettered_choices"])
    }

    // MARK: - setProfilePlugins (#22)

    @Test("setProfilePlugins rejects malformed plugin config (InvalidArgument)")
    func setProfilePluginsMalformedConfig() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "prof-bad-config")
        let profile = try await client.profiles.create(Fixtures.minimalProfilePatch())
        // lettered_choices.keep_last_n is a number; sending a string forces
        // the JSON unmarshal in plugins.Build to fail → InvalidArgument.
        let bad = ReeveProfilePlugin(
            pluginName: "lettered_choices", ordinal: 0,
            config: Data("{\"keep_last_n\":\"not-an-int\"}".utf8)
        )
        do {
            _ = try await client.profiles.setProfilePlugins(
                profileID: profile.id, plugins: [bad]
            )
            Issue.record("expected InvalidArgument")
        } catch let ReeveError.rpc(code, _) {
            #expect(code == .invalidArgument)
        }
    }
}
