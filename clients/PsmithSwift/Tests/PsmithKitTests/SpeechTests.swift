import Foundation
import Testing
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for the speech stack: SpeechRepository config CRUD
/// against a live psmithd, SpeechSettingsModel draft/save/dirty
/// mechanics, plus pure tests for the client-side text prep and the
/// replay-cache key.
@Suite("Speech", .serialized)
@MainActor
struct SpeechTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    // MARK: - Repository

    @Test("fresh user defaults to apple_local")
    func defaultConfig() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-def")
        let cfg = try await client.speech.get()
        #expect(cfg.kind == PsmithSpeechConfig.kindAppleLocal)
        #expect(cfg.isAppleLocal)
        #expect(cfg.enabled)
        #expect(cfg.apiKeySet == false)
        #expect(cfg.normalizerVersion >= 1)
    }

    @Test("update round-trips, sparse update preserves, empty key clears")
    func updateRoundTrip() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-upd")

        var cfg = try await client.speech.update(
            kind: "grok", voice: "ara", speed: 1.2, apiKey: "xai-test-secret"
        )
        #expect(cfg.kind == "grok")
        #expect(cfg.voice == "ara")
        #expect(cfg.speed == 1.2)
        #expect(cfg.apiKeySet)

        // Sparse: voice only; kind and key survive.
        cfg = try await client.speech.update(voice: "rex")
        #expect(cfg.kind == "grok")
        #expect(cfg.voice == "rex")
        #expect(cfg.apiKeySet)

        // "" clears the key.
        cfg = try await client.speech.update(apiKey: "")
        #expect(cfg.apiKeySet == false)
    }

    @Test("unknown kind is refused")
    func unknownKind() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-bad")
        await #expect(throws: PsmithError.self) {
            _ = try await client.speech.update(kind: "shouting-into-the-void")
        }
    }

    @Test("delete restores the apple_local default")
    func deleteRestoresDefault() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-del")
        _ = try await client.speech.update(kind: "openai-compatible", voice: "alloy")
        try await client.speech.delete()
        let cfg = try await client.speech.get()
        #expect(cfg.kind == PsmithSpeechConfig.kindAppleLocal)
    }

    @Test("listKinds includes the registered drivers")
    func listKinds() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-kinds")
        let kinds = try await client.speech.listKinds()
        #expect(kinds.contains(PsmithSpeechConfig.kindAppleLocal))
        #expect(kinds.contains("grok"))
        #expect(kinds.contains("openai-compatible"))
    }

    @Test("test RPC succeeds as a no-op on the apple_local default")
    func testRPCAppleLocal() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-test")
        let result = try await client.speech.test()
        #expect(result.ok)
        #expect(result.audioBytes == 0)
    }

    @Test("synthesize on a nonexistent message maps to notFound")
    func synthesizeNotFound() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-404")
        do {
            _ = try await client.speech.synthesize(messageID: UUID().uuidString)
            Issue.record("expected a thrown error")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .notFound)
        }
    }

    // MARK: - SpeechSettingsModel

    @Test("settings model loads defaults, kinds, and stays clean")
    func settingsLoad() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-vm-load")
        let vm = SpeechSettingsModel(client: client)
        await vm.load()
        #expect(vm.didLoad)
        #expect(vm.kindDraft == PsmithSpeechConfig.kindAppleLocal)
        #expect(vm.speedDraft == 1.0)
        #expect(vm.isDirty == false)
        #expect(vm.availableKinds.contains("grok"))
    }

    @Test("settings model save clears dirty and reports apiKeySet")
    func settingsSave() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-vm-save")
        let vm = SpeechSettingsModel(client: client)
        await vm.load()

        vm.kindDraft = "grok"
        vm.voiceDraft = "eve"
        vm.speedDraft = 1.1
        vm.apiKeyDraft = "xai-vm-secret"
        #expect(vm.isDirty)

        let ok = await vm.save()
        #expect(ok, "save failed: \(vm.saveError ?? "<nil>")")
        #expect(vm.isDirty == false)
        #expect(vm.apiKeyDraft.isEmpty)
        #expect(vm.saved?.apiKeySet == true)
        #expect(vm.saved?.kind == "grok")
    }

    @Test("settings model second save without retyping key preserves it")
    func settingsSparseKeyPreserved() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-vm-tri")
        let vm = SpeechSettingsModel(client: client)
        await vm.load()
        vm.kindDraft = "grok"
        vm.apiKeyDraft = "xai-keep"
        _ = await vm.save()
        #expect(vm.saved?.apiKeySet == true)

        vm.voiceDraft = "ara"
        _ = await vm.save()
        #expect(vm.saved?.apiKeySet == true)
        #expect(vm.saved?.voice == "ara")
    }

    @Test("settings model delete snaps back to apple_local")
    func settingsDelete() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-vm-del")
        let vm = SpeechSettingsModel(client: client)
        await vm.load()
        vm.kindDraft = "openai-compatible"
        vm.baseURLDraft = "http://localhost:8880"
        _ = await vm.save()
        #expect(vm.saved?.kind == "openai-compatible")

        await vm.delete()
        #expect(vm.kindDraft == PsmithSpeechConfig.kindAppleLocal)
        #expect(vm.isDirty == false)
    }

    @Test("settings model discard resets drafts")
    func settingsDiscard() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "sp-vm-disc")
        let vm = SpeechSettingsModel(client: client)
        await vm.load()
        vm.kindDraft = "grok"
        vm.voiceDraft = "scrap"
        vm.discardChanges()
        #expect(vm.kindDraft == PsmithSpeechConfig.kindAppleLocal)
        #expect(vm.voiceDraft.isEmpty)
        #expect(vm.isDirty == false)
    }

    // MARK: - Pure: client-side text prep

    @Test("liteNormalize announces code fences and strips markers")
    func liteNormalize() {
        let input = """
        # Heading

        Here is **bold** and a [link](https://example.com) plus `code`.

        ```go
        secret()
        ```

        | a | b |
        | - | - |
        | 1 | 2 |

        Done.
        """
        let out = SpeechText.liteNormalize(input)
        #expect(out.contains("Code omitted."))
        #expect(!out.contains("secret()"))
        #expect(out.contains("Table omitted."))
        #expect(!out.contains("| a |"))
        #expect(out.contains("bold"))
        #expect(!out.contains("**"))
        #expect(out.contains("link"))
        #expect(!out.contains("example.com"))
        #expect(!out.contains("# Heading"))
        #expect(out.contains("Heading"))
        #expect(out.contains("Done."))
    }

    @Test("liteNormalize speaks image alt as announcement")
    func liteNormalizeImage() {
        let out = SpeechText.liteNormalize("Look: ![diagram](https://x/y.png) here.")
        #expect(out.contains("Image."))
        #expect(!out.contains("y.png"))
    }

    // MARK: - Pure: replay-cache key

    @Test("cacheID varies with every audio-relevant input")
    func cacheKeyComponents() {
        let base = PsmithSpeechConfig(kind: "grok", voice: "eve", normalizerVersion: 1)
        let k1 = SpeechPlaybackModel.cacheID(messageID: "m1", content: "hello", config: base)
        #expect(k1 == SpeechPlaybackModel.cacheID(messageID: "m1", content: "hello", config: base))
        #expect(k1 != SpeechPlaybackModel.cacheID(messageID: "m2", content: "hello", config: base))
        #expect(k1 != SpeechPlaybackModel.cacheID(messageID: "m1", content: "edited", config: base))
        let otherVoice = PsmithSpeechConfig(kind: "grok", voice: "ara", normalizerVersion: 1)
        #expect(k1 != SpeechPlaybackModel.cacheID(messageID: "m1", content: "hello", config: otherVoice))
        let otherNorm = PsmithSpeechConfig(kind: "grok", voice: "eve", normalizerVersion: 2)
        #expect(k1 != SpeechPlaybackModel.cacheID(messageID: "m1", content: "hello", config: otherNorm))
    }
}
