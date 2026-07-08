import SwiftUI
import PsmithKit

/// iOS Speech settings — synthesis kind, voice/model/speed, base
/// URL + credential for cloud kinds, test button. Same
/// Form-of-Sections shape as Embedder. apple_local (on-device) is
/// the default and needs nothing beyond an optional voice.
struct SpeechDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SpeechSettingsModel?
    @State private var revealAPIKey = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        Group {
            if let model {
                form(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Speech")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let m = SpeechSettingsModel(client: app.client)
                model = m
                await m.load()
            }
        }
    }

    @ViewBuilder
    private func form(model: SpeechSettingsModel) -> some View {
        Form {
            Section {
                Picker("Kind", selection: bindKind(model)) {
                    ForEach(model.availableKinds, id: \.self) { k in
                        Text(kindLabel(k)).tag(k)
                    }
                }
            } header: {
                Text("Synthesis")
            } footer: {
                Text(kindFooter(model.kindDraft))
            }

            Section {
                TextField(voicePlaceholder(model.kindDraft), text: bindVoice(model))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !model.isAppleLocalDraft {
                    TextField(modelPlaceholder(model.kindDraft), text: bindModel(model))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text(String(format: "%.1f×", model.speedDraft))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: bindSpeed(model), in: 0.7...1.5, step: 0.1)
                }
            } header: {
                Text("Voice")
            }

            if model.kindDraft == "openai-compatible" {
                Section {
                    TextField("https://api.openai.com", text: bindBaseURL(model))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Base URL")
                } footer: {
                    Text("Leave empty for OpenAI. Point at a self-hosted server (Kokoro, Piper, XTTS via an OpenAI-compatible bridge) to synthesize for free — the driver appends /v1/audio/speech.")
                }
            }

            if !model.isAppleLocalDraft {
                Section {
                    HStack {
                        if revealAPIKey {
                            TextField(apiKeyPlaceholder(model), text: bindAPIKey(model))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else {
                            SecureField(apiKeyPlaceholder(model), text: bindAPIKey(model))
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
                    if !model.availableProviders.isEmpty {
                        Picker("Reuse provider credential", selection: bindProviderRef(model)) {
                            Text("None").tag("")
                            ForEach(model.availableProviders, id: \.id) { p in
                                Text(p.label).tag(p.id)
                            }
                        }
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    Text("A key typed here wins over the provider reference. Reusing a chat provider's credential also attributes synthesis cost to it on the Cost screen.")
                }
            }

            if model.isDirty {
                Section {
                    Button {
                        Task { _ = await model.save() }
                    } label: {
                        if model.saving {
                            HStack { ProgressView(); Text("Saving…") }
                        } else {
                            Text("Save changes").bold()
                        }
                    }
                    .disabled(model.saving)
                    Button("Discard changes", role: .cancel) {
                        model.discardChanges()
                    }
                }
            }

            if !model.isDirty, let saved = model.saved, !saved.isAppleLocal {
                Section {
                    Button {
                        Task { await model.test() }
                    } label: {
                        if model.testing {
                            HStack { ProgressView(); Text("Synthesizing…") }
                        } else {
                            Label("Test synthesis", systemImage: "waveform")
                        }
                    }
                    .disabled(model.testing)
                    if let r = model.testResult {
                        testResultRow(r)
                    }
                } footer: {
                    Text("Synthesizes one short phrase through the saved config.")
                }
            }

            if let err = model.saveError {
                Section {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let saved = model.saved, !saved.isAppleLocal {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        if model.deleting {
                            HStack { ProgressView(); Text("Deleting…") }
                        } else {
                            Label("Reset to on-device", systemImage: "trash")
                        }
                    }
                    .disabled(model.deleting)
                } footer: {
                    Text("Removes the configuration and credentials. Read-aloud falls back to the on-device voice.")
                }
            }
        }
        .confirmationDialog(
            "Reset speech configuration?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { await model.delete() }
            }
        } message: {
            Text("Credentials are forgotten. Playback switches to the on-device voice.")
        }
    }

    @ViewBuilder
    private func testResultRow(_ r: PsmithSpeechTestResult) -> some View {
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
    }

    // MARK: - Copy helpers

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
            return "Synthesized on this device. Free, works offline, no configuration."
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

    private func apiKeyPlaceholder(_ model: SpeechSettingsModel) -> String {
        model.saved?.apiKeySet == true ? "Replace existing key…" : "API key"
    }

    // MARK: - Bindings

    private func bindKind(_ model: SpeechSettingsModel) -> Binding<String> {
        Binding(get: { model.kindDraft }, set: { model.kindDraft = $0 })
    }
    private func bindVoice(_ model: SpeechSettingsModel) -> Binding<String> {
        Binding(get: { model.voiceDraft }, set: { model.voiceDraft = $0 })
    }
    private func bindModel(_ model: SpeechSettingsModel) -> Binding<String> {
        Binding(get: { model.modelDraft }, set: { model.modelDraft = $0 })
    }
    private func bindSpeed(_ model: SpeechSettingsModel) -> Binding<Double> {
        Binding(get: { model.speedDraft }, set: { model.speedDraft = $0 })
    }
    private func bindBaseURL(_ model: SpeechSettingsModel) -> Binding<String> {
        Binding(get: { model.baseURLDraft }, set: { model.baseURLDraft = $0 })
    }
    private func bindAPIKey(_ model: SpeechSettingsModel) -> Binding<String> {
        Binding(get: { model.apiKeyDraft }, set: { model.apiKeyDraft = $0 })
    }
    private func bindProviderRef(_ model: SpeechSettingsModel) -> Binding<String> {
        Binding(get: { model.providerRefDraft }, set: { model.providerRefDraft = $0 })
    }
}
