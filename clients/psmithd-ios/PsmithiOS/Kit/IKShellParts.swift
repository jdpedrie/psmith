import SwiftUI
import PsmithUI

// Parts shared by the shell's own screens: sign in, launch, onboarding.
// Measurements come from the SignIn*, Launch* and Onboard* boards.

extension IK {
    /// A text input's well: darker than the group it sits in.
    static let fieldFill = Color.dynamic(light: Color(red: 16 / 255, green: 32 / 255, blue: 52 / 255).opacity(0.088),
                                         dark: Color.black.opacity(0.22))
    /// An archived conversation's title in the list.
    static let archivedTitle = Color.dynamic(light: .hex("#3D4955"), dark: .hex("#AEB8C2"))
    static let swipeUnarchive = Color.dynamic(light: .hex("#4F4AA8"), dark: .hex("#4F4AA8"))
}

extension View {
    /// CSS line-height for system text: the extra leading goes between
    /// lines and half of it above and below, so a block's height and its
    /// first baseline land where the board's do.
    func ikLineHeight(_ lineHeight: CGFloat, size: CGFloat) -> some View {
        let extra = max(0, lineHeight - UIFont.systemFont(ofSize: size).lineHeight)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// The app icon tile the launch and sign-in screens center on.
struct IKAppIcon: View {
    var body: some View {
        Group {
            if let icon = UIImage(named: "AppIcon") ?? Self.bundleIcon {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                IK.wash(0.06)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(IK.ring(0.12), lineWidth: 1))
        .accessibilityLabel("Psmith app icon")
    }

    private static var bundleIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }
}

/// A labeled text input inside a group: 13pt label, 44pt well, an
/// optional hint under it. The ring shows focus (accent) or an error.
struct IKField<Field: View>: View {
    let label: String
    var hint: String?
    var ring: Color?
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
            field
                .font(.system(size: 16))
                .foregroundStyle(IK.text)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(IK.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(ring ?? IK.ring(0.08), lineWidth: ring == nil ? 1 : 1.5))
                .padding(.top, 6)
            if let hint {
                Text(hint).font(.system(size: 13)).ikLineHeight(18, size: 13).foregroundStyle(IK.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }
}

/// The neutral card the shell's forms sit in.
struct IKCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
    }
}

/// The shell's 50pt buttons: primary (accent) and plain (wash).
struct IKWideButtonStyle: ButtonStyle {
    var primary = true
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color.white : IK.text)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Capsule().fill(primary ? theme.accent : IK.wash(0.09)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

extension View {
    func ikWideButton(primary: Bool = true) -> some View {
        buttonStyle(IKWideButtonStyle(primary: primary))
    }
}

/// A status line under a field: icon and text in one state color.
struct IKStatusLine: View {
    let systemImage: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 14)).frame(width: 15).padding(.top, 2.5)
            Text(text).font(.system(size: 13)).ikLineHeight(18, size: 13).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
    }
}

/// The 26pt ring spinner on the launch screen.
struct IKLaunchSpinner: View {
    var size: CGFloat = 26
    var lineWidth: CGFloat = 2.5
    var track: Double = 0.12
    var label = "Connecting"
    @Environment(\.theme) private var theme
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(IK.ring(track), lineWidth: lineWidth)
            Circle().trim(from: 0, to: 0.25)
                .stroke(theme.accentInk, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(turning ? 225 : -135))
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

/// A round initial: the account avatar.
struct IKAvatar: View {
    let name: String
    var size: CGFloat = 32
    var fill: Color?
    var ink: Color = .white
    @Environment(\.theme) private var theme

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.47, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(Circle().fill(fill ?? theme.accent))
    }
}

/// A filled status strip: the offline notice on the list and at launch.
struct IKStatusBanner: View {
    var systemImage = "wifi.slash"
    let text: String
    var color: Color = IK.orange

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .medium)).frame(width: 15)
            Text(text).font(.system(size: 13)).ikLineHeight(18, size: 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}
