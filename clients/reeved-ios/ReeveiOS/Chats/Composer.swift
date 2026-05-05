import SwiftUI
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

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if app.connectivity.state == .offline {
                offlineBanner
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    draftField
                    sendButton
                }
                HStack(spacing: 8) {
                    modelChip
                    settingsButton
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .onAppear { draftFocused = true }
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
        .submitLabel(.send)
        .onSubmit {
            // .submitLabel(.send) on a vertical-axis TextField fires
            // onSubmit when the keyboard's Send key is tapped — Return
            // still inserts a newline (iOS doesn't have shift modifier
            // on the on-screen keyboard).
            triggerSend()
        }
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
        if model.isStreaming {
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
            .accessibilityLabel("Stop streaming")
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
        // Block sends when the server is unreachable — the request would
        // hang on a TCP timeout and leave the user staring at a spinner.
        // `.unknown` is treated as send-allowed so a fresh launch isn't
        // gated on the first probe completing.
        let serverReachable = app.connectivity.state != .offline
        return !trimmed.isEmpty && !model.sending && !model.isCompacting && serverReachable
    }

    private func triggerSend() {
        guard canSend else { return }
        Haptics.impact(.light)
        Task { await model.send() }
    }
}
