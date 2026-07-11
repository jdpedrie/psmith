import SwiftUI

/// Standardised height for a pane's bottom footer band so adjacent column
/// footers (categories | list | detail) line up across a settings shell.
public let paneFooterHeight: CGFloat = 40
public let paneHeaderHeight: CGFloat = 36

/// Footer band used at the bottom of every settings pane. Always renders
/// the divider + a fixed-height row, even when there's no content to show
/// (so adjacent columns line up vertically).
public struct PaneFooter<Content: View>: View {
    let content: Content
    public init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) { content }
                .padding(.horizontal, 12)
                .frame(height: paneFooterHeight, alignment: .center)
                .background(.thinMaterial)
        }
    }
}

/// Notes-style header strip at the top of a settings pane. Title + optional
/// count subtitle on the left, trailing-aligned glass action buttons on the
/// right. Mirrors `PaneFooter` for column alignment across panes.
public struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .scaledFont(.title3, weight: .semibold)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, 14)
            .frame(height: paneHeaderHeight)
            .background(.thinMaterial)
            Divider()
        }
    }
}

public extension PaneHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Tight, restrained empty-state used everywhere in Psmith. The platform's
/// `ContentUnavailableView` is too jumbo for our panes — it dominates the
/// layout. This version is small icon + callout title + caption description,
/// fills its container, and supports markdown in the description.
public struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let description: LocalizedStringKey?

    public init(_ title: String, systemImage: String, description: LocalizedStringKey? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(.tertiary)
            Text(title)
                .scaledFont(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }
}
