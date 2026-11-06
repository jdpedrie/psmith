import SwiftUI
import PsmithUI

/// The app-settings page layout: a title and a line on what the page is
/// for, then sections, in a column centered in the detail pane. Every
/// two-pane settings page uses it, so they read as one set.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    var maxWidth: CGFloat = 720
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .scaledFont(.title2, weight: .semibold)
                    Text(subtitle)
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A labeled group on a settings page. `card: false` drops the backing
/// for content that draws its own (the theme grid).
struct SettingsSection<Content: View>: View {
    let title: String
    var card: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if card {
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else {
                content
            }
        }
    }
}

/// Shown in place of a settings form whose load failed: what went wrong
/// and a way to try again, instead of a spinner that never ends.
struct SettingsLoadFailed: View {
    let message: String
    let retry: () async -> Void
    @State private var retrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Couldn't load these settings", systemImage: "exclamationmark.triangle")
                .scaledFont(.callout, weight: .semibold)
                .foregroundStyle(.orange)
            Text(message)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    retrying = true
                    await retry()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView().controlSize(.small) } else { Text("Retry") }
            }
            .disabled(retrying)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
