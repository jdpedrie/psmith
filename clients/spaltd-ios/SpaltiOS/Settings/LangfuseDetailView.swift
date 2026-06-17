import SwiftUI
import SpaltKit

/// iOS Langfuse — single Form with the credentials, the enable
/// toggle, and a Test affordance. Mirrors the Mac panel; layout is
/// the iOS-native list-of-Sections rather than the Mac's
/// stacked-cards. Auto-loads on appear; saves explicit (Save row
/// at the bottom of the form when isDirty).
struct LangfuseDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var model: LangfuseViewModel?
    @State private var revealSecret = false
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
        .navigationTitle("Langfuse")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let m = LangfuseViewModel(client: app.client)
                model = m
                await m.load()
            }
        }
    }

    @ViewBuilder
    private func form(model: LangfuseViewModel) -> some View {
        Form {
            Section {
                TextField("https://us.cloud.langfuse.com", text: bindHost(model))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Host")
            } footer: {
                Text("Langfuse Cloud (US/EU) or your self-hosted URL.")
            }

            Section {
                TextField("pk-lf-…", text: bindPublicKey(model))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Public key")
            } footer: {
                Text("From Langfuse → Settings → API Keys.")
            }

            Section {
                HStack {
                    if revealSecret {
                        TextField(secretPlaceholder(model), text: bindSecretKey(model))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField(secretPlaceholder(model), text: bindSecretKey(model))
                    }
                    Button {
                        revealSecret.toggle()
                    } label: {
                        Image(systemName: revealSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                if let saved = model.saved, saved.secretKeySet, model.secretKeyDraft.isEmpty {
                    Label("Secret saved (replace by typing a new one)", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Secret key")
            } footer: {
                Text("Stored encrypted at rest; the server never returns the value.")
            }

            Section {
                Toggle("Send traces to Langfuse", isOn: bindEnabled(model))
                    .disabled(!enableEligible(model))
                if !enableEligible(model) {
                    Text("Save a public key + secret first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let last = model.saved?.lastEmittedAt {
                    HStack {
                        Label("Last emit", systemImage: "clock")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(last.formatted(.relative(presentation: .numeric)))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } header: {
                Text("State")
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

            if let saved = model.saved, saved.secretKeySet, !model.isDirty {
                Section {
                    Button {
                        Task { await model.test() }
                    } label: {
                        if model.testing {
                            HStack { ProgressView(); Text("Sending…") }
                        } else {
                            Label("Send test trace", systemImage: "paperplane")
                        }
                    }
                    .disabled(model.testing)
                    if let r = model.testResult {
                        testResultRow(r)
                    }
                } footer: {
                    Text("Fires one synthetic trace using the saved credentials.")
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

            if model.saved != nil {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        if model.deleting {
                            HStack { ProgressView(); Text("Deleting…") }
                        } else {
                            Label("Delete configuration", systemImage: "trash")
                        }
                    }
                    .disabled(model.deleting)
                } footer: {
                    Text("Removes credentials entirely. Toggle off above if you want to pause without forgetting the keys.")
                }
            }
        }
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

    @ViewBuilder
    private func testResultRow(_ r: SpaltLangfuseTestResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.ok ? "Test trace sent" : "Test failed")
                    .font(.callout.weight(.medium))
                if !r.errorMessage.isEmpty {
                    Text(r.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
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

    // MARK: - Bindings + helpers

    private func enableEligible(_ model: LangfuseViewModel) -> Bool {
        let havePub = !model.publicKeyDraft.isEmpty
        let haveSecret = (model.saved?.secretKeySet == true) || !model.secretKeyDraft.isEmpty
        return havePub && haveSecret
    }

    private func secretPlaceholder(_ model: LangfuseViewModel) -> String {
        model.saved?.secretKeySet == true ? "Replace existing secret…" : "sk-lf-…"
    }

    private func bindHost(_ model: LangfuseViewModel) -> Binding<String> {
        Binding(get: { model.hostDraft }, set: { model.hostDraft = $0 })
    }
    private func bindPublicKey(_ model: LangfuseViewModel) -> Binding<String> {
        Binding(get: { model.publicKeyDraft }, set: { model.publicKeyDraft = $0 })
    }
    private func bindSecretKey(_ model: LangfuseViewModel) -> Binding<String> {
        Binding(get: { model.secretKeyDraft }, set: { model.secretKeyDraft = $0 })
    }
    private func bindEnabled(_ model: LangfuseViewModel) -> Binding<Bool> {
        Binding(get: { model.enabledDraft }, set: { model.enabledDraft = $0 })
    }
}
