import SwiftUI
import PhotosUI
import ReeveKit
import ReeveUI

/// iOS composer. Two-row layout per `docs/ios-screens.md` §2.23
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
    @FocusState private var draftFocused: Bool

    /// PhotosPicker binding. We rotate the selection back to empty
    /// after each pick so re-tapping the paperclip + choosing the
    /// same photo still triggers an upload (SwiftUI's
    /// PhotosPickerItem identity is stable per asset, so without
    /// the reset re-selecting wouldn't fire onChange).
    @State private var pickedItems: [PhotosPickerItem] = []

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

    /// Paperclip button → PhotosPicker. Multi-select on so the user
    /// can attach a few images at once; preprocessing + upload
    /// happen per-item, in parallel-ish (each via its own Task).
    /// Capability gate is driven by the active model's image
    /// support — drivers that don't accept images dim the button
    /// rather than letting the user upload and discover the failure
    /// at send time.
    @ViewBuilder
    private var paperclipButton: some View {
        let accepts = activeModelAcceptsImages
        PhotosPicker(
            selection: $pickedItems,
            maxSelectionCount: 6,
            matching: .images,
            preferredItemEncoding: .compatible
        ) {
            Image(systemName: "paperclip")
                .font(.callout)
                .foregroundStyle(accepts ? .secondary : .tertiary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!accepts)
        .accessibilityLabel(accepts ? "Attach an image" : "Attachments not supported by this model")
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
        // UIImage(data:) is cheap on the preprocessed thumbnail-
        // sized JPEG bytes the VM already holds; no need to dance
        // through AsyncImage / signed-URL fetches for content we
        // have in-memory.
        let image: Image? = UIImage(data: att.previewData).map(Image.init(uiImage:))
        return ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

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

    /// Whether the currently-selected model accepts image attachments.
    /// Capability table is hardcoded for now (Phase 1 ships
    /// Anthropic-only image translation; other drivers will slot
    /// in as their slices land). Driver type is the simplest
    /// discriminator we have until the catalog grows a
    /// `accepts_images` column.
    private var activeModelAcceptsImages: Bool {
        guard let pid = model.selectedProviderID else { return false }
        switch model.providerTypes[pid] {
        case "anthropic": return true
        default: return false
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
        // Vertical-axis TextField never fires onSubmit — Return always
        // inserts a newline regardless of the submitLabel — so labelling
        // the key as "Send" was lying to the user (they tapped ↑
        // expecting a submit, got a newline). The button on the right
        // is the only submit path; the keyboard key is the newline key
        // and now reads as one.
        TextField(
            "Send a message",
            text: $model.draft,
            axis: .vertical
        )
        .lineLimit(1...8)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .focused($draftFocused)
        .submitLabel(.return)
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
        // Block sends when the server is unreachable — the request would
        // hang on a TCP timeout and leave the user staring at a spinner.
        // `.unknown` is treated as send-allowed so a fresh launch isn't
        // gated on the first probe completing.
        let serverReachable = app.connectivity.state != .offline
        // Block sends while an upload is still in flight: the chip
        // is showing a spinner and sending without it would drop
        // the user's intent on the floor.
        let noUploadInFlight = model.attachmentUploadCount == 0
        return hasContent && !model.sending && !model.isCompacting && serverReachable && noUploadInFlight
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
