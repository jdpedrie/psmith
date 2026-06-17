import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Gathers the device-supplied facts the server-side plugin
/// pipeline asks for, returning a list of `SpaltDeviceFact`
/// suitable for `SendMessageRequest.deviceFacts`.
///
/// Always supplies the zero-permission facts (`locale`,
/// `timezone`, `platform`) synchronously. Location facts ride
/// along ONLY when the user has opted in via
/// `LocationFactPreference` AND `LocationProvider.shared` has a
/// fresh fix — never synchronously waits for one (CLLocationManager
/// fixes can take seconds; we'd rather skip the fact this turn
/// and ship what we have than gate the send).
public final class DeviceFactsProvider {
    public init() {}

    public func gather(_ requested: Set<SpaltDeviceFactKey> = .defaults) -> [SpaltDeviceFact] {
        var out: [SpaltDeviceFact] = []
        out.reserveCapacity(requested.count)
        for key in requested {
            if let value = currentValue(for: key) {
                out.append(SpaltDeviceFact(key: key, value: value))
            }
        }
        // Location facts: opt-in via LocationFactPreference, gated
        // on a fresh cached fix. We call `requestPermissionAndFix`
        // (not just `refreshIfAuthorized`) so the very first send
        // after the preference is enabled also triggers the OS
        // permission prompt — without this, the user has to find
        // the Privacy toggle and manually flip it AGAIN to start
        // the CLLocationManager flow even though they already opted
        // in. The call is cheap when permission is already granted
        // (just kicks off a fresh fix request).
        #if canImport(CoreLocation)
        if LocationFactPreference.enabled {
            Task { @MainActor in
                LocationProvider.shared.requestPermissionAndFix()
            }
            if let fact = MainActor.assumeIsolated({ LocationProvider.shared.freshFact() }) {
                if requested.contains(.locationCoords) {
                    out.append(SpaltDeviceFact(key: .locationCoords, value: fact.coords))
                }
                if requested.contains(.locationCity), let city = fact.city {
                    out.append(SpaltDeviceFact(key: .locationCity, value: city))
                }
            }
        }
        #endif
        return out
    }

    private func currentValue(for key: SpaltDeviceFactKey) -> String? {
        switch key {
        case .locale: return localeValue()
        case .timezone: return timezoneValue()
        case .platform: return platformValue()
        case .locationCity, .locationCoords:
            // Handled in the LocationProvider branch in `gather`
            // above — the basic-loop case can't reach the actor-
            // isolated provider safely from here.
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

extension Set where Element == SpaltDeviceFactKey {
    /// Default fact set the client gathers on every send. The
    /// zero-permission facts are always in; location facts are
    /// in too because gathering them is cheap when the user
    /// hasn't opted in (the provider drops them silently). The
    /// server-side plugin makes the final decision on whether to
    /// render them.
    public static var defaults: Set<SpaltDeviceFactKey> {
        [.locale, .timezone, .platform, .locationCity, .locationCoords]
    }
}

/// UserDefaults-backed flag for "user wants location to ride
/// along on outgoing messages". Toggled from
/// `PrivacyDetailView`; read by `DeviceFactsProvider.gather`.
/// Stored in the standard suite — survives reinstall via iCloud
/// keychain doesn't apply here, but a fresh install starts with
/// the conservative default-off, which is what we want anyway.
public enum LocationFactPreference {
    private static let key = "spalt.deviceFacts.locationEnabled"

    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
