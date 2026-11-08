import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Speech (board SettingsSpeech): how replies are read aloud.
/// On-device (Apple) is the default and needs nothing but an optional
/// voice; the cloud kinds add a model, an endpoint and a credential.
/// Whether replies speak as they arrive is this device's own setting.
struct SettingsSpeech: View {
    @Environment(AppModel.self) private var app
    @State private var model: SpeechSettingsModel?
    @State private var confirmingReset = false
    @AppStorage(SpeechPreferences.autoSpeakKey) private var autoSpeak = false

    var body: some View {
        Group {
            if let model {
                SettingsSpeechScreen(
                    kind: Binding(get: { model.kindDraft }, set: { model.kindDraft = $0 }),
                    voice: Binding(get: { model.voiceDraft }, set: { model.voiceDraft = $0 }),
                    modelName: Binding(get: { model.modelDraft }, set: { model.modelDraft = $0 }),
                    speed: Binding(get: { model.speedDraft }, set: { model.speedDraft = $0 }),
                    baseURL: Binding(get: { model.baseURLDraft }, set: { model.baseURLDraft = $0 }),
                    apiKey: Binding(get: { model.apiKeyDraft }, set: { model.apiKeyDraft = $0 }),
                    providerRef: Binding(get: { model.providerRefDraft }, set: { model.providerRefDraft = $0 }),
                    autoSpeak: $autoSpeak,
                    availableKinds: model.availableKinds,
                    availableProviders: model.availableProviders.map { SpeechProviderOption(id: $0.id, label: $0.label) },
                    saved: model.saved,
                    isDirty: model.isDirty,
                    saving: model.saving,
                    testing: model.testing,
                    deleting: model.deleting,
                    saveError: model.saveError,
                    testResult: model.testResult.map { SpeechTestOutcome(ok: $0.ok, errorMessage: $0.errorMessage, latencyMs: $0.latencyMs, audioBytes: $0.audioBytes) },
                    confirmingReset: $confirmingReset,
                    onSave: { Task { _ = await model.save() } },
                    onRevert: { model.discardChanges() },
                    onRemoveKey: { Task { await model.clearAPIKey() } },
                    onTest: { Task { await model.test() } },
                    onReset: { Task { await model.delete() } }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(IK.settingsGround.ignoresSafeArea())
                    .navigationTitle("Speech")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            guard model == nil else { return }
            let m = SpeechSettingsModel(client: app.client)
            model = m
            await m.load()
        }
    }
}

/// A synthesis test's outcome, as the page shows it.
struct SpeechTestOutcome: Hashable {
    let ok: Bool
    let errorMessage: String
    let latencyMs: Int64
    let audioBytes: Int64
}

struct SpeechProviderOption: Hashable {
    let id: String
    let label: String
}

struct SettingsSpeechScreen: View {
    @Binding var kind: String
    @Binding var voice: String
    @Binding var modelName: String
    @Binding var speed: Double
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var providerRef: String
    @Binding var autoSpeak: Bool
    let availableKinds: [String]
    let availableProviders: [SpeechProviderOption]
    let saved: PsmithSpeechConfig?
    let isDirty: Bool
    let saving: Bool
    let testing: Bool
    let deleting: Bool
    let saveError: String?
    let testResult: SpeechTestOutcome?
    @Binding var confirmingReset: Bool
    let onSave: () -> Void
    let onRevert: () -> Void
    let onRemoveKey: () -> Void
    let onTest: () -> Void
    let onReset: () -> Void
    @Environment(\.theme) private var theme

    private var appleLocal: Bool { kind == PsmithSpeechConfig.kindAppleLocal }

    private var changeCount: Int {
        guard let saved else { return 1 }
        return [kind != saved.kind, voice != saved.voice, modelName != saved.model, speed != saved.speed,
                baseURL != saved.baseURL, !apiKey.isEmpty, providerRef != saved.providerRef].filter { $0 }.count
    }

    var body: some View {
        IKSettingsPage(title: "Speech") {
            IKSFooter("Reads assistant replies aloud. Keys are encrypted at rest and audio is never stored.", top: 0)

            IKSHead("Synthesis")
            IKGroup {
                Menu {
                    Picker("Kind", selection: $kind) {
                        ForEach(availableKinds.isEmpty ? [kind] : availableKinds, id: \.self) {
                            Text(SettingsFormat.speechKind($0)).tag($0)
                        }
                    }
                } label: {
                    IKSRow {
                        Text("Kind").foregroundStyle(IK.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(SettingsFormat.speechKind(kind)).font(.system(size: 15)).foregroundStyle(IK.secondary)
                        IKChevron()
                    }
                }
                .buttonStyle(.plain)
            }

            IKSHead("Voice")
            IKGroup {
                IKSInlineField(label: "Voice", text: $voice, placeholder: voicePlaceholder)
                if !appleLocal {
                    IKSInlineField(label: "Model", text: $modelName,
                                   placeholder: kind == "openai-compatible" ? "gpt-4o-mini-tts" : "Optional")
                }
                IKSRow {
                    Text("Speed").fixedSize()
                    Slider(value: $speed, in: 0.7...1.5, step: 0.1).tint(theme.accent).accessibilityLabel("Speed")
                    Text(String(format: "%.1f×", speed)).font(.system(size: 15)).monospacedDigit()
                        .foregroundStyle(IK.secondary).frame(width: 36, alignment: .trailing)
                }
            }

            if kind == "openai-compatible" {
                IKSHead("Endpoint")
                IKGroup {
                    IKSInlineField(label: "Base URL", text: $baseURL, placeholder: "https://api.openai.com", keyboard: .URL)
                }
                IKSFooter("Leave empty for OpenAI. The driver appends /v1/audio/speech.")
            }

            if !appleLocal {
                IKSHead("Credentials")
                IKGroup {
                    IKSInlineField(label: "API key", text: $apiKey,
                                   placeholder: saved?.apiKeySet == true ? "Replace existing key" : "API key", secure: true)
                    if saved?.apiKeySet == true && apiKey.isEmpty {
                        IKSRow {
                            Image(systemName: "lock").font(.system(size: 14)).foregroundStyle(IK.green)
                            Text("Key saved").font(.system(size: 15)).foregroundStyle(IK.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(action: onRemoveKey) { Text("Remove").foregroundStyle(IK.red) }.ikButton()
                        }
                    }
                    if !availableProviders.isEmpty {
                        Menu {
                            Picker("Reuse provider key", selection: $providerRef) {
                                Text("None").tag("")
                                ForEach(availableProviders, id: \.id) { Text($0.label).tag($0.id) }
                            }
                        } label: {
                            IKSRow {
                                Text("Reuse provider key").foregroundStyle(IK.text).frame(maxWidth: .infinity, alignment: .leading)
                                Text(availableProviders.first { $0.id == providerRef }?.label ?? "None")
                                    .font(.system(size: 15)).foregroundStyle(IK.secondary)
                                IKChevron()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                IKSFooter("A saved key wins over a reused provider key. Remove it to bill synthesis to a provider instead.")
            }

            IKSHead("Playback")
            IKGroup {
                IKSSwitchRow(title: "Speak replies as they arrive", note: "This iPhone only", isOn: $autoSpeak)
            }

            if !isDirty, let saved, !saved.isAppleLocal {
                IKSHead("Test")
                IKGroup {
                    IKSRow {
                        Text("Test synthesis").frame(maxWidth: .infinity, alignment: .leading)
                        Button(testing ? "Testing…" : "Test", action: onTest).ikButton().disabled(testing)
                    }
                    if let r = testResult {
                        IKSResultRow(ok: r.ok, title: r.ok ? "Synthesis OK" : "Test failed", detail: r.errorMessage,
                                     value: testValue(r))
                    }
                }
            }
            if let saveError { IKSError(text: saveError) }

            if let saved, !saved.isAppleLocal {
                IKSDangerZone(actionTitle: "Reset to on-device",
                              question: "Reset speech to on-device?",
                              detail: "The configuration and its key are forgotten. Replies read in the on-device voice.",
                              confirmLabel: "Reset", busy: deleting, confirming: $confirmingReset, onConfirm: onReset)
            }
        } bar: {
            if isDirty {
                IKSaveBar(summary: SettingsFormat.unsaved(changeCount), canSave: !saving, onRevert: onRevert, onSave: onSave)
            }
        }
    }

    private var voicePlaceholder: String {
        switch kind {
        case PsmithSpeechConfig.kindAppleLocal: "System default"
        case "grok": "eve"
        case "openai-compatible": "alloy"
        default: "Voice"
        }
    }

    private func testValue(_ r: SpeechTestOutcome) -> String? {
        var parts: [String] = []
        if r.ok, r.audioBytes > 0 { parts.append("\(r.audioBytes.formatted()) bytes") }
        if r.latencyMs > 0 { parts.append("\(r.latencyMs) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
