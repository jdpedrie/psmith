import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Langfuse (board SettingsLangfuse): credentials, the tracing
/// switch, a test trace and delete. Edits collect in the save bar; nothing
/// is sent until Save.
struct SettingsLangfuse: View {
    @Environment(AppModel.self) private var app
    @State private var model: LangfuseViewModel?
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let model {
                SettingsLangfuseScreen(
                    host: Binding(get: { model.hostDraft }, set: { model.hostDraft = $0 }),
                    publicKey: Binding(get: { model.publicKeyDraft }, set: { model.publicKeyDraft = $0 }),
                    secretKey: Binding(get: { model.secretKeyDraft }, set: { model.secretKeyDraft = $0 }),
                    enabled: Binding(get: { model.enabledDraft }, set: { model.enabledDraft = $0 }),
                    saved: model.saved,
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
                    .navigationTitle("Langfuse")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            guard model == nil else { return }
            let m = LangfuseViewModel(client: app.client)
            model = m
            await m.load()
        }
    }
}

struct SettingsLangfuseScreen: View {
    @Binding var host: String
    @Binding var publicKey: String
    @Binding var secretKey: String
    @Binding var enabled: Bool
    let saved: PsmithLangfuseConfig?
    let isDirty: Bool
    let saving: Bool
    let testing: Bool
    let deleting: Bool
    let saveError: String?
    let testResult: PsmithLangfuseTestResult?
    @Binding var confirmingDelete: Bool
    let onSave: () -> Void
    let onRevert: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void
    var now: Date = .now

    private var secretSaved: Bool { saved?.secretKeySet == true }
    /// Tracing needs both keys, saved or typed.
    private var canEnable: Bool { !publicKey.isEmpty && (secretSaved || !secretKey.isEmpty) }

    private var changeCount: Int {
        guard let saved else {
            return [host != "https://us.cloud.langfuse.com", !publicKey.isEmpty, !secretKey.isEmpty, enabled]
                .filter { $0 }.count
        }
        return [host != saved.host, publicKey != saved.publicKey, !secretKey.isEmpty, enabled != saved.enabled]
            .filter { $0 }.count
    }

    var body: some View {
        IKSettingsPage(title: "Langfuse") {
            IKSFooter("Mirror every assistant turn into your Langfuse instance for observability and cost tracking. Off by default. Credentials are encrypted at rest.", top: 0)

            IKSHead("Connection")
            IKGroup {
                IKSInlineField(label: "Host", text: $host, placeholder: "https://us.cloud.langfuse.com", keyboard: .URL)
                IKSInlineField(label: "Public key", text: $publicKey, placeholder: "pk-lf-…")
                IKSInlineField(label: "Secret key", text: $secretKey,
                               placeholder: secretSaved ? "Replace existing secret" : "sk-lf-…", secure: true)
            }
            HStack(alignment: .top, spacing: 5) {
                if secretSaved && secretKey.isEmpty {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(IK.green).padding(.top, 2)
                }
                Text(secretSaved && secretKey.isEmpty
                     ? "Secret saved. Both keys are in Langfuse under Settings, API Keys. The server never sends the secret back."
                     : "Both keys are in Langfuse under Settings, API Keys. The server never sends the secret back.")
            }
            .font(.system(size: 13))
            .lineSpacing(2.5)
            .foregroundStyle(IK.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 7.25, leading: 4, bottom: 1.25, trailing: 4))

            IKSHead("State")
            IKGroup {
                IKSRow {
                    IKSToggle("Send traces to Langfuse", isOn: $enabled).disabled(!canEnable)
                }
                if !canEnable {
                    IKSRow { Text("Save a public key and secret first.").font(.system(size: 13)).foregroundStyle(IK.orange) }
                }
                if let last = saved?.lastEmittedAt {
                    IKSValueRow(title: "Last successful emit",
                                value: "\(SettingsFormat.relative(last, now: now)) · \(last.formatted(date: .omitted, time: .shortened))")
                }
                if secretSaved && !isDirty {
                    IKSRow(vertical: 10) {
                        IKSTitleNote(title: "Test trace", note: "Fires one synthetic trace with the saved keys. Look for it in Traces.",
                                     noteSize: 12.5)
                        Button(testing ? "Sending…" : "Send Test", action: onTest).ikButton().disabled(testing)
                    }
                    if let r = testResult {
                        IKSResultRow(ok: r.ok, title: r.ok ? "Test trace sent" : "Test failed", detail: r.errorMessage,
                                     value: r.latencyMs > 0 ? "\(r.latencyMs) ms" : nil)
                    }
                }
            }
            if let saveError { IKSError(text: saveError) }

            if saved != nil {
                IKSDangerZone(actionTitle: "Delete configuration",
                              question: "Delete the Langfuse configuration?",
                              detail: "The keys go and tracing stops. To keep the keys and pause tracing, turn off Send traces instead.",
                              busy: deleting, confirming: $confirmingDelete, onConfirm: onDelete)
            }
        } bar: {
            if isDirty {
                IKSaveBar(summary: SettingsFormat.unsaved(changeCount), canSave: !saving, onRevert: onRevert, onSave: onSave)
                    .padding(.bottom, 0)
            }
        }
    }
}

extension SettingsFormat {
    static func unsaved(_ n: Int) -> String {
        n <= 1 ? "1 unsaved change" : "\(n) unsaved changes"
    }
}
