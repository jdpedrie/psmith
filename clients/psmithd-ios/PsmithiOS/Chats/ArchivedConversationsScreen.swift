import SwiftUI
import PsmithKit
import PsmithUI

/// The archive: conversations removed from the main list. Rows open the
/// transcript read-only (the server refuses every mutation on an
/// archived conversation; ConversationView swaps the composer for an
/// Unarchive bar). Swipe to unarchive or delete. Fetches through the
/// repository directly — archive contents are screen-local state, not
/// part of the active-list view model.
struct ArchivedConversationsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos

    @State private var archived: [PsmithConversation] = []
    @State private var nextPageToken: String?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if archived.isEmpty, loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if archived.isEmpty {
                EmptyStateView(
                    "No archived conversations",
                    systemImage: "archivebox",
                    description: "Swipe a conversation in the list to archive it."
                )
            } else {
                List {
                    if let error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(archived) { c in
                        NavigationLink {
                            ConversationView(conversation: c)
                        } label: {
                            ConversationRow(
                                conversation: c,
                                profileChainName: nil,
                                isGenerating: false,
                                isUnseen: false
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await delete(c) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                Task { await unarchive(c) }
                            } label: {
                                Label("Unarchive", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.indigo)
                        }
                    }
                    LoadMoreFooter(token: nextPageToken) { await loadMore() }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await app.client.conversations.list(pageSize: 50, archived: true)
            archived = page.items
            nextPageToken = page.nextPageToken
        } catch let err {
            if PsmithError.isCancellation(err) { return }
            error = PsmithError.display(err)
        }
    }

    @MainActor
    private func loadMore() async {
        guard let token = nextPageToken else { return }
        do {
            let page = try await app.client.conversations.list(pageSize: 50, pageToken: token, archived: true)
            let known = Set(archived.map(\.id))
            archived.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextPageToken = page.nextPageToken
        } catch let err {
            if PsmithError.isCancellation(err) { return }
            error = PsmithError.display(err)
        }
    }

    @MainActor
    private func unarchive(_ c: PsmithConversation) async {
        do {
            try await app.client.conversations.unarchive(id: c.id)
            archived.removeAll { $0.id == c.id }
            // Surface it back in the main list without waiting for the
            // next launch refresh.
            await convos.refresh()
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    @MainActor
    private func delete(_ c: PsmithConversation) async {
        do {
            try await app.client.conversations.delete(id: c.id)
            archived.removeAll { $0.id == c.id }
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}
