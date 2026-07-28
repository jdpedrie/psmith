import PsmithKit
import SwiftUI

/// Lists what an import could not wire up.
///
/// Shared rather than duplicated per platform because the wording and the
/// severity ordering are part of the feature, not the chrome: a user who
/// imports on their phone and their Mac should be told the same thing.
///
/// Used in two places. Before an import, driven by a dry run, it is the
/// "here is what you are about to get" preview. After one, it reports what
/// still needs configuring, because the import succeeded regardless.
public struct ProfileImportReview: View {
    private let warnings: [PsmithImportWarning]
    private let renamed: [String]
    private let profileNames: [String]

    public init(
        warnings: [PsmithImportWarning],
        renamed: [String] = [],
        profileNames: [String] = []
    ) {
        self.warnings = warnings
        self.renamed = renamed
        self.profileNames = profileNames
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !profileNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profileNames.count == 1 ? "Profile" : "Profiles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(profileNames, id: \.self) { name in
                        Text(name).font(.body)
                    }
                }
            }

            if warnings.isEmpty {
                Label("Everything resolved. Nothing else to configure.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ordered) { warning in
                        WarningRow(warning: warning)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Things the user has to act on first; a rename is informational.
    private var ordered: [PsmithImportWarning] {
        warnings.sorted { lhs, rhs in
            if severity(lhs.kind) != severity(rhs.kind) {
                return severity(lhs.kind) < severity(rhs.kind)
            }
            return lhs.message < rhs.message
        }
    }

    private func severity(_ kind: PsmithImportWarning.Kind) -> Int {
        switch kind {
        case .providerMissing: 0
        case .mcpServerMissing: 1
        case .pluginUnknown: 2
        case .renamed: 3
        case .unspecified: 4
        }
    }
}

private struct WarningRow: View {
    let warning: PsmithImportWarning

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.callout)
                .frame(width: 16)
            Text(warning.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var icon: String {
        switch warning.kind {
        case .providerMissing: "cpu"
        case .mcpServerMissing: "server.rack"
        case .pluginUnknown: "puzzlepiece.extension"
        case .renamed: "textformat.abc"
        case .unspecified: "exclamationmark.triangle"
        }
    }

    // A rename is a note, not a problem. Everything else is something the
    // user has to go and fix before the profile behaves as its author meant.
    private var tint: Color {
        warning.kind == .renamed ? .secondary : .orange
    }
}

/// What an export deliberately left behind, shown before the user shares the
/// file so they can tell the recipient what to supply.
public struct ProfileExportNotices: View {
    private let notices: [String]

    public init(notices: [String]) {
        self.notices = notices
    }

    public var body: some View {
        if notices.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Not included", systemImage: "lock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(notices, id: \.self) { notice in
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
