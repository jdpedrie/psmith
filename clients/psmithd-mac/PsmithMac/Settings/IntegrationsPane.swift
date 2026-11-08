import SwiftUI
import PsmithKit
import EventKit
import UniformTypeIdentifiers

/// The Integrations pane (boards "Integrations · …"): Langfuse, Embedder,
/// Speech and Device tools in a list, the selected one beside it. The
/// view models live here, not in each page, so the list can show each
/// service's state and switching away doesn't drop unsaved edits.
struct IntegrationsPane: View {
    @Environment(Navigator.self) private var navigator
    @State private var langfuse: LangfuseViewModel
    @State private var embedder: EmbedderViewModel
    @State private var speech: SpeechSettingsModel
    @State private var folderSet = FilesFolderBookmark.isSet

    init(client: PsmithClient) {
        _langfuse = State(wrappedValue: LangfuseViewModel(client: client))
        _embedder = State(wrappedValue: EmbedderViewModel(client: client))
        _speech = State(wrappedValue: SpeechSettingsModel(client: client))
    }

    var body: some View {
        SKSplit {
            SKListHeader(text: "Integrations")
            ForEach(SettingsIntegration.allCases) { item in
                let on = navigator.settingsIntegration == item
                SKListItem(
                    title: item.label,
                    subtitle: item.detail,
                    selected: on,
                    action: { navigator.settingsIntegration = item },
                    lead: {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(on ? .white : SK.secondary)
                            .frame(width: 16, height: 16)
                    },
                    trail: { status(item, selected: on) }
                )
            }
        } detail: {
            switch navigator.settingsIntegration {
            case .langfuse: LangfuseDetail(model: langfuse)
            case .embedder: EmbedderDetail(model: embedder)
            case .speech: SpeechDetail(model: speech)
            case .deviceTools: DeviceToolsDetail(folderSet: $folderSet)
            }
        } bottom: {
            saveBar
        }
        .task {
            async let a: Void = langfuse.load()
            async let b: Void = embedder.load()
            async let c: Void = speech.load()
            _ = await (a, b, c)
        }
    }

    @ViewBuilder
    private func status(_ item: SettingsIntegration, selected: Bool) -> some View {
        let ink: Color? = selected ? .white : nil
        switch item {
        case .langfuse:
            if langfuse.saved?.enabled == true { onChip(selected) }
        case .embedder:
            if embedder.saved?.enabled == true { onChip(selected) }
        case .speech:
            if let saved = speech.saved, !saved.isAppleLocal {
                SKChip(text: "Cloud", color: ink ?? SK.secondary)
            }
        case .deviceTools:
            if folderSet { SKChip(text: "Folder set", color: ink ?? SK.secondary) }
        }
    }

    private func onChip(_ selected: Bool) -> SKChip {
        SKChip(text: "On", color: selected ? .white : SK.green, fill: SK.green.opacity(0.14))
    }

    @ViewBuilder
    private var saveBar: some View {
        switch navigator.settingsIntegration {
        case .langfuse where langfuse.isDirty:
            SKSaveBar(summary: Self.summary(langfuseChanges), note: langfuse.saved == nil ? nil : "Testing uses the saved settings until you save",
                      saving: langfuse.saving, onDiscard: { langfuse.discardChanges() }, onSave: { Task { _ = await langfuse.save() } })
        case .embedder where embedder.isDirty:
            SKSaveBar(summary: Self.summary(embedderChanges), saving: embedder.saving,
                      onDiscard: { embedder.discardChanges() }, onSave: { Task { _ = await embedder.save() } })
        case .speech where speech.isDirty:
            SKSaveBar(summary: Self.summary(speechChanges), saving: speech.saving,
                      onDiscard: { speech.discardChanges() }, onSave: { Task { _ = await speech.save() } })
        default:
            EmptyView()
        }
    }

