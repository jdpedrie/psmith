import SwiftUI

/// Horizontal flow layout — fills a row left-to-right, wraps to a
/// new row when the next subview would exceed the proposed width.
/// SwiftUI's built-in HStack tries to "make it fit" by allowing
/// children to shrink (text wraps vertically into a column of single
/// characters in the worst case); FlowHStack instead admits defeat
/// on the first row and wraps cleanly.
///
/// Used by `ContextRow.metadataStrip` so a five-chip row on a narrow
/// iPhone width gracefully spills onto two rows instead of producing
/// the column-of-text-fragments layout bug. Each subview is sized
/// with `proposeSize: .unspecified` so the chips render at their
/// natural width; a chip wider than the proposed row width gets its
/// own row at full width (still better than character-stacking).
public struct FlowHStack: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat
    public var alignment: HorizontalAlignment

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 4, alignment: HorizontalAlignment = .leading) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(0) { $0 + $1.height } +
            (rows.isEmpty ? 0 : CGFloat(rows.count - 1) * lineSpacing)
        let totalWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: totalWidth, height: totalHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for entry in row.entries {
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(entry.size)
                )
                x += entry.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct RowLayout {
        var entries: [(index: Int, size: CGSize)]
        var width: CGFloat
        var height: CGFloat
    }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [RowLayout] {
        var rows: [RowLayout] = []
        var current = RowLayout(entries: [], width: 0, height: 0)
        for (i, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(.unspecified)
            let needed = current.entries.isEmpty ? size.width : current.width + spacing + size.width
            if !current.entries.isEmpty && needed > maxWidth {
                rows.append(current)
                current = RowLayout(entries: [(i, size)], width: size.width, height: size.height)
            } else {
                current.entries.append((i, size))
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.entries.isEmpty { rows.append(current) }
        return rows
    }
}
