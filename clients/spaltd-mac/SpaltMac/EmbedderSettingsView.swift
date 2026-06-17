import SwiftUI
import SpaltKit

/// Mac settings panel for the per-user embedder + memory-search
/// integration. Mirrors LangfuseSettingsView's three-block layout
/// (Connection / State / Danger zone) so the two settings pages
/// feel like siblings. Auto-loads on appear; saves are inline via
/// the Save bar that appears above the form when isDirty.
struct EmbedderSettingsView: View {
    @State private var model: EmbedderViewModel
    @State private var revealAPIKey = false
    @State private var showingDeleteConfirm = false

    init(client: SpaltClient) {
        _model = State(wrappedValue: EmbedderViewModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !model.didLoad {
                    ProgressView().padding(.top, 40)
                } else {
                    driverSection
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
            Text("Embedder")
                .font(.title2.weight(.semibold))
            Text("Run every message through a vector embedder and let the memory plugin pull older context back into long conversations. Per-user; off by default. API keys are encrypted at rest.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Driver

    private var driverSection: some View {
        sectionCard("Driver") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Type", selection: $model.typeDraft) {
                    ForEach(model.availableTypes, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
                Text("\"openai\" works against real OpenAI, Ollama via /v1/embeddings, Voyage, Together, or any OpenAI-compatible API.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        sectionCard("Connection") {
            VStack(alignment: .leading, spacing: 14) {
                fieldRow(
                    title: "Base URL",
                    description: "Ends with /v1. The driver appends \"/embeddings\".",
                    field: TextField("https://api.openai.com/v1", text: $model.baseURLDraft)
                        .textFieldStyle(.roundedBorder)
                )
                fieldRow(
                    title: "Model",
                    description: "nomic-embed-text (Ollama), text-embedding-3-small, etc.",
                    field: TextField("text-embedding-3-small", text: $model.modelDraft)
                        .textFieldStyle(.roundedBorder)
                )
                fieldRow(
                    title: "Dimensions",
                    description: "Must match the model: nomic-embed-text → 768, text-embedding-3-small → 1536, text-embedding-3-large → 3072.",
                    field: Stepper(
                        value: $model.dimensionsDraft,
                        in: 1...8192
                    ) {
                        Text("\(model.dimensionsDraft)")
                            .monospacedDigit()
                    }
                )
                apiKeyField
            }
        }
    }

    @ViewBuilder
    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API key").font(.callout.weight(.medium))
            Text("Leave empty for local Ollama (no auth). Encrypted at rest; the server never echoes the saved value back.")
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
    }

    private var apiKeyPlaceholder: String {
        model.saved?.apiKeySet == true ? "Replace existing key…" : "sk-…"
    }

    // MARK: - State

    private var stateSection: some View {
        sectionCard("State") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use this embedder", isOn: $model.enabledDraft)
                if let stats = model.stats {
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .foregroundStyle(.tertiary)
                        Text("\(stats.unembeddedCount) message\(stats.unembeddedCount == 1 ? "" : "s") pending")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        if stats.workerActive {
                            Text("Worker active")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        } else {
                            Text("Worker idle")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                if model.saved != nil, !model.isDirty {
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.test() }
                        } label: {
                            if model.testing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Pinging…")
                                }
                            } else {
                                Label("Test connection", systemImage: "bolt.horizontal")
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(model.testing)
                        Text("Sends one Embed(\"ping\") through the saved config.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func testResultBanner(_ r: SpaltEmbedderTestResult) -> some View {
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
        .padding(10)
        .background(
            (r.ok ? Color.green : Color.red).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8))
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
                Text("Delete removes the row entirely. Already-embedded messages stay searchable; toggle off above instead if you want to pause embedding without forgetting the credentials.")
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
