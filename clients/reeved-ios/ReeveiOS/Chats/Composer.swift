import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ReeveKit
import ReeveUI

/// iOS composer. Two-row layout per `docs/clients/ios-reference.md`
/// (revised after Phase 5d shipped):
///
///   Top row: model chip — provider logo + model name. Always
///     visible so the user knows what's about to be sent. Whole
///     chip is the tap target for `ModelPickerSheet`. Sheet attached
///     here at the trigger view (not on ConversationView's body)
///     because SwiftUI doesn't reliably dispatch multiple
///     `.sheet(isPresented:)` modifiers from the same anchor.
///   Bottom row: TextField + Send/Stop button. Send morphs into a
///     red Stop circle while `model.isStreaming`.
struct Composer: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    /// Bridge state for the UIKit-backed input: the wrapper writes
    /// its first-responder status here and reads it back when the
    /// composer wants to programmatically focus / blur (e.g.
    /// dropping the keyboard after `triggerSend`). Replaces the
    /// SwiftUI `@FocusState` we had on the old `TextField` —
    /// `@FocusState` doesn't bind to a `UIViewRepresentable`.
    @State private var draftFocused: Bool = false
    /// Live-measured height of the text input. Lets the input
    /// auto-grow from one line up to the cap (set in `draftField`)
    /// the same way the previous SwiftUI `.lineLimit(1...8)` did.
    @State private var draftFieldHeight: CGFloat = 36

    /// PhotosPicker binding. We rotate the selection back to empty
    /// after each pick so re-tapping the paperclip + choosing the
    /// same photo still triggers an upload (SwiftUI's
    /// PhotosPickerItem identity is stable per asset, so without
    /// the reset re-selecting wouldn't fire onChange).
    @State private var pickedItems: [PhotosPickerItem] = []
    /// Whether the system photos picker is presented. Separating
    /// the trigger button from the picker via `.photosPicker(
    /// isPresented:)` works around an iOS 26 quirk where the
    /// inline `PhotosPicker { Label }` initializer renders as
    /// zero-width inside a tight HStack.
    @State private var showingPhotosPicker = false
    /// Whether the system file importer is presented (for PDFs,
    /// audio, video — anything not in the Photos library).
    @State private var showingFileImporter = false
    /// Whether the camera-capture sheet is presented. Separate
    /// from the photos picker because they're distinct UX:
    /// camera = "take a new photo right now", PhotosPicker =
    /// "pick from history".
    @State private var showingCamera = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if app.connectivity.state == .offline {
                offlineBanner
            }
            if !model.pendingAttachments.isEmpty || model.attachmentUploadCount > 0 {
                attachmentChips
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    draftField
                    sendButton
                }
                HStack(spacing: 8) {
                    paperclipButton
                    modelChip
                    settingsButton
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .onChange(of: model.draft) { _, newValue in
            // Persist on every keystroke. UserDefaults writes are
            // memory-mapped and cheap; debouncing would cost us
            // freshness if the user backgrounds the app between
            // their last keystroke and the would-be debounced
            // flush. Trimming + empty-check happens inside the
            // store so an empty draft removes the key cleanly.
            DraftStore.save(conversationID: model.conversation.id, text: newValue)
        }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            // Snapshot + clear so re-picking the same asset still
            // triggers a new round.
            let snapshot = items
            pickedItems = []
            for item in snapshot {
                Task { @MainActor in
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    let filename = item.itemIdentifier // best-available label
                    await model.attachImage(data: data, originalFilename: filename)
                }
            }
        }
        .sheet(isPresented: $model.showingModelPicker) {
            ModelPickerSheet(model: model)
        }
        .photosPicker(
            isPresented: $showingPhotosPicker,
            selection: $pickedItems,
            maxSelectionCount: 6,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: fileImporterTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    Task { @MainActor in
                        await model.attachFile(from: url)
                    }
                }
            case .failure:
                // System picker handles its own error UI; nothing to
                // surface in-app for cancel-or-failure paths.
                break
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker(
                onCapture: { data in
                    showingCamera = false
                    Task { @MainActor in
                        await model.attachImage(data: data, originalFilename: nil)
                    }
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
    }

    /// Thin amber strip above the input controls when the server's
    /// `/healthz` probe is failing. Doesn't grab focus or shift the
    /// layout much — the disabled Send button already gives the
    /// strongest signal; this just explains why.
    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption2)
            Text("Server unreachable — viewing cached data")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Paperclip + attachment chip strip

    /// Paperclip menu. The system file picker doesn't show
    /// camera-roll images (those go through Photos), and
    /// PhotosPicker doesn't show files; users need both. Menu
    /// items are gated by the active provider's per-kind capability
    /// — Anthropic gets Photos + Files (PDFs); Google gets all
    /// of Photos + Files (PDFs, audio, video); OpenAI gets Photos
    /// only.
    @ViewBuilder
    private var paperclipButton: some View {
        let imageOK = activeModelAccepts(.image)
        let docOK   = activeModelAccepts(.document)
        let avOK    = activeModelAccepts(.audioVideo)
        let cameraOK = imageOK && UIImagePickerController.isSourceTypeAvailable(.camera)
        let anyOK   = imageOK || docOK || avOK
        Menu {
            if imageOK {
                Button {
                    showingPhotosPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
            }
            if cameraOK {
                Button {
                    showingCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            if docOK || avOK {
                Button {
                    showingFileImporter = true
                } label: {
                    Label(filePickerLabel(docOK: docOK, avOK: avOK), systemImage: "folder")
                }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.callout)
                .foregroundStyle(anyOK ? .secondary : .tertiary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(!anyOK)
        .accessibilityLabel(anyOK ? "Attach a file" : "Attachments not supported by this model")
    }

    private func filePickerLabel(docOK: Bool, avOK: Bool) -> String {
        switch (docOK, avOK) {
        case (true, true):  return "Choose Files"   // PDFs, audio, video
        case (true, false): return "Choose PDF"
        case (false, true): return "Choose Audio / Video"
        default:            return "Choose File"
        }
    }

    /// UTTypes the file importer accepts for the active provider.
    /// Built lazily so menu invocation reflects the current model.
    private var fileImporterTypes: [UTType] {
        var types: [UTType] = []
        if activeModelAccepts(.document) {
            types.append(.pdf)
        }
        if activeModelAccepts(.audioVideo) {
            types.append(contentsOf: [.audio, .movie])
        }
        return types
    }

    /// Pending-attachment strip — horizontal-scrolling thumbnails
    /// above the composer. Each chip has an inline X button to
    /// remove that one attachment before sending.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { att in
                    pendingChip(att)
                }
                if model.attachmentUploadCount > 0 {
                    uploadingChip
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    private func pendingChip(_ att: PendingAttachment) -> some View {
        // Image attachments use the in-memory preprocessed thumbnail
        // bytes; everything else (PDF / audio / video) renders an
        // icon + filename chip — no remote fetch needed since the
        // file's already uploaded and the user just needs to see
        // what's about to be sent.
        ZStack(alignment: .topTrailing) {
            if att.mimeType.hasPrefix("image/"),
               let uiImage = UIImage(data: att.previewData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            } else {
                filePendingChip(att)
            }

            Button {
                Haptics.impact(.light)
                model.removePendingAttachment(fileID: att.fileID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Remove attachment")
        }
    }

    /// Non-image pending-attachment chip. Bigger than the image
    /// thumbnail (filename needs room), but capped so a long PDF
    /// title doesn't push the send button off screen.
    private func filePendingChip(_ att: PendingAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: att.mimeType))
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(att.originalFilename ?? defaultLabel(for: att.mimeType))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(att.mimeType)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 180, alignment: .leading)
        .frame(height: 60)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func iconName(for mime: String) -> String {
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("image/") { return "photo" }
        return "doc"
    }

    private func defaultLabel(for mime: String) -> String {
        if mime == "application/pdf" { return "PDF" }
        if mime.hasPrefix("audio/") { return "Audio" }
        if mime.hasPrefix("video/") { return "Video" }
        return "File"
    }

    private var uploadingChip: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.08))
            .frame(width: 60, height: 60)
            .overlay(
                ProgressView().controlSize(.small)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .accessibilityLabel("Uploading attachment")
    }

    /// Per-provider attachment capabilities. The composer's paperclip
    /// menu shows / hides options based on the active provider:
    ///
    ///   anthropic         → image + document (PDF)
    ///   google            → image + document + audio + video
    ///   openai-compatible → image only (Files API path for docs
    ///                       hasn't been wired; audio/video are
    ///                       routed through the (separate) realtime
    ///                       API and not supported here)
    ///
    /// Capabilities here mirror what the Go drivers actually
    /// translate in `internal/providers/{anthropic,google,openai}/send.go`.
    /// If the catalog grows a per-model `accepts_*` flag this can
    /// move to a per-model lookup; for v1 the provider-level
    /// granularity matches the driver-side reality.
    enum AttachmentKind {
        case image, document, audioVideo
    }

    private func activeModelAccepts(_ kind: AttachmentKind) -> Bool {
        guard let pid = model.selectedProviderID else { return false }
        switch (model.providerTypes[pid], kind) {
        case ("anthropic", .image),
             ("anthropic", .document),
             ("google", .image),
             ("google", .document),
             ("google", .audioVideo),
             ("openai-compatible", .image):
            return true
        default:
            return false
        }
    }

    // MARK: - Conversation settings button

    /// Pushes the per-conversation settings page (system message,
    /// thinking flag, default model overrides…). Sits next to the
    /// model chip so the two related controls live together —
    /// "what model" and "how it behaves".
    private var settingsButton: some View {
        NavigationLink {
            ConversationSettingsView(model: model)
        } label: {
            Image(systemName: "gearshape")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Conversation settings")
    }

    // MARK: - Draft text field

    private var draftField: some View {
        // UITextView wrapper instead of SwiftUI TextField so we
        // can override `paste(_:)` and route image-pasteboard
        // content to `attachImage` instead of letting iOS try to
        // stringify the image and stuff a file URL into the text.
        // Auto-sizes between minHeight and maxHeight, then enables
        // internal scrolling — same behavior as the old
        // `.lineLimit(1...8)` modifier on the vertical TextField.
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let verticalInset: CGFloat = 16   // 8pt top + 8pt bottom
        let minHeight = lineHeight + verticalInset
        let maxHeight = lineHeight * 8 + verticalInset
        return ZStack(alignment: .topLeading) {
            PasteAwareTextField(
                text: $model.draft,
                measuredHeight: $draftFieldHeight,
                isFocused: $draftFocused,
                minHeight: minHeight,
                maxHeight: maxHeight,
                onImagePaste: { data in
                    Task { @MainActor in
                        await model.attachImage(data: data, originalFilename: nil)
                    }
                }
            )
            .frame(height: draftFieldHeight)

            if model.draft.isEmpty {
                Text("Send a message")
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Model chip (provider logo + model name + chevron)

    private var modelChip: some View {
        Button {
            model.showingModelPicker = true
        } label: {
            HStack(spacing: 8) {
                ProviderLogo(slug: providerLogoSlug, size: 20)
                Text(modelChipLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose model")
        .accessibilityValue(modelChipLabel)
    }

    /// Composite label shown on the chip:
    ///   - Selected model display name when set ("Gemini 3.1 Pro
    ///     Preview"). Falls back to model id ("gemini-3.1-pro").
    ///   - "Pick a model" when nothing is selected (fresh
    ///     conversation, never sent).
    private var modelChipLabel: String {
        if let display = modelDisplayName { return display }
        if let mid = model.selectedModelID, !mid.isEmpty { return mid }
        return "Pick a model"
    }

    private var providerLogoSlug: String? {
        guard let pid = model.selectedProviderID else { return nil }
        switch model.providerTypes[pid] {
        case "anthropic": return "anthropic"
        case "google": return "google-color"
        case "openai-compatible": return model.providerPresetIDs[pid]
        default: return nil
        }
    }

    private var modelDisplayName: String? {
        guard let mid = model.selectedModelID else { return nil }
        let pid = model.selectedProviderID
        return model.availableModels
            .first(where: { $0.modelID == mid && (pid == nil || $0.providerID == pid) })?
            .displayName
    }

    // MARK: - Send / Stop button

    @ViewBuilder
    private var sendButton: some View {
        // Stop also surfaces during compaction — that path runs its
        // own stream alongside the conversation chain, and `isStreaming`
        // is gated false while `isCompacting` is true, so we have to
        // OR them. cancelStream() targets whichever streamRunID is
        // currently live, so a single tap kills either.
        if model.isStreaming || model.isCompacting {
            Button {
                model.cancelStream()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isCompacting ? "Stop compaction" : "Stop streaming")
        } else {
            Button {
                triggerSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.accentColor : Color.gray.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private var canSend: Bool {
        let trimmed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmed.isEmpty || !model.pendingAttachments.isEmpty
        // Offline sends are no longer blocked — they go to the
        // outbound queue and drain when the server is back. The
        // composer still won't fire while an upload is pending
        // (the file_ids the queue would reference don't exist
        // yet) or while a compaction is mid-stream (those run on
        // their own dedicated stream and overlap is unsupported).
        let noUploadInFlight = model.attachmentUploadCount == 0
        return hasContent && !model.sending && !model.isCompacting && noUploadInFlight
    }

    private func triggerSend() {
        guard canSend else { return }
        Haptics.impact(.light)
        // Drop the keyboard so the message bubble + streaming reply
        // are visible without the user having to tap-to-dismiss.
        draftFocused = false
        Task { await model.send() }
    }
}
