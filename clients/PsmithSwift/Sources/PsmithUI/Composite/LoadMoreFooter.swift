import SwiftUI

/// Infinite-scroll trigger row. Drop it after the last row of a paged
/// List/Section: it renders a spinner only while another page exists,
/// and List's lazy row creation means `.task` fires exactly when the
/// user scrolls near the end. Keyed on the page token so advancing to
/// the next page re-arms the trigger; when the token goes nil the row
/// disappears entirely.
///
/// The owning view model is expected to make `action` idempotent while
/// a page is in flight (both paged VMs guard on isLoadingMore), so the
/// re-fire on token change can't double-fetch.
public struct LoadMoreFooter: View {
    private let token: String?
    private let action: () async -> Void

    public init(token: String?, action: @escaping () async -> Void) {
        self.token = token
        self.action = action
    }

    public var body: some View {
        if token != nil {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .listRowSeparator(.hidden)
            .task(id: token) { await action() }
            .accessibilityLabel("Loading more")
        }
    }
}
