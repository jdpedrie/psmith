import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import PsmithKit
import PsmithUI

/// The composer (Conversation, Streaming, ComposerTray, Council,
/// DraftStart, DraftNoProfile, Compacting): a glass card with the text
/// on top and one row under it: "+" for the tray, the model chip, call
/// settings, then send, stop or resend. "+" opens the tray in the
/// keyboard's place rather than a menu or a sheet.
struct Composer: View {
    @Bindable var model: ConversationViewModel
    let ui: ConversationUIState
    /// Overrides for tests; nil runs the real send and stop.
    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    /// The tray stands where the keyboard would; the screen sizes it.
    var trayHeight: CGFloat = 282
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openConversationPage) private var open

    @State private var focused = false
    @State private var fieldHeight: CGFloat = 22
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var showingCamera = false
    @State private var openPanel: PsmithPluginType?

    /// A council's voices each bring their own model, so the chip and
    /// call settings have nothing to say there.
    private var isCouncil: Bool { !model.councilVoices.isEmpty }
    private var noProfile: Bool { model.isDraft && model.draftProfile == nil }

    var body: some View {
        VStack(spacing: 8) {
            if model.canContinueDiscussion {
                continueChip
            }
            card
            if ui.trayOpen {
                ComposerTray(model: model, ui: ui,
                             attachments: attachmentAccess, height: trayHeight,
                             onCamera: { showingCamera = true },
                             onAllPhotos: { showingPhotosPicker = true },
                             onFiles: { showingFileImporter = true },
                             onPanel: { openPanel = $0 })
                    .padding(.horizontal, -12)
                    .padding(.top, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: model.draft) { _, text in
            DraftStore.save(conversationID: model.conversation.id, text: text)
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused, ui.trayOpen { withAnimation(.snappy(duration: 0.25)) { ui.trayOpen = false } }
        }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            // Cleared so picking the same asset again still uploads.
            let snapshot = items
            pickedItems = []
            for item in snapshot {
                Task { @MainActor in
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    await model.attachImage(data: data, originalFilename: item.itemIdentifier)
                }
            }
        }
        // Panels are resolved per conversation.
        .task(id: model.conversation.id) { await model.loadPanels() }
        .navigationDestination(item: $openPanel) { type in
            if let panel = type.panel {
                PluginPanelPage(pluginName: type.name, panel: panel, conversationID: model.conversation.id,
                                client: app.client, onCompose: { model.draft += $0 })
            }
        }
        .photosPicker(isPresented: $showingPhotosPicker, selection: $pickedItems, maxSelectionCount: 6,
                      matching: .images, preferredItemEncoding: .compatible)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: fileImporterTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { Task { @MainActor in await model.attachFile(from: url) } }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker(
                onCapture: { data in
                    showingCamera = false
                    Task { @MainActor in await model.attachImage(data: data, originalFilename: nil) }
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.pendingAttachments.isEmpty || model.attachmentUploadCount > 0 {
                PendingAttachmentStrip(model: model)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
            field
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .opacity(model.isCompacting ? 0.5 : 1)
            HStack(spacing: 4) {
                // Stop stays at full strength while a compaction runs.
                HStack(spacing: 4) {
                    plusButton
                    if !isCouncil { modelChip }
                    if !model.isDraft && !isCouncil { callSettingsButton }
                }
                .opacity(model.isCompacting ? 0.5 : 1)
                Spacer(minLength: 0)
                trailingButton
            }
            .opacity(noProfile ? 0.45 : 1)
        }
        .padding(.top, 12)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .ikGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var placeholder: String {
        if noProfile { return "Choose a profile to start" }
        let name = model.draftProfile?.name ?? profileName
        return name.map { "Message \($0)" } ?? "Message"
    }

    @Environment(ConversationsModel.self) private var convos
    private var profileName: String? {
        convos.profiles.first(where: { $0.id == model.conversation.profileID })?.name
    }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            PasteAwareTextField(
                text: $model.draft,
                measuredHeight: $fieldHeight,
                isFocused: $focused,
                minHeight: 22,
                maxHeight: 22 * 8,
                onImagePaste: { data in Task { @MainActor in await model.attachImage(data: data, originalFilename: nil) } },
                isEnabled: !noProfile && !model.isCompacting
            )
            if model.draft.isEmpty {
                Text(placeholder).font(.system(size: 16)).foregroundStyle(IK.tertiary).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message")
    }

    // MARK: Row

    private var plusButton: some View {
        Button { toggleTray() } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .rotationEffect(.degrees(ui.trayOpen ? 45 : 0))
                .foregroundStyle(ui.trayOpen ? theme.accentInk : IK.strong)
                .frame(width: 36, height: 36)
                .background(Circle().fill(ui.trayOpen ? theme.accent.opacity(0.18) : IK.wash(0.08)))
                .overlay(Circle().strokeBorder(ui.trayOpen ? theme.accent.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(noProfile)
        .accessibilityLabel(ui.trayOpen ? "Close the tray" : "Add photos, files and actions")
    }

    private var modelChip: some View {
        Button {
            ui.trayOpen = false
            open(.models)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.system(size: 13))
                Text(modelLabel).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                if !noProfile {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(IK.strong)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(noProfile)
        .layoutPriority(1)
        .accessibilityLabel("Choose model")
        .accessibilityValue(modelLabel)
    }

    private var modelLabel: String {
        if noProfile { return "No model" }
        if let name = model.modelDisplayName(providerID: model.selectedProviderID, modelID: model.selectedModelID) { return name }
        return "Pick a model"
    }

    private var callSettingsButton: some View {
        Button {
            ui.trayOpen = false
            open(.callSettings)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17))
                .foregroundStyle(IK.strong)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Call settings")
    }

    @ViewBuilder
    private var trailingButton: some View {
        // Stop covers a compaction too: it runs its own stream, and
        // cancelStream targets whichever run is live.
        if model.isStreaming || model.isCompacting {
            Button { stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(IK.red)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(IK.red.opacity(0.18)))
                    .overlay(Circle().strokeBorder(IK.red.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isCompacting ? "Stop the compaction" : "Stop the reply")
        } else if canResend {
            Button {
                Haptics.impact(.light)
                Task { await model.reloadLastUser() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resend your last message")
        } else {
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(theme.accent))
                    .opacity(canSend ? 1 : (noProfile ? 0.6 : 0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(model.attachmentUploadCount > 0 ? "Send after the upload finishes" : "Send")
        }
    }

    /// The reply to your last message never landed (it failed, or was
    /// deleted): one tap asks again without retyping.
    var canResend: Bool {
        guard model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.pendingAttachments.isEmpty, !model.isDraft, !model.sending,
              model.pendingUserText == nil, model.queuedEntries.isEmpty,
              let last = model.messages.last(where: { $0.role == .user || $0.role == .assistant })
        else { return false }
        return last.role == .user || last.errorText != nil
    }

    var canSend: Bool {
        let hasContent = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty
        // Offline sends queue; an upload in flight would queue file ids
        // that don't exist yet.
        let draftReady = !model.isDraft
            || (model.draftProfile != nil && model.selectedModelID != nil && !model.creatingConversation)
        return hasContent && !model.sending && !model.isCompacting && model.attachmentUploadCount == 0 && draftReady
    }

    func send() {
        guard canSend else { return }
        Haptics.impact(.light)
        focused = false
        ui.trayOpen = false
        if let onSend { onSend(); return }
        Task { await model.send() }
    }

    func toggleTray() {
        focused = false
        withAnimation(.snappy(duration: 0.25)) { ui.trayOpen.toggle() }
    }

    func stop() {
        Haptics.impact(.light)
        if let onStop { onStop(); return }
        model.cancelStream()
    }

    private var continueChip: some View {
        HStack {
            Button {
                Task { await model.continueDiscussion() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 13))
                    Text("Continue the discussion").font(.system(size: 14))
                }
                .foregroundStyle(IK.strong)
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(height: 36)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .ikGlass(in: Capsule())
            .disabled(app.connectivity.state == .offline)
            Spacer(minLength: 0)
        }
    }

    // MARK: Attachment capabilities

    /// What the active provider takes. Mirrors what the server's drivers
    /// translate: Anthropic images and PDFs, Google those plus audio and
    /// video, OpenAI-compatible images only. A harness takes text only.
    var attachmentAccess: ComposerTray.Access {
        func accepts(_ kind: Int) -> Bool {
            guard model.canAttachFiles, let pid = model.selectedProviderID else { return false }
            switch (model.providerTypes[pid], kind) {
            case ("anthropic", 0), ("anthropic", 1), ("google", 0), ("google", 1), ("google", 2), ("openai-compatible", 0):
                return true
            default:
                return false
            }
        }
        return .init(images: accepts(0), documents: accepts(1), audioVideo: accepts(2),
                     camera: accepts(0) && UIImagePickerController.isSourceTypeAvailable(.camera))
    }

    private var fileImporterTypes: [UTType] {
        var types: [UTType] = []
        if attachmentAccess.documents { types.append(.pdf) }
        if attachmentAccess.audioVideo { types.append(contentsOf: [.audio, .movie]) }
        return types
    }
}

// MARK: - Pending attachments

/// What's about to be sent, above the text: image thumbnails, file chips
/// and an uploading chip, each removable (ComposerTray).
struct PendingAttachmentStrip: View {
    let model: ConversationViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.pendingAttachments) { att in
                    chip(att)
                        .overlay(alignment: .topTrailing) { removeButton(att).offset(x: 6, y: -6) }
                }
                if model.attachmentUploadCount > 0 {
                    HStack(spacing: 8) {
                        IKSpinner()
                        Text("Uploading").font(.system(size: 12.5)).foregroundStyle(IK.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 10).fill(IK.wash(0.04)))
                    .accessibilityLabel("Uploading attachment")
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .padding(.top, -6)
    }

    @ViewBuilder
    private func chip(_ att: PendingAttachment) -> some View {
        if att.mimeType.hasPrefix("image/"), let image = UIImage(data: att.previewData) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if att.mimeType.hasPrefix("image/") {
            RoundedRectangle(cornerRadius: 10).fill(IK.wash(0.10))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(IK.secondary))
        } else {
            HStack(spacing: 8) {
                Image(systemName: icon(att.mimeType)).font(.system(size: 20)).foregroundStyle(IK.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(att.originalFilename ?? "File").font(.system(size: 13)).foregroundStyle(IK.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(UsageFormat.bytes(att.previewData.isEmpty ? 0 : att.previewData.count))
                        .font(.system(size: 11.5)).foregroundStyle(IK.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .frame(maxWidth: 180, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(IK.wash(0.06)))
        }
    }

    private func removeButton(_ att: PendingAttachment) -> some View {
        Button {
            Haptics.impact(.light)
            model.removePendingAttachment(fileID: att.fileID)
        } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(IK.strong)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.dynamic(light: .hex("#F2F6FA"), dark: .hex("#0E161F"))))
                .overlay(Circle().strokeBorder(IK.ring(0.18), lineWidth: 1))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(-5)
        .accessibilityLabel("Remove attachment")
    }

    private func icon(_ mime: String) -> String {
        if mime == "application/pdf" { return "doc.text" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        return "doc"
    }
}

// MARK: - Tray

/// The tray "+" opens where the keyboard sits (ComposerTray): the camera
/// and recent photos, the photo library and files, then this
/// conversation's own actions and any plugin panels.
struct ComposerTray: View {
    struct Access {
        var images: Bool
        var documents: Bool
        var audioVideo: Bool
        var camera: Bool
    }

    let model: ConversationViewModel
    let ui: ConversationUIState
    let attachments: Access
    var height: CGFloat = 282
    let onCamera: () -> Void
    let onAllPhotos: () -> Void
    let onFiles: () -> Void
    let onPanel: (PsmithPluginType) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.openConversationPage) private var open

    var body: some View {
        // Scrolls when a short phone gives it less than its full height.
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 12) {
            if attachments.images {
                HStack(spacing: 8) {
                    tile("camera", "Camera", height: 84, action: onCamera)
                        .frame(width: 84)
                        .disabled(!attachments.camera)
                    RecentPhotosStrip { data in
                        Task { @MainActor in await model.attachImage(data: data, originalFilename: nil) }
                    }
                }
                .padding(.trailing, -16)
            }
            if attachments.images || attachments.documents || attachments.audioVideo {
                HStack(spacing: 8) {
                    if attachments.images { wideTile("photo.on.rectangle", "All Photos", action: onAllPhotos) }
                    if attachments.documents || attachments.audioVideo { wideTile("folder", "Files", action: onFiles) }
                }
            }
            Text("This conversation").font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
                .padding(.top, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                tile("rectangle.expand.vertical", "Compress") { ui.openCompress(model: model) }
                    .disabled(model.isStreaming || model.isCompacting || model.hasPendingCompression || model.isDraft)
                tile("cpu", "Model") { ui.trayOpen = false; open(.models) }
                tile("slider.horizontal.3", "Settings") { ui.trayOpen = false; open(.info) }
                    .disabled(model.isDraft)
                tile("puzzlepiece.extension", "Plugins") { ui.trayOpen = false; open(.info) }
                    .disabled(model.isDraft)
                ForEach(model.panelPlugins) { type in
                    if let panel = type.panel {
                        tile(panel.sfSymbol.isEmpty ? "square.grid.2x2" : panel.sfSymbol, panel.title) {
                            ui.trayOpen = false
                            onPanel(type)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: height, alignment: .top)
        .background(theme.trayGround.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(IK.wash(0.07)).frame(height: 1) }
    }

    private func tile(_ symbol: String, _ title: String, height: CGFloat = 72, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.system(size: 12.5)).lineLimit(1)
            }
            .foregroundStyle(IK.strong)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func wideTile(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.system(size: 12.5))
            }
            .foregroundStyle(IK.strong)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// The newest photos in the library, when the app may already read it;
/// tap one to attach it. Never asks for access itself: All Photos is
/// the way in until the person grants it.
struct RecentPhotosStrip: View {
    let onPick: (Data) -> Void
    @Environment(\.theme) private var theme
    @State private var assets: [PHAsset] = []
    @State private var thumbs: [String: UIImage] = [:]
    @State private var picked: Set<String> = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    let id = asset.localIdentifier
                    Button { pick(asset) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let img = thumbs[id] {
                                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    IK.wash(0.08)
                                }
                            }
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            if picked.contains(id) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(theme.accent))
                                    .padding(6)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(picked.contains(id) ? theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recent photo")
                }
            }
        }
        .task { load() }
    }

    private func load() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 12
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [PHAsset] = []
        result.enumerateObjects { a, _, _ in list.append(a) }
        assets = list
        let size = CGSize(width: 168, height: 168)
        for a in list {
            let id = a.localIdentifier
            PHImageManager.default().requestImage(for: a, targetSize: size, contentMode: .aspectFill, options: nil) { img, _ in
                guard let img else { return }
                Task { @MainActor in thumbs[id] = img }
            }
        }
    }

    private func pick(_ asset: PHAsset) {
        let id = asset.localIdentifier
        guard !picked.contains(id) else { return }
        picked.insert(id)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            guard let data else { return }
            Task { @MainActor in onPick(data) }
        }
    }
}