    /// "Host changed", "Host and 2 more changed".
    static func summary(_ fields: [String]) -> String {
        guard let first = fields.first else { return "Unsaved changes" }
        return fields.count == 1 ? "\(first) changed" : "\(first) and \(fields.count - 1) more changed"
    }

    private var langfuseChanges: [String] {
        let s = langfuse.saved
        var out: [String] = []
        if langfuse.hostDraft != (s?.host ?? "https://us.cloud.langfuse.com") { out.append("Host") }
        if langfuse.publicKeyDraft != (s?.publicKey ?? "") { out.append("Public key") }
        if !langfuse.secretKeyDraft.isEmpty { out.append("Secret key") }
        if langfuse.enabledDraft != (s?.enabled ?? false) { out.append("Send traces") }
        return out
    }

    private var embedderChanges: [String] {
        let s = embedder.saved
        var out: [String] = []
        if embedder.enabledDraft != (s?.enabled ?? false) { out.append("Use this embedder") }
        if embedder.typeDraft != (s?.type ?? "openai") { out.append("Type") }
        if embedder.baseURLDraft != (s?.baseURL ?? "http://localhost:11434/v1") { out.append("Base URL") }
        if embedder.modelDraft != (s?.model ?? "nomic-embed-text") { out.append("Model") }
        if embedder.dimensionsDraft != (s?.dimensions ?? 768) { out.append("Dimensions") }
        if !embedder.apiKeyDraft.isEmpty { out.append("API key") }
        return out
    }

    private var speechChanges: [String] {
        let s = speech.saved
        var out: [String] = []
        if speech.kindDraft != (s?.kind ?? PsmithSpeechConfig.kindAppleLocal) { out.append("Engine") }
        if speech.voiceDraft != (s?.voice ?? "") { out.append("Voice") }
        if speech.modelDraft != (s?.model ?? "") { out.append("Model") }
        if abs(speech.speedDraft - (s.map { $0.speed == 0 ? 1 : $0.speed } ?? 1)) > 0.001 { out.append("Speed") }
        if speech.baseURLDraft != (s?.baseURL ?? "") { out.append("Base URL") }
        if !speech.apiKeyDraft.isEmpty { out.append("API key") }
        if speech.providerRefDraft != (s?.providerRef ?? "") { out.append("Reused key") }
        return out
    }
}

// MARK: - Shared pieces

private struct IntegrationHead: View {
    let title: String
    let subtitle: String
    var toggleLabel: String?
    var isOn: Binding<Bool>?
    var toggleDisabled = false

    var body: some View {
        SKPageHead(title: title, subtitle: subtitle) {
            if let toggleLabel, let isOn {
                HStack(spacing: 8) {
                    Text(toggleLabel).sk(12.5, SK.secondary)
                    Toggle(toggleLabel, isOn: isOn).skSwitch().disabled(toggleDisabled)
                }
            }
        }
    }
}

/// A test's outcome, under its button's row.
private struct TestResultLine: View {
    let ok: Bool
    let text: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: ok ? "checkmark" : "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ok ? SK.green : SK.red)
                    .frame(width: 14)
                Text(text).sk(12.5, ok ? SK.green : SK.red)
            }
            if let detail, !detail.isEmpty {
                Text(detail).sk(11.5, SK.secondary, mono: true).textSelection(.enabled).padding(.leading, 21)
            }
        }
    }
}

/// "Delete…" in its own group, confirming in place.
private struct DeleteGroup: View {
    let title: String
    let detail: String
    let button: String
    let question: String
    let consequence: String
    let confirmLabel: String
    var disabled = false
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        SKGroup {
            if confirming {
                SKRawRow(vertical: 8, horizontal: 8) {
                    SKConfirmStrip(question: question, detail: consequence, confirmLabel: confirmLabel,
                                   onCancel: { confirming = false }, onConfirm: { confirming = false; action() })
                }
            } else {
                SKRow(title, detail: detail) {
                    Button(button) { confirming = true }.skButton(.destructive).disabled(disabled)
                }
            }
        }
    }
}

