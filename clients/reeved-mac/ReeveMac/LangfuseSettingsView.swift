import SwiftUI
import ReeveKit

/// Mac settings panel for the per-user Langfuse observability
/// integration. Three groupings:
///
///   - Connection: host + public key + secret-key field with the
///     "credentials saved" indicator + a Replace affordance.
///   - State: enable toggle + Test button (fires one synthetic
///     trace through the just-saved credentials).
///   - Danger zone: Delete (severs the integration entirely;
///     toggling enabled off keeps credentials on file).
///
/// Auto-loads on appear; saves are explicit (the secret-key write
/// path benefits from a confirm step) but the rest of the form
/// follows the codebase's "no popups" rule — the Save button
/// appears inline above the form when isDirty.
struct LangfuseSettingsView: View {
    @State private var model: LangfuseViewModel
    @State private var revealSecret = false
    @State private var showingDeleteConfirm = false
    @State private var showingReplaceConfirm = false

    init(client: ReeveClient) {
        _model = State(wrappedValue: LangfuseViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !model.didLoad {
                    ProgressView().padding(.top, 40)
                } else {
                    connectionSection
                    stateSection
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
                    if let result = model.testResult {
                        testResultBanner(result)
                    }
                    Divider().padding(.vertical, 8)
                    dangerZone
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Langfuse")
                .font(.title2.weight(.semibold))
            Text("Mirror every assistant turn into your Langfuse instance for observability + cost tracking. Per-user; off by default. Credentials are encrypted at rest.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        sectionCard("Connection") {
            VStack(alignment: .leading, spacing: 14) {
                fieldRow(
                    title: "Host",
                    description: "Langfuse Cloud (US/EU) or your self-hosted URL. Trailing slash is stripped.",
                    field: TextField("https://us.cloud.langfuse.com", text: $model.hostDraft)
                        .textFieldStyle(.roundedBorder)
                )
                fieldRow(
                    title: "Public key",
                    description: "From Langfuse → Settings → API Keys (the part starting with pk-…).",
                    field: TextField("pk-lf-…", text: $model.publicKeyDraft)
                        .textFieldStyle(.roundedBorder)
                )
                secretKeyField
            }
        }
    }

    @ViewBuilder
    private var secretKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Secret key").font(.callout.weight(.medium))
                Spacer()
                if let saved = model.saved, saved.secretKeySet, model.secretKeyDraft.isEmpty {
                    Label("Saved", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("From Langfuse → Settings → API Keys (sk-…). Stored encrypted; the server never returns it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Group {
                    if revealSecret {
                        TextField(secretPlaceholder, text: $model.secretKeyDraft)
                    } else {
                        SecureField(secretPlaceholder, text: $model.secretKeyDraft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button {
                    revealSecret.toggle()
                } label: {
                    Image(systemName: revealSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealSecret ? "Hide secret" : "Show what you're typing")
            }
        }
    }

    private var secretPlaceholder: String {
        if model.saved?.secretKeySet == true {
            return "Replace existing secret…"
        }
        return "sk-lf-…"
    }

    // MARK: - State

    private var stateSection: some View {
        sectionCard("State") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Send traces to Langfuse", isOn: $model.enabledDraft)
                    .toggleStyle(.switch)
                    .disabled(!enableEligible)
                if !enableEligible {
                    Text("Save a public key + secret first.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.test() }
                    } label: {
                        if model.testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Label("Send test trace", systemImage: "paperplane")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(!testEligible)
                    Spacer()
                }
                Text(testHelpText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var enableEligible: Bool {
        // Toggle the switch is allowed iff we have what the server
        // requires: a public key + a secret on file (either saved or
        // about to be saved on the next press).
        let havePub = !model.publicKeyDraft.isEmpty
        let haveSecret = (model.saved?.secretKeySet == true) || !model.secretKeyDraft.isEmpty
        return havePub && haveSecret
    }

    private var testEligible: Bool {
        // Test reads the server-side row, so unsaved drafts aren't
        // honoured. Disable until the form is saved + a secret exists.
        guard model.saved?.secretKeySet == true else { return false }
        return !model.isDirty && !model.testing && !model.saving
    }

    private var testHelpText: String {
        if model.isDirty { return "Save changes first to send a test." }
        if model.saved?.secretKeySet != true { return "Save a secret first to send a test." }
        return "Fires one synthetic trace using the saved credentials. Look for it in your Langfuse Traces tab."
    }

    @ViewBuilder
    private func testResultBanner(_ r: ReeveLangfuseTestResult) -> some View {
        let bg = r.ok ? Color.green.opacity(0.10) : Color.red.opacity(0.10)
        let icon = r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let tint = r.ok ? Color.green : Color.red
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(r.ok ? "Test trace sent" : "Test failed")
                    .font(.callout.weight(.semibold))
                Spacer()
                if r.latencyMs > 0 {
                    Text("\(r.latencyMs)ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !r.errorMessage.isEmpty {
                Text(r.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(bg, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Save bar

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

    // MARK: - Danger zone

    private var dangerZone: some View {
        sectionCard("Danger zone") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete removes the row entirely. Toggle off above if you want to keep the credentials saved but pause emit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showingDeleteConfirm = true
                } label: {
                    if model.deleting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Deleting…")
                        }
                    } else {
                        Label("Delete configuration", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(model.deleting || model.saved == nil)
                .confirmationDialog(
                    "Delete Langfuse configuration?",
                    isPresented: $showingDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await model.delete() }
                    }
                } message: {
                    Text("Removes credentials + drops the in-memory cache. New turns won't be traced until you reconfigure.")
                }
            }
        }
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
