import SwiftUI
import PsmithKit

/// Mac settings panel for text-to-speech. Mirrors EmbedderSettingsView's
/// section-card layout; drives the shared SpeechSettingsModel. The
/// apple_local default needs nothing beyond an optional voice — the
/// cloud sections only appear for kinds that use them.
struct SpeechSettingsView: View {
    @State private var model: SpeechSettingsModel
    @State private var revealAPIKey = false
    @State private var showingResetConfirm = false
    /// Device-local: whether replies speak as they arrive. Same key
    /// SpeechPreferences reads; deliberately not part of the server
    /// config (this Mac opting in shouldn't make the phone talk).
    @AppStorage(SpeechPreferences.autoSpeakKey) private var autoSpeak = false

    init(client: PsmithClient) {
        _model = State(wrappedValue: SpeechSettingsModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !model.didLoad {
                    ProgressView().padding(.top, 40)
                } else {
                    synthesisSection
                    voiceSection
                    if model.kindDraft == "openai-compatible" {
                        baseURLSection
                    }
                    if !model.isAppleLocalDraft {
                        credentialsSection
                    }
                    playbackSection
                    if let err = model.saveError {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(10)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.isDirty {
                        saveBar
                    }
                    if !model.isDirty, let saved = model.saved, !saved.isAppleLocal {
                        testSection
                    }
                    if let saved = model.saved, !saved.isAppleLocal {
                        Divider().padding(.vertical, 8)
                        dangerZone
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speech")
                .font(.title2.weight(.semibold))
            Text("Read assistant replies aloud. On-device synthesis works with zero setup; configure a cloud or self-hosted voice for higher quality. Keys are encrypted at rest and audio is never stored.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var synthesisSection: some View {
        sectionCard("Synthesis") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Kind", selection: $model.kindDraft) {
                    ForEach(model.availableKinds, id: \.self) { k in
                        Text(kindLabel(k)).tag(k)
                    }
                }
                Text(kindFooter(model.kindDraft))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var voiceSection: some View {
        sectionCard("Voice") {
            VStack(alignment: .leading, spacing: 14) {
                fieldRow(
                    title: "Voice",
                    description: model.isAppleLocalDraft
                        ? "Empty uses the system default voice."
                        : "The provider's voice id (grok: eve, ara, …; OpenAI: alloy, …). Self-hosted servers define their own.",
                    field: TextField(voicePlaceholder(model.kindDraft), text: $model.voiceDraft)
                        .textFieldStyle(.roundedBorder)
                )
                if !model.isAppleLocalDraft {
                    fieldRow(
                        title: "Model",
                        description: "Optional synthesis model (OpenAI: gpt-4o-mini-tts).",
                        field: TextField(modelPlaceholder(model.kindDraft), text: $model.modelDraft)
                            .textFieldStyle(.roundedBorder)
                    )
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Speed").font(.callout.weight(.medium))
                        Spacer()
                        Text(String(format: "%.1f×", model.speedDraft))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.speedDraft, in: 0.7...1.5, step: 0.1)
                }
            }
        }
    }

    private var baseURLSection: some View {
        sectionCard("Endpoint") {
            fieldRow(
                title: "Base URL",
                description: "Leave empty for OpenAI. Point at a self-hosted server (Kokoro, Piper, XTTS via an OpenAI-compatible bridge) to synthesize for free — the driver appends /v1/audio/speech.",
                field: TextField("https://api.openai.com", text: $model.baseURLDraft)
                    .textFieldStyle(.roundedBorder)
            )
        }
    }

    private var credentialsSection: some View {
        sectionCard("Credentials") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key").font(.callout.weight(.medium))
                    Text("A key typed here wins over the provider reference below.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        if revealAPIKey {
                            TextField(apiKeyPlaceholder, text: $model.apiKeyDraft)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField(apiKeyPlaceholder, text: $model.apiKeyDraft)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            revealAPIKey.toggle()
                        } label: {
                            Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    if let saved = model.saved, saved.apiKeySet, model.apiKeyDraft.isEmpty {
                        Label("Key saved (replace by typing a new one)", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.availableProviders.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Reuse provider credential", selection: $model.providerRefDraft) {
                            Text("None").tag("")
                            ForEach(model.availableProviders, id: \.id) { p in
                                Text(p.label).tag(p.id)
                            }
                        }
                        Text("Reusing a chat provider's credential also attributes synthesis cost to it on the Cost screen.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var playbackSection: some View {
        sectionCard("Playback") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Speak replies as they arrive", isOn: $autoSpeak)
                Text("Reads each completed reply aloud in the conversation you're viewing. This Mac only.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var testSection: some View {
        sectionCard("Test") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        Task { await model.test() }
                    } label: {
                        if model.testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Synthesizing…")
                            }
                        } else {
                            Label("Test synthesis", systemImage: "waveform")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(model.testing)
                    Text("Synthesizes one short phrase through the saved config.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let r = model.testResult {
                    testResultBanner(r)
                }
            }
        }
    }

    @ViewBuilder
    private func testResultBanner(_ r: PsmithSpeechTestResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.ok ? "Synthesis OK" : "Test failed")
                    .font(.callout.weight(.medium))
                if !r.errorMessage.isEmpty {
                    Text(r.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if r.ok, r.audioBytes > 0 {
                    Text("\(r.audioBytes.formatted()) bytes of audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if r.latencyMs > 0 {
                Text("\(r.latencyMs)ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            (r.ok ? Color.green : Color.red).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8))
    }

    private var saveBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Discard") { model.discardChanges() }
                .buttonStyle(.borderless)
                .disabled(model.saving)
            Button {
                Task { await model.save() }
            } label: {
                if model.saving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Text("Save changes")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.saving)
        }
    }

    private var dangerZone: some View {
        sectionCard("Danger zone") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Removes the configuration and credentials. Read-aloud falls back to the on-device voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showingResetConfirm = true
                } label: {
                    if model.deleting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Resetting…")
                        }
                    } else {
                        Label("Reset to on-device", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(model.deleting)
                .confirmationDialog(
                    "Reset speech configuration?",
                    isPresented: $showingResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task { await model.delete() }
                    }
                } message: {
                    Text("Credentials are forgotten. Playback switches to the on-device voice.")
                }
            }
        }
    }

    // MARK: - Copy helpers (mirror the iOS screen)

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case PsmithSpeechConfig.kindAppleLocal: return "On-device (Apple)"
        case "grok": return "Grok (xAI)"
        case "openai-compatible": return "OpenAI-compatible"
        default: return kind
        }
    }

    private func kindFooter(_ kind: String) -> String {
        switch kind {
        case PsmithSpeechConfig.kindAppleLocal:
            return "Synthesized on this Mac. Free, works offline, no configuration."
        case "grok":
            return "xAI's voice API. Streams through your server; audio is never stored."
        case "openai-compatible":
            return "OpenAI's TTS or any self-hosted server speaking the same API."
        default:
            return ""
        }
    }

    private func voicePlaceholder(_ kind: String) -> String {
        switch kind {
        case PsmithSpeechConfig.kindAppleLocal: return "System default voice"
        case "grok": return "eve"
        case "openai-compatible": return "alloy"
        default: return "Voice"
        }
    }

    private func modelPlaceholder(_ kind: String) -> String {
        kind == "openai-compatible" ? "gpt-4o-mini-tts" : "Model (optional)"
    }

    private var apiKeyPlaceholder: String {
        model.saved?.apiKeySet == true ? "Replace existing key…" : "API key"
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func fieldRow<Field: View>(title: String, description: String, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            Text(description).font(.caption2).foregroundStyle(.tertiary)
            field
        }
    }
}