private struct LoadFailed: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        SKBanner(kind: .error, title: "Couldn't load these settings", message: message) {
            Button("Retry") { Task { await retry() } }.skButton(small: true)
        }
    }
}

// MARK: - Langfuse

private struct LangfuseDetail: View {
    @Bindable var model: LangfuseViewModel

    private var canEnable: Bool {
        !model.publicKeyDraft.isEmpty && (model.saved?.secretKeySet == true || !model.secretKeyDraft.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IntegrationHead(title: "Langfuse", subtitle: "Mirrors every assistant turn into your Langfuse project. Off until you turn it on.",
                            toggleLabel: "Send traces", isOn: $model.enabledDraft, toggleDisabled: !canEnable && !model.enabledDraft)
            if !model.didLoad, let error = model.saveError {
                LoadFailed(message: error) { await model.load() }
            } else if !model.didLoad {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
            } else {
                if let error = model.saveError { SKBanner(.error, "Couldn't save", message: error) }
                SKGroup("Connection") {
                    SKRow("Host", detail: "Langfuse Cloud US or EU, or your own.") {
                        SKTextField(label: "Host", text: $model.hostDraft, placeholder: "https://us.cloud.langfuse.com", width: 300)
                    }
                    SKRow("Public key") {
                        SKTextField(label: "Public key", text: $model.publicKeyDraft, placeholder: "pk-lf-…", width: 300, mono: true)
                    }
                    SKRow("Secret key", detail: "Stored encrypted. The server never sends it back.") {
                        SKSecretField(isSaved: model.saved?.secretKeySet == true, draft: $model.secretKeyDraft)
                    }
                } trailing: {
                    SKChip.synced
                } footer: {
                    Text("Both keys are in Langfuse under Settings › API Keys.")
                }
                SKGroup("Check") {
                    if let last = model.saved?.lastEmittedAt {
                        SKRow("Last trace sent") {
                            HStack(spacing: 6) {
                                Text(last.formatted(.relative(presentation: .numeric))).sk(13)
                                Text("· \(last.formatted(date: .omitted, time: .shortened))").sk(12.5, SK.tertiary)
                            }
                        }
                    }
                    SKRow("Test trace", detail: model.isDirty ? "Save first; the test uses the saved keys." : "Sends one synthetic trace with the saved keys.") {
                        Button(model.testing ? "Sending…" : "Send Test Trace") { Task { await model.test() } }
                            .skButton()
                            .disabled(model.testing || model.isDirty || model.saved?.secretKeySet != true)
                    }
                    if let r = model.testResult {
                        SKRawRow(vertical: 8) {
                            TestResultLine(ok: r.ok, text: r.ok ? "Sent in \(r.latencyMs) ms. Look for it in your Langfuse Traces tab." : "Test failed after \(r.latencyMs) ms", detail: r.ok ? nil : r.errorMessage)
                        }
                    }
                }
                DeleteGroup(
                    title: "Delete configuration",
                    detail: "To keep the keys and pause tracing, turn off Send traces instead.",
                    button: model.deleting ? "Deleting…" : "Delete…",
                    question: "Delete the Langfuse configuration?",
                    consequence: "Removes the keys. New turns aren't traced until you set it up again.",
                    confirmLabel: "Delete",
                    disabled: model.saved == nil || model.deleting
                ) { Task { await model.delete() } }
            }
        }
    }
}

// MARK: - Embedder

