import SwiftUI
import ReeveKit
import ReeveUI

/// iOS composer. Two pieces:
///
///   1. **Bar** — pinned to the bottom of the conversation. Shows
///      the draft preview (or a placeholder), plus model chip,
///      settings, and a Send button. Tapping the preview opens the
///      editor sheet; the Send button works directly from the bar
///      when a draft is already populated, so quick "yes" or "go"
///      replies don't require opening a modal.
///   2. **Editor sheet** — full-height multi-line `TextEditor` with
///      its own Cancel/Send toolbar. Hosting the actual text input
///      in a sheet sidesteps the keyboard-vs-scroll dance entirely:
///      the conversation behind the sheet doesn't need to reflow.
struct Composer: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @State private var showingEditor = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if app.connectivity.state == .offline {
                offlineBanner
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    draftBar
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
        .sheet(isPresented: $showingEditor) {
            ComposerEditorSheet(model: model, onSendComplete: {
                showingEditor = false
            })
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

    // MARK: - Draft bar (tap target → opens editor sheet)

    private var draftBar: some View {
        Button {
            showingEditor = true
        } label: {
            HStack {
                Text(barLabel)
                    .font(.body)
                    .foregroundStyle(model.draft.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compose message")
        .accessibilityValue(model.draft.isEmpty ? "" : model.draft)
        .accessibilityHint("Opens the message editor")
    }

    /// One-line summary shown on the bar. The full draft + multi-line
    /// editing happens in the sheet — the bar's only job is to remind
    /// the user there's a saved draft and serve as the tap target.
    private var barLabel: String {
        if model.draft.isEmpty { return "Send a message" }
        // Collapse newlines so a multi-line draft still reads as one
        // line in the bar. The full text shows up in the sheet.
        return model.draft
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
    }

    // MARK: - Conversation settings button

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
        let serverReachable = app.connectivity.state != .offline
        return !trimmed.isEmpty && !model.sending && !model.isCompacting && serverReachable
    }

    private func triggerSend() {
        guard canSend else { return }
        Haptics.impact(.light)
        Task { await model.send() }
    }
}

// MARK: - Editor sheet

/// Full-height composer modal. Hosts the only multi-line text editor
/// in the chat surface — when text input lives in a sheet, the
/// conversation pane behind it doesn't need to reflow around the
/// keyboard. Cancel preserves the draft (DraftStore writes on every
/// keystroke); Send fires the same `model.send()` path as the bar.
private struct ComposerEditorSheet: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool
    /// Hook for the parent to dismiss its presentation flag — calling
    /// `dismiss()` alone tears down the sheet but doesn't toggle the
    /// `@State showingEditor`, leaving the bar in a stale state.
    let onSendComplete: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $model.draft)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                if app.connectivity.state == .offline {
                    offlineBanner
                }
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        Task {
                            await model.send()
                            // Send drained the draft; close the
                            // sheet so the user lands back on the
                            // conversation to watch the reply.
                            onSendComplete()
                        }
                    } label: {
                        Text("Send").bold()
                    }
                    .disabled(!canSend)
                }
            }
            .onAppear { editorFocused = true }
            .onChange(of: model.draft) { _, newValue in
                DraftStore.save(conversationID: model.conversation.id, text: newValue)
            }
        }
    }

    private var canSend: Bool {
        let trimmed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverReachable = app.connectivity.state != .offline
        return !trimmed.isEmpty && !model.sending && !model.isCompacting && serverReachable
    }

    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption2)
            Text("Server unreachable — Send is disabled")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }
}
