import Foundation
@_exported import ClarkKit

/// Pre-built builders + canned values used to seed common state without
/// verbose constructor calls at every test site.
public enum Fixtures {
    /// Minimal create-profile patch: just a name. Use this when a test only
    /// needs *some* profile to attach a conversation/plugin to.
    public static func minimalProfilePatch(name: String = "Test Profile") -> ClarkProfilePatch {
        ClarkProfilePatch(name: name)
    }

    /// Full-fat patch covering every optional field — used by tests that
    /// verify create() round-trips the entire shape.
    public static func fullProfilePatch(name: String = "Full Profile") -> ClarkProfilePatch {
        ClarkProfilePatch(
            name: name,
            systemMessage: "You are a helpful assistant.",
            defaultUserMessage: "Hi there.",
            compressionGuide: "Summarize concisely.",
            compressionMode: .replace,
            description: "A profile with every field set.",
            parentOnly: false,
            favorite: true
        )
    }

    /// Lettered-choices plugin attached to a profile. The server requires
    /// a non-nil JSON object as the config blob; an empty `{}` is fine
    /// because every field has a default.
    public static func letteredChoicesPlugin(
        ordinal: Int32 = 0,
        configJSON: String = "{}"
    ) -> ClarkProfilePlugin {
        ClarkProfilePlugin(
            pluginName: "lettered_choices",
            ordinal: ordinal,
            config: Data(configJSON.utf8)
        )
    }

    /// Empty-config plugin with a deliberately bogus name — used to assert
    /// the server returns InvalidArgument for unknown plugins.
    public static func unknownPlugin(ordinal: Int32 = 0) -> ClarkProfilePlugin {
        ClarkProfilePlugin(
            pluginName: "this_plugin_does_not_exist",
            ordinal: ordinal,
            config: Data("{}".utf8)
        )
    }

    /// JSON config blob for an `openai-compatible` driver pointing at the
    /// in-process FakeProvider listener. The server's openai-compatible
    /// driver requires both `api_key` and `base_url`; the fake's `/v1`
    /// endpoint serves canned `/v1/models` and `/v1/chat/completions`.
    ///
    /// Sets `use_chat_completions: true` so the driver routes through the
    /// older Chat Completions endpoint (which FakeProvider implements)
    /// instead of the newer Responses API (which it doesn't). This is the
    /// only path the in-process fake serves.
    public static func fakeProviderConfig(baseURL: URL, apiKey: String = "fake-key") -> Data {
        let json = "{\"api_key\":\"\(apiKey)\",\"base_url\":\"\(baseURL.absoluteString)\",\"use_chat_completions\":true}"
        return Data(json.utf8)
    }

    /// Boots a FakeProvider, registers it via `client.modelProviders.create`,
    /// returns both so the caller can `enableModels(...)` against the listed
    /// fake models. The FakeProvider is kept alive by the caller (typically
    /// by holding it as a local `let`) — its NWListener tears down on deinit.
    public static func seedFakeProvider(
        client: ClarkClient,
        label: String = "Fake"
    ) async throws -> (provider: ClarkUserModelProvider, fake: FakeProvider) {
        let fake = FakeProvider()
        try fake.start()
        let provider = try await client.modelProviders.create(
            type: "openai-compatible",
            label: label,
            config: fakeProviderConfig(baseURL: fake.baseURL)
        )
        return (provider, fake)
    }

    /// Boots a fake provider, enables its single model (`fake-model-1`), and
    /// creates a profile defaulting to that provider/model so subsequent
    /// `createConversation` + `sendMessage` calls have everything they need.
    /// Returns the fake (caller holds it for the test's lifetime so the
    /// NWListener stays alive), provider, model, and profile.
    ///
    /// `withCompression`: when true, the profile is also seeded with
    /// `compression_*` fields pointing at the same fake (so Compact tests
    /// can succeed without the test having to layer extra setup). Defaults
    /// to false because send-only tests don't need it.
    public static func seedReadyToChat(
        client: ClarkClient,
        profileName: String = "Test Profile",
        replyText: String = "hello",
        withCompression: Bool = false,
        compressionMode: ClarkCompressionMode? = nil
    ) async throws -> (fake: FakeProvider, provider: ClarkUserModelProvider, model: ClarkUserModel, profile: ClarkProfile) {
        let fake = FakeProvider(replyText: replyText)
        try fake.start()
        let provider = try await client.modelProviders.create(
            type: "openai-compatible",
            label: "Fake",
            config: fakeProviderConfig(baseURL: fake.baseURL)
        )
        let enabled = try await client.modelProviders.enableModels(
            providerID: provider.id, modelIDs: ["fake-model-1"]
        )
        guard let model = enabled.first else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "enableModels returned empty"
            ])
        }
        var patch = ClarkProfilePatch(
            name: profileName,
            defaultSettings: ClarkProfileDefaults(
                defaultProviderID: provider.id,
                defaultModelID: model.modelID
            )
        )
        if withCompression {
            patch.compressionGuide = "Summarize the conversation."
            patch.compressionProviderID = provider.id
            patch.compressionModelID = model.modelID
            patch.compressionMode = compressionMode
        }
        let profile = try await client.profiles.create(patch)
        return (fake, provider, model, profile)
    }

    /// Convenience JSON config for an `anthropic`-driver provider — the
    /// driver requires `api_key`, nothing else. base_url stays unset
    /// (anthropic.com is the implicit default at runtime).
    public static func anthropicConfig(apiKey: String = "fake-anthropic-key") -> Data {
        let json = "{\"api_key\":\"\(apiKey)\"}"
        return Data(json.utf8)
    }
}