private struct EmbedderDetail: View {
    @Bindable var model: EmbedderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IntegrationHead(title: "Embedder", subtitle: "Embeds every message so the memory plugin can pull older context back into long conversations.",
                            toggleLabel: "Use this embedder", isOn: $model.enabledDraft)
            if !model.didLoad, let error = model.saveError {
                LoadFailed(message: error) { await model.load() }
            } else if !model.didLoad {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
            } else {
                if let error = model.saveError { SKBanner(.error, "Couldn't save", message: error) }
                SKGroup("Status") {
                    if let stats = model.stats {
                        SKRow("Backlog", detail: "Refreshes every few seconds while this page is open.") {
                            HStack(spacing: 10) {
                                Text("\(stats.unembeddedCount.formatted()) message\(stats.unembeddedCount == 1 ? "" : "s") waiting").sk(13)
                                if stats.workerActive {
                                    SKChip(text: "Worker active", color: SK.green, fill: SK.green.opacity(0.14))
                                } else {
                                    SKChip(text: "Worker idle")
                                }
                            }
                        }
                    }
                    SKRow("Test connection", detail: "Embeds the word \u{201C}ping\u{201D} through the saved settings.") {
                        Button(model.testing ? "Testing…" : "Test Connection") { Task { await model.test() } }
                            .skButton()
                            .disabled(model.testing || model.isDirty || model.saved == nil)
                    }
                    if let r = model.testResult {
                        SKRawRow(vertical: 8) {
                            TestResultLine(ok: r.ok, text: r.ok ? "Connected in \(r.latencyMs.formatted()) ms" : "Test failed after \(r.latencyMs.formatted()) ms", detail: r.ok ? nil : r.errorMessage)
                        }
                    }
                }
                SKGroup("Driver") {
                    SKRow("Type", detail: "Works with OpenAI, Ollama, Voyage, Together, or anything OpenAI-compatible.") {
                        SKPopup(value: model.typeDraft, minWidth: 140) {
                            ForEach(model.availableTypes, id: \.self) { type in
                                Button(type) { model.typeDraft = type }
                            }
                        }
                    }
                    SKRow("Base URL", detail: "Ends with /v1.") {
                        SKTextField(label: "Base URL", text: $model.baseURLDraft, placeholder: "https://api.openai.com/v1", width: 280, mono: true)
                    }
                    SKRow("Model") {
                        SKTextField(label: "Model", text: $model.modelDraft, placeholder: "text-embedding-3-small", width: 280, mono: true)
                    }
                    SKRow("Dimensions", detail: "Must match the model: 768 for nomic-embed-text, 1536 or 3072 for OpenAI's.") {
                        HStack(spacing: 8) {
                            TextField("Dimensions", value: $model.dimensionsDraft, format: .number.grouping(.never)).skField(width: 80, mono: true)
                            SKPopup(value: "Presets", minWidth: 90) {
                                ForEach([768, 1024, 1536, 3072], id: \.self) { d in
                                    Button("\(d)") { model.dimensionsDraft = Int32(d) }
                                }
                            }
                        }
                    }
                    SKRow("API key", detail: "Stored encrypted.") {
                        if model.saved?.apiKeySet == true {
                            SKSecretField(isSaved: true, draft: $model.apiKeyDraft)
                        } else {
                            SKTextField(label: "API key", text: $model.apiKeyDraft, placeholder: "Leave empty for local Ollama", width: 280, secure: true)
                        }
                    }
                } trailing: {
                    SKChip.synced
                }
                DeleteGroup(
                    title: "Delete configuration",
                    detail: "Embedded messages stay searchable. To pause, turn off Use this embedder.",
                    button: model.deleting ? "Deleting…" : "Delete…",
                    question: "Delete the embedder configuration?",
                    consequence: "New messages stop being embedded, and the memory plugin can't search until you set it up again.",
                    confirmLabel: "Delete",
                    disabled: model.saved == nil || model.deleting
                ) { Task { await model.delete() } }
            }
        }
        .task {
            // The backlog moves while the worker runs.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await model.refreshStats()
            }
        }
    }
}

// MARK: - Speech

private struct SpeechDetail: View {
    @Bindable var model: SpeechSettingsModel
    @AppStorage(SpeechPreferences.autoSpeakKey) private var autoSpeak = false

    private static func label(_ kind: String) -> String {
        switch kind {
        case PsmithSpeechConfig.kindAppleLocal: "On this Mac"
        case "grok": "Grok"
        case "openai-compatible": "OpenAI-compatible"
        default: kind
        }
    }

