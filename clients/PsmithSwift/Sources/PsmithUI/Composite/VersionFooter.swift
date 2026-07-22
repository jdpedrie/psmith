import SwiftUI
import PsmithKit

/// One-line build-identity footer for the settings surfaces:
/// "Psmith <app stamp> · Server <server stamp>". The app half comes
/// from `BuildInfo.commit` (the Info.plist stamp); the server half
/// from one unauthenticated Probe against the active account's
/// server. Stamps are short commit hashes, `+YYYYMMDDHHMM`-suffixed
/// for dirty builds, so "am I on the latest?" is a glance, not an
/// investigation.
public struct VersionFooter: View {
    private let auth: AuthRepository
    @State private var serverLabel: String = "…"

    public init(auth: AuthRepository) {
        self.auth = auth
    }

    public var body: some View {
        Text("Psmith \(BuildInfo.commit) · Server \(serverLabel)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .task {
                switch await auth.probe() {
                case .ok(_, let version):
                    serverLabel = version.isEmpty ? "dev" : version
                case .wrongServer, .unreachable:
                    serverLabel = "unreachable"
                }
            }
    }
}
