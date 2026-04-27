import SwiftUI
import ClarkKit

struct ConversationListView: View {
    @Environment(ConversationsModel.self) private var convos
    @State private var conversationToDelete: ClarkConversation?

    var body: some View {
        @Bindable var convos = convos
        VStack(spacing: 0) {
            List(selection: $convos.selectedID) {
                if convos.conversations.isEmpty && !convos.isLoading && convos.loadError == nil {
                    Text("No conversations yet.")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(convos.conversations) { c in
                    ConversationRow(conversation: c)
                        .tag(c.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                conversationToDelete = c
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .confirmationDialog(
                "Delete \"\(conversationToDelete?.title?.isEmpty == false ? conversationToDelete!.title! : "Untitled")\"?",
                isPresented: Binding(
                    get: { conversationToDelete != nil },
                    set: { if !$0 { conversationToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let c = conversationToDelete {
                        Task { await convos.delete(c.id) }
                    }
                    conversationToDelete = nil
                }
                Button("Cancel", role: .cancel) { conversationToDelete = nil }
            } message: {
                Text("This will permanently delete the conversation and all its messages.")
            }
            .overlay {
                if let err = convos.loadError {
                    VStack(spacing: 8) {
                        Text("Failed to load").font(.headline)
                        Text(err).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await convos.refresh() } }
                    }
                    .padding()
                } else if convos.isLoading && convos.conversations.isEmpty {
                    ProgressView()
                }
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: ClarkConversation
    @Environment(ConversationsModel.self) private var convos

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title?.isEmpty == false ? conversation.title! : "Untitled")
                .lineLimit(1)
            if let profileName = profileName {
                Text(profileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// "Profile (Parent, Grandparent)" — walks the profile parent chain.
    private var profileName: String? {
        let id = conversation.profileID
        guard let p = convos.profiles.first(where: { $0.id == id }) else { return nil }
        var ancestors: [String] = []
        var current = p.parentProfileID
        var seen: Set<String> = [p.id]
        var depth = 0
        while let pid = current, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let parent = convos.profiles.first(where: { $0.id == pid }) else { break }
            ancestors.append(parent.name)
            current = parent.parentProfileID
        }
        return ancestors.isEmpty ? p.name : "\(p.name) (\(ancestors.joined(separator: ", ")))"
    }
}

/// Shared compact popover used by the bottom sidebar tray's `+` button.
/// Picks a profile and (optionally) a title.
struct NewConversationPopover: View {
    let profiles: ProfilesViewModel
    let onDone: (_ profileID: String?, _ title: String?) -> Void

    @Environment(ConversationsModel.self) private var convos
    @State private var selectedProfileID: String?
    @State private var title: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Profile", selection: $selectedProfileID) {
                ForEach(convos.profiles) { p in
                    Text(profileLabel(p)).tag(Optional(p.id))
                }
            }
            .labelsHidden()

            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { onDone(nil, nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    onDone(selectedProfileID, title.isEmpty ? nil : title)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(selectedProfileID == nil)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = convos.profiles.first?.id
            }
        }
    }

    private func profileLabel(_ p: ClarkProfile) -> String {
        if let full = profiles.profiles.first(where: { $0.id == p.id }) {
            return profiles.conciseName(for: full)
        }
        return p.name
    }
}