    private var engineDetail: String {
        switch model.kindDraft {
        case PsmithSpeechConfig.kindAppleLocal: "The Mac's own voice. Free, offline, nothing to set up."
        case "grok": "xAI's voice API, through your server. Audio is never stored."
        default: "OpenAI's speech API, or a self-hosted server that speaks it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKPageHead("Speech", subtitle: "Reads assistant replies aloud. The on-device voice needs no setup.")
            if !model.didLoad, let error = model.saveError {
                LoadFailed(message: error) { await model.load() }
            } else if !model.didLoad {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
            } else {
                if let error = model.saveError { SKBanner(.error, "Couldn't save", message: error) }
                SKGroup("Voice") {
                    SKRow("Engine", detail: engineDetail) {
                        SKSegmented(options: model.availableKinds.map { ($0, Self.label($0)) }, selection: $model.kindDraft)
                    }
                    SKRow("Voice", detail: model.isAppleLocalDraft ? "Empty uses the system voice." : "The provider's voice name. OpenAI's include alloy and verse.") {
                        SKTextField(label: "Voice", text: $model.voiceDraft, placeholder: model.isAppleLocalDraft ? "System voice" : "alloy", width: 200, mono: true)
                    }
                    if !model.isAppleLocalDraft {
                        SKRow("Model", detail: "Optional.") {
                            SKTextField(label: "Model", text: $model.modelDraft, placeholder: "gpt-4o-mini-tts", width: 200, mono: true)
                        }
                    }
                    SKRow("Speed") {
                        HStack(spacing: 10) {
                            SKSlider(value: $model.speedDraft, range: 0.7...1.5, step: 0.1, width: 180, ticks: 9)
                            Text(String(format: "%.1f×", model.speedDraft)).sk(13, SK.secondary, mono: true)
                        }
                    }
                    if model.kindDraft == "openai-compatible" {
                        SKRow("Base URL", detail: "Leave empty for OpenAI. Point at Kokoro, Piper or XTTS behind an OpenAI-compatible bridge to synthesize for free.") {
                            SKTextField(label: "Base URL", text: $model.baseURLDraft, placeholder: "https://api.openai.com", width: 260, mono: true)
                        }
                    }
                } trailing: {
                    SKChip.synced
                }
                if !model.isAppleLocalDraft {
                    SKGroup("Credentials") {
                        SKRow("API key", detail: "Wins over a reused provider credential.") {
                            SKSecretField(isSaved: model.saved?.apiKeySet == true, draft: $model.apiKeyDraft,
                                          onRemove: { Task { await model.clearAPIKey() } })
                        }
                        if !model.availableProviders.isEmpty {
                            SKRow("Reuse a provider's key", detail: "Speech cost is then counted under that provider in Usage.") {
                                SKPopup(value: model.availableProviders.first { $0.id == model.providerRefDraft }?.label ?? "None", minWidth: 150) {
                                    Button("None") { model.providerRefDraft = "" }
                                    ForEach(model.availableProviders, id: \.id) { p in
                                        Button(p.label) { model.providerRefDraft = p.id }
                                    }
                                }
                            }
                        }
                    } trailing: {
                        SKChip.synced
                    }
                }
                SKGroup("Playback") {
                    SKRow("Speak replies as they arrive", detail: "In the conversation you're looking at.") {
                        Toggle("Speak replies as they arrive", isOn: $autoSpeak).skSwitch()
                    }
                } trailing: {
                    SKChip.thisMac
                }
                if let saved = model.saved, !saved.isAppleLocal {
                    SKGroup("Check") {
                        SKRow("Test synthesis", detail: "Synthesizes one short phrase through the saved settings.") {
                            Button(model.testing ? "Synthesizing…" : "Test Synthesis") { Task { await model.test() } }
                                .skButton()
                                .disabled(model.testing || model.isDirty)
                        }
                        if let r = model.testResult {
                            SKRawRow(vertical: 8) {
                                TestResultLine(ok: r.ok, text: r.ok ? "\(r.audioBytes.formatted()) bytes of audio in \(r.latencyMs) ms" : "Test failed after \(r.latencyMs) ms", detail: r.ok ? nil : r.errorMessage)
                            }
                        }
                    }
                    DeleteGroup(
                        title: "Reset to on-device",
                        detail: "Forgets the cloud settings and key. Replies read with the Mac's own voice.",
                        button: model.deleting ? "Resetting…" : "Reset…",
                        question: "Reset speech to the on-device voice?",
                        consequence: "The cloud settings and key are forgotten.",
                        confirmLabel: "Reset",
                        disabled: model.deleting
                    ) { Task { await model.delete() } }
                }
            }
        }
    }
}

