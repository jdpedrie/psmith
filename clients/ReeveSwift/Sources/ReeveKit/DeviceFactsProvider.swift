import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Gathers the device-supplied facts the server-side plugin
/// pipeline asks for, returning a list of `ReeveDeviceFact`
/// suitable for `SendMessageRequest.deviceFacts`.
///
/// v1 covers the zero-permission facts (`locale`, `platform`,
/// `timezone`) — these are gathered synchronously and shipped on
/// every send. The location facts (`locationCity`,
/// `locationCoords`) are scaffolded but not auto-gathered yet:
/// they require an OS-level permission prompt and a settings UI
/// to opt-in, which lands in a follow-up. The provider returns
/// them only when explicitly requested.
public final class DeviceFactsProvider: Sendable {
    public init() {}

    /// Gather the facts in `requested`, returning the subset the
    /// device can supply right now (no permission gates yet for
    /// location). Caller drops nothing — the absent-facts
    /// behavior is owned by the server-side plugin (it skips
    /// rendering lines for missing keys), so an empty result is
    /// always a safe send.
    public func gather(_ requested: Set<ReeveDeviceFactKey> = .defaults) -> [ReeveDeviceFact] {
        var out: [ReeveDeviceFact] = []
        out.reserveCapacity(requested.count)
        for key in requested {
            if let value = currentValue(for: key) {
                out.append(ReeveDeviceFact(key: key, value: value))
            }
        }
        return out
    }

    private func currentValue(for key: ReeveDeviceFactKey) -> String? {
        switch key {
        case .locale: return localeValue()
        case .timezone: return timezoneValue()
        case .platform: return platformValue()
        case .locationCity, .locationCoords:
            // Location gathering deferred — needs CLLocationManager
            // wiring + a permission flow on top of the existing
            // settings UI. Until both ship, return nil so the
            // server-side plugin renders no Location line even if
            // the user enabled it on basic_grounding.
            return nil
        }
    }

    /// BCP-47 tag, e.g. "en-US". Locale.current uses underscores
    /// historically; `.identifier(.bcp47)` is the canonical
    /// hyphenated form the server expects.
    private func localeValue() -> String? {
        let raw = Locale.current.identifier(.bcp47)
        return raw.isEmpty ? nil : raw
    }

    /// IANA tz, e.g. "America/New_York". Reads `TimeZone.current`
    /// rather than the IANA-environment-variable hack so it works
    /// the same in shells, sandboxes, and the simulator.
    private func timezoneValue() -> String? {
        let id = TimeZone.current.identifier
        return id.isEmpty ? nil : id
    }

    /// Free-form OS + device label. iOS gets
    /// "iOS 26.5 / iPhone 17 Pro"; macOS gets
    /// "macOS 26.0 / Apple M3 Pro" (model fetched via sysctl).
    /// Prefers a friendly assembled string over either field
    /// alone since the model uses this for tech-support framing
    /// where both halves matter.
    private func platformValue() -> String {
        #if os(iOS)
        let osName = UIDevice.current.systemName        // "iOS"
        let osVersion = UIDevice.current.systemVersion  // "26.5"
        let model = sysctlString("hw.model") ?? UIDevice.current.model
        return "\(osName) \(osVersion) / \(model)"
        #elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osName = "macOS"
        let osVersion = "\(v.majorVersion).\(v.minorVersion)"
        let model = sysctlString("hw.model") ?? "Mac"
        return "\(osName) \(osVersion) / \(model)"
        #else
        return "\(ProcessInfo.processInfo.hostName)"
        #endif
    }

    /// Read a sysctl string (e.g. "hw.model" → "iPhone17,1").
    /// Matches the conventional Apple-platform usage where
    /// hw.model returns the marketing-adjacent identifier.
    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let str = String(cString: buffer)
        return str.isEmpty ? nil : str
    }
}

extension Set where Element == ReeveDeviceFactKey {
    /// Default fact set the client gathers without any explicit
    /// opt-in: zero-permission, zero-permission-prompt, fully
    /// available on all platforms. Plugins that asked for
    /// these read them; plugins that didn't ignore them.
    public static var defaults: Set<ReeveDeviceFactKey> {
        [.locale, .timezone, .platform]
    }
}
