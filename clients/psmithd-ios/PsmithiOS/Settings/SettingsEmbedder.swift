import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Embedder (board SettingsEmbedder): the driver, its endpoint
/// and key, the on switch and the queue. Switching driver type changes the
/// placeholders but never overwrites what's typed. Edits collect in the
/// save bar.
struct SettingsEmbedder: View {
    @Environment(AppModel.self) private var app
    @State private var model: EmbedderViewModel?
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let model {
                SettingsEmbedderScreen(
                    type: Binding(get: { model.typeDraft }, set: { model.typeDraft = $0 }),
                    baseURL: Binding(get: { model.baseURLDraft }, set: { model.baseURLDraft = $0 }),
                    modelName: Binding(get: { model.modelDraft }, set: { model.modelDraft = $0 }),
                    dimensions: Binding(get: { model.dimensionsDraft }, set: { model.dimensionsDraft = $0 }),
                    apiKey: Binding(get: { model.apiKeyDraft }, set: { model.apiKeyDraft = $0 }),
                    enabled: Binding(get: { model.enabledDraft }, set: { model.enabledDraft = $0 }),
                    availableTypes: model.availableTypes,
                    saved: model.saved,
                    stats: model.stats,
                    isDirty: model.isDirty,
                    saving: model.saving,
                    testing: model.testing,
                    deleting: model.deleting,
                    saveError: model.saveError,
                    testResult: model.testResult,
                    confirmingDelete: $confirmingDelete,
                    onSave: { Task { _ = await model.save() } },
                    onRevert: { model.discardChanges() },
                    onTest: { Task { await model.test() } },
                    onDelete: { Task { await model.delete() } }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(IK.settingsGround.ignoresSafeArea())
                    .navigationTitle("Embedder")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            guard model == nil else { return }
            let m = EmbedderViewModel(client: app.client)
            model = m
            await m.load()
        }
    }
}

struct SettingsEmbedderScreen: View {
    @Binding var type: String
    @Binding var baseURL: String
    @Binding var modelName: String
    @Binding var dimensions: Int32
    @Binding var apiKey: String
    @Binding var enabled: Bool
    let availableTypes: [String]
    let saved: PsmithEmbedderConfig?
    let stats: PsmithEmbedderStats?
    let isDirty: Bool
    let saving: Bool
    let testing: Bool
    let deleting: Bool
    let saveError: String?
    let testResult: PsmithEmbedderTestResult?
    @Binding var confirmingDelete: Bool
    let onSave: () -> Void
    let onRevert: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    private var changeCount: Int {
        guard let saved else { return 1 }
        return [type != saved.type, baseURL != saved.baseURL, modelName != saved.model,
                dimensions != saved.dimensions, !apiKey.isEmpty, enabled != saved.enabled].filter { $0 }.count
    }

    var body: some View {
        IKSettingsPage(title: "Embedder") {
            IKSFooter("Embeds every message so the memory plugin can pull older context back into long conversations. Off by default. Keys are encrypted at rest.", top: 0)

            IKSHead("Driver")
            IKGroup {
                Menu {
                    Picker("Type", selection: $type) {
                        ForEach(availableTypes.isEmpty ? [type] : availableTypes, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    IKSRow {
                        Text("Type").foregroundStyle(IK.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text(type).font(.system(size: 14, design: .monospaced)).foregroundStyle(IK.secondary)
                        IKChevron()
                    }
                }
                .buttonStyle(.plain)
            }
            IKSFooter("“openai” works with OpenAI, Ollama, Voyage, Together, or any OpenAI-compatible API.")

            IKSHead("Connection")
            IKGroup {
                IKSInlineField(label: "Base URL", text: $baseURL, placeholder: "https://api.openai.com/v1", keyboard: .URL)
                IKSInlineField(label: "Model", text: $modelName, placeholder: "text-embedding-3-small")
                IKSRow {
                    Text("Dimensions").frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(dimensions)").font(.system(size: 15)).monospacedDigit().foregroundStyle(IK.text)
                    IKSStepper(lowerLabel: "Fewer dimensions", raiseLabel: "More dimensions", segment: 44, divided: true,
                               canLower: dimensions > 1, canRaise: dimensions < 8192,
                               lower: { dimensions = max(1, dimensions - 1) },
                               raise: { dimensions = min(8192, dimensions + 1) })
                }
                IKSInlineField(label: "API key", text: $apiKey,
                               placeholder: saved?.apiKeySet == true ? "Replace existing key" : "Leave empty for Ollama",
                               secure: true)
            }
            IKSFooter("Must match the model: nomic-embed-text is 768, text-embedding-3-small 1536.")

            IKSHead("State")
            IKGroup {
                IKSRow { IKSToggle("Use this embedder", isOn: $enabled) }
                if let stats {
                    IKSRow {
                        Text("\(stats.unembeddedCount.formatted()) message\(stats.unembeddedCount == 1 ? "" : "s") pending")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(stats.workerActive ? "Worker running" : "Worker idle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IK.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(IK.wash(0.08)))
                    }
                }
                if saved != nil && !isDirty {
                    IKSRow(vertical: 10) {
                        IKSTitleNote(title: "Test connection", note: "Embeds “ping” through the saved settings.", noteSize: 12.5)
                        Button(testing ? "Testing…" : "Test", action: onTest).ikButton().disabled(testing)
                    }
                    if let r = testResult {
                        IKSResultRow(ok: r.ok, title: r.ok ? "Connection OK" : "Test failed", detail: r.errorMessage,
                                     value: r.latencyMs > 0 ? "\(r.latencyMs) ms" : nil)
                    }
                }
            }
            if let saveError { IKSError(text: saveError) }

            if saved != nil {
                IKSDangerZone(actionTitle: "Delete configuration",
                              question: "Delete the embedder configuration?",
                              detail: "New messages stop getting embedded and the memory plugin fails until you set it up again. Messages already embedded stay searchable.",
                              busy: deleting, confirming: $confirmingDelete, onConfirm: onDelete)
            }
        } bar: {
            if isDirty {
                IKSaveBar(summary: SettingsFormat.unsaved(changeCount), canSave: !saving, onRevert: onRevert, onSave: onSave)
            }
        }
    }
}
