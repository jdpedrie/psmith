import SwiftUI
import ReeveKit

/// iOS Embedder settings — driver type, endpoint, model, dim,
/// api_key, enable toggle. Same Form-of-Sections shape as Langfuse;
/// the type picker swaps the displayed defaults when the user
/// switches drivers but does not auto-overwrite anything they've
/// typed.
struct EmbedderDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var model: EmbedderViewModel?
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
        .navigationTitle("Embedder")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let m = EmbedderViewModel(client: app.client)
                model = m
                await m.load()
            }
        }
    }

    @ViewBuilder
    private func form(model: EmbedderViewModel) -> some View {
        Form {
            // Driver type picker. Sourced from listTypes() so future
            // drivers (voyage, cohere, …) drop in server-side without
            // a client release.
            Section {
                Picker("Type", selection: bindType(model)) {
                    ForEach(model.availableTypes, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
            } header: {
                Text("Driver")
            } footer: {
                Text("\"openai\" works against real OpenAI, Ollama (via /v1/embeddings), Voyage, Together, or any other OpenAI-compatible API.")
            }

            Section {
                TextField("https://api.openai.com/v1", text: bindBaseURL(model))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Base URL")
            } footer: {
                Text("Should end with /v1. The driver appends \"/embeddings\".")
            }

            Section {
                TextField("text-embedding-3-small", text: bindModel(model))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Stepper(value: bindDimensions(model), in: 1...8192) {
                    HStack {
                        Text("Dimensions")
                        Spacer()
                        Text("\(model.dimensionsDraft)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Common sizes: nomic-embed-text → 768, text-embedding-3-small → 1536, text-embedding-3-large → 3072.")
            }

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
            } header: {
                Text("API key")
            } footer: {
                Text("Stored encrypted at rest. Leave empty for local Ollama (no auth).")
            }

            Section {
                Toggle("Use this embedder", isOn: bindEnabled(model))
                if let stats = model.stats {
                    HStack {
                        Label("Pending", systemImage: "tray")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(stats.unembeddedCount) message\(stats.unembeddedCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            } header: {
                Text("State")
            } footer: {
                Text("Off = the worker stops embedding and the memory plugin reports \"search not configured\" to the model. Your existing embeddings stay on file.")
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

            if model.saved != nil, !model.isDirty {
                Section {
                    Button {
                        Task { await model.test() }
                    } label: {
                        if model.testing {
                            HStack { ProgressView(); Text("Pinging…") }
                        } else {
                            Label("Test connection", systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(model.testing)
                    if let r = model.testResult {
                        testResultRow(r)
                    }
                } footer: {
                    Text("Sends one Embed(\"ping\") through the saved config.")
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
                    Text("Removes the row. Already-embedded messages stay searchable; toggle off above instead if you want to pause embedding without forgetting the credentials.")
                }
            }
        }
        .confirmationDialog(
            "Delete embedder configuration?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.delete() }
            }
        } message: {
            Text("New messages stop getting embedded. The memory plugin will fail until reconfigured.")
        }
    }

    @ViewBuilder
    private func testResultRow(_ r: ReeveEmbedderTestResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.ok ? "Connection OK" : "Test failed")
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

    private func apiKeyPlaceholder(_ model: EmbedderViewModel) -> String {
        model.saved?.apiKeySet == true ? "Replace existing key…" : "sk-…"
    }

    private func bindType(_ model: EmbedderViewModel) -> Binding<String> {
        Binding(get: { model.typeDraft }, set: { model.typeDraft = $0 })
    }
    private func bindBaseURL(_ model: EmbedderViewModel) -> Binding<String> {
        Binding(get: { model.baseURLDraft }, set: { model.baseURLDraft = $0 })
    }
    private func bindModel(_ model: EmbedderViewModel) -> Binding<String> {
        Binding(get: { model.modelDraft }, set: { model.modelDraft = $0 })
    }
    private func bindDimensions(_ model: EmbedderViewModel) -> Binding<Int32> {
        Binding(get: { model.dimensionsDraft }, set: { model.dimensionsDraft = $0 })
    }
    private func bindAPIKey(_ model: EmbedderViewModel) -> Binding<String> {
        Binding(get: { model.apiKeyDraft }, set: { model.apiKeyDraft = $0 })
    }
    private func bindEnabled(_ model: EmbedderViewModel) -> Binding<Bool> {
        Binding(get: { model.enabledDraft }, set: { model.enabledDraft = $0 })
    }
}