// MARK: - Device tools

private struct DeviceToolsDetail: View {
    @Binding var folderSet: Bool
    @Environment(AppModel.self) private var app
    @State private var folderName: String? = FilesFolderBookmark.resolve()?.lastPathComponent
    @State private var folderPath: String? = FilesFolderBookmark.resolve()?.path
    @State private var picking = false
    @State private var pickError: String?
    @State private var confirmingForget = false
    @State private var dropTargeted = false
    @State private var calls: [PsmithDeviceToolCall] = []
    @State private var loading = false
    @State private var callsError: String?
    @State private var atEnd = false
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKPageHead("Device tools", subtitle: "Tools the model runs on this Mac: Calendar, Reminders, and a folder of notes.")
            folderGroup
            permissionsGroup
            activityGroup
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { use(url) }
        }
        .task { if calls.isEmpty { await reload() } }
    }

    private var folderGroup: some View {
        SKGroup("Notes folder") {
            if let folderName {
                SKRow("Folder", detail: folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath }) {
                    HStack(spacing: 7) {
                        Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(SK.link)
                        Text(folderName).sk(13)
                    }
                }
            } else {
                SKRow("Folder", detail: "None yet.") { EmptyView() }
            }
            if confirmingForget {
                SKRawRow(vertical: 8, horizontal: 8) {
                    SKConfirmStrip(question: "Forget the notes folder?", detail: "The files stay where they are. The model can't reach them until you pick a folder again.",
                                   confirmLabel: "Forget Folder", onCancel: { confirmingForget = false }, onConfirm: forget)
                }
            } else {
                SKRawRow {
                    HStack(spacing: 8) {
                        if let pickError { Text(pickError).sk(12, SK.red) }
                        Spacer(minLength: 0)
                        if folderName != nil {
                            Button("Forget Folder") { confirmingForget = true }.skButton(.destructive)
                        }
                        Button(folderName == nil ? "Choose Folder…" : "Change Folder…") { picking = true }.skButton()
                    }
                }
            }
        } trailing: {
            SKChip.thisMac
        } footer: {
            Text("Drop a folder anywhere on this group to change it. An Obsidian vault, or a folder in one, is the usual pick.")
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(SK.accent, lineWidth: 2).padding(.bottom, 22).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
            use(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var permissionsGroup: some View {
        SKGroup("Calendar and reminders") {
            permissionRow("Calendar", EKEventStore.authorizationStatus(for: .event), "macOS asks the first time the model reads your calendar.")
            permissionRow("Reminders", EKEventStore.authorizationStatus(for: .reminder), "macOS asks the first time the model adds a reminder.")
        } trailing: {
            SKChip.thisMac
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, _ status: EKAuthorizationStatus, _ notAsked: String) -> some View {
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            SKRow(title) { Text("Allowed").sk(13, SK.green) }
        case .denied, .restricted:
            SKRow(title, detail: "Off for Psmith in System Settings.") {
                HStack(spacing: 10) {
                    Text("Not allowed").sk(13, SK.orange)
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(title == "Calendar" ? "Calendars" : "Reminders")") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .skButton(small: true)
                }
            }
        default:
            SKRow(title, detail: notAsked) { Text("Not asked yet").sk(13, SK.secondary) }
        }
    }

    private var activityGroup: some View {
        SKGroup("Recent activity") {
            if let callsError {
                SKRawRow { Text(callsError).sk(12.5, SK.red).textSelection(.enabled) }
            }
            if calls.isEmpty, !loading {
                SKRawRow { Text("No calls yet. Calls the model makes on your devices show up here.").sk(13, SK.secondary) }
            }
            ForEach(calls) { call in
                ActivityRow(call: call, expanded: expanded == call.id) {
                    withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == call.id ? nil : call.id }
                }
                .onAppear {
                    if call.id == calls.last?.id, !atEnd { Task { await loadMore() } }
                }
            }
            if loading {
                SKRawRow { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            }
        } trailing: {
            HStack(spacing: 8) {
                SKChip.synced
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium)).frame(width: 12)
                }
                .skButton(small: true, compact: true)
                .accessibilityLabel("Refresh")
            }
        } footer: {
            Text("Calls from all your devices. Older calls load as you scroll.")
        }
    }

    private func use(_ url: URL) {
        pickError = nil
        do {
            try FilesFolderBookmark.save(folderURL: url)
            folderName = FilesFolderBookmark.resolve()?.lastPathComponent
            folderPath = FilesFolderBookmark.resolve()?.path
            folderSet = true
            // The server only offers the files tools while a folder is set.
            Task { await app.deviceTools.registerWithServer() }
        } catch {
            pickError = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    private func forget() {
        confirmingForget = false
        FilesFolderBookmark.clear()
        folderName = nil
        folderPath = nil
        folderSet = false
        Task { await app.deviceTools.registerWithServer() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        callsError = nil
        do {
            let fresh = try await app.client.deviceTools.listCalls()
            calls = fresh
            atEnd = fresh.count < 50
        } catch {
            callsError = "Couldn't load activity: \(PsmithError.display(error))"
        }
    }

    private func loadMore() async {
        guard !loading, let cursor = calls.last?.invokedAt else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await app.client.deviceTools.listCalls(before: cursor)
            let known = Set(calls.map(\.id))
            calls.append(contentsOf: page.filter { !known.contains($0.id) })
            atEnd = page.count < 50
        } catch {
            callsError = "Couldn't load more: \(PsmithError.display(error))"
        }
    }
}

private struct ActivityRow: View {
    let call: PsmithDeviceToolCall
    let expanded: Bool
    let toggle: () -> Void

    private var color: Color {
        switch call.status {
        case "ok": SK.green
        case "error": SK.red
        default: SK.orange
        }
    }

    private var duration: String {
        if call.status == "timeout" { return "timed out" }
        let ms = Int(call.completedAt.timeIntervalSince(call.invokedAt) * 1000)
        return ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(max(ms, 0)) ms"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    SKDot(color: color)
                    Text(call.toolName).sk(12.5, mono: true)
                    Spacer(minLength: 0)
                    Text(duration).sk(11.5, SK.tertiary, mono: true)
                    Text(call.invokedAt.formatted(.relative(presentation: .named))).sk(12, SK.tertiary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SK.tertiary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                if !call.errorMessage.isEmpty {
                    Text(call.errorMessage).sk(12, SK.red).textSelection(.enabled).padding(.top, 9)
                }
                HStack(alignment: .top, spacing: 10) {
                    json("Input", call.inputJSON)
                    json("Output", call.outputJSON)
                }
                .padding(.top, 9)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
    }

    private func json(_ title: String, _ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).sk(11, SK.tertiary, weight: .semibold)
            Text(Self.pretty(data))
                .sk(11, SK.secondary, mono: true)
                .lineSpacing(4.5)
                .lineLimit(12)
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func pretty(_ data: Data) -> String {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return "—" }
        return s
    }
}
