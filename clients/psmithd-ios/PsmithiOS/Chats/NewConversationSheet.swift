import SwiftUI
import PsmithKit
import PsmithUI

/// Compose-new-conversation sheet — `.large` detent per
/// `docs/clients/ios-reference.md` Sheet because compose is a discrete
/// modal action; nav-bar Cancel + Start commit pattern matches iOS
/// Mail's compose flow.
///
/// On Start: calls `convos.newConversation(...)` which inserts the new
/// row at the front of the list and returns the conversation. The
/// caller's `onCreated` callback gets the new conversation so the
/// outer ChatsRoot can append it to the navigation path (auto-push).
struct NewConversationSheet: View {
    let onCreated: (PsmithConversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ConversationsModel.self) private var convos
    @Environment(AppModel.self) private var app

    @State private var title: String = ""
    @State private var selectedProfileID: String?
    @State private var creating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $title)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Profile") {
                    if convos.profiles.isEmpty {
                        Text("No profiles configured. Create one in Settings → Profiles.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profilesForPicker) { profile in
                            profileRow(profile)
                        }
                        // The picker reads the shared profiles VM; page in
                        // the rest when the user scrolls past what's loaded.
                        LoadMoreFooter(token: app.profiles.nextPageToken) { await app.profiles.loadMore() }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await create() }
                    } label: {
                        if creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Start").fontWeight(.semibold)
                        }
                    }
                    .disabled(selectedProfileID == nil || creating)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Re-fetch conversations + the shared profile list before the
        // picker materialises. Without this, a profile changed in
        // another client / via MCP / via direct DB tweak doesn't show
        // up here — the user picks a stale snapshot and the new
        // conversation inherits the wrong defaults. Cheap RPC; cost
        // is paid only when the sheet opens.
        .task {
            await convos.refresh()
            // Pre-select the account default so Start is one tap when the
            // user got here deliberately (press-and-hold on +).
            if selectedProfileID == nil {
                selectedProfileID = convos.profiles.first(where: { $0.isDefault && !$0.parentOnly })?.id
            }
        }
    }

    private var profilesForPicker: [PsmithProfile] {
        convos.profiles
            .filter { !$0.parentOnly }
            .sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    @ViewBuilder
    private func profileRow(_ profile: PsmithProfile) -> some View {
        Button {
            selectedProfileID = profile.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedProfileID == profile.id
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(selectedProfileID == profile.id
                                     ? AnyShapeStyle(.tint)
                                     : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(profile.name)
                            .foregroundStyle(.primary)
                        if profile.favorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                    if !profile.description.isEmpty {
                        Text(profile.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func create() async {
        guard let profileID = selectedProfileID, !creating else { return }
        creating = true
        errorMessage = nil
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await convos.newConversation(
            profileID: profileID,
            title: trimmed.isEmpty ? nil : trimmed,
            settings: nil
        )
        creating = false
        if let conversation = result {
            onCreated(conversation)
            dismiss()
        } else {
            errorMessage = convos.loadError ?? "Failed to create conversation."
        }
    }
}
