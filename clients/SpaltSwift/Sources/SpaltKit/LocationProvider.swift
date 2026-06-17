import Foundation
#if canImport(CoreLocation)
import CoreLocation
import Observation

/// Singleton wrapper around CLLocationManager that the rest of
/// the app uses to read the current location fact + drive the
/// OS permission flow. Lives once per process so the manager
/// instance survives view churn and so multiple call sites share
/// the same authorization state without each instantiating a
/// fresh manager (which causes redundant prompts).
///
/// State is `@Observable` so SwiftUI views can show "current
/// location: …" without polling.
@Observable
@MainActor
public final class LocationProvider: NSObject {
    /// Process-wide instance. Hold a reference in AppModel (or
    /// any long-lived environment) — letting the singleton live
    /// in the SpaltKit module keeps both iOS and macOS sharing the
    /// same authorization & cache plumbing.
    public static let shared = LocationProvider()

    /// Last known authorization state from the underlying
    /// CLLocationManager. Mirrors `manager.authorizationStatus`
    /// so SwiftUI views can render "Allow" / "Authorized" / etc.
    /// without holding a delegate reference of their own.
    public private(set) var authorization: CLAuthorizationStatus

    /// "Brooklyn, NY"-style label from the most recent reverse-
    /// geocode. nil when we either have no fix yet or the geocode
    /// hasn't completed (or failed — common when the network's
    /// flaky; the raw coords act as the fallback in that case).
    public private(set) var lastCity: String?

    /// "lat,lng" string from the most recent fix. nil when we
    /// have no fix.
    public private(set) var lastCoords: String?

    /// Wall-clock of the most recent fix. Used by the freshness
    /// gate — we ignore fixes older than `cacheTTL`.
    public private(set) var lastFixAt: Date?

    /// How long a fix is considered "fresh enough" to ride along
    /// on a SendMessage. Picked to be long enough that the user
    /// doesn't pay a wait on every send (CLLocationManager fixes
    /// can take several seconds), but short enough that a long-
    /// running session reflects approximate-current-location.
    private let cacheTTL: TimeInterval = 15 * 60   // 15 min

    private let manager: CLLocationManager
    private let geocoder = CLGeocoder()

    override private init() {
        self.manager = CLLocationManager()
        self.authorization = manager.authorizationStatus
        // Restore the last fix from UserDefaults so a cold launch
        // within the TTL can answer `freshFact()` immediately, before
        // the warmup's async requestLocation() round-trip lands.
        // freshFact()'s TTL check still applies on read, so stale
        // disk values are silently ignored.
        if let cached = Self.loadCachedFix() {
            self.lastCoords = cached.coords
            self.lastCity = cached.city
            self.lastFixAt = cached.at
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Fire the OS permission prompt if we haven't asked yet,
    /// then immediately request a one-shot fix when authorized.
    /// No-op if already denied — the user has to flip the switch
    /// in iOS Settings, which we can't do from here.
    public func requestPermissionAndFix() {
        switch manager.authorizationStatus {
        case .notDetermined:
            #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
        case .authorizedAlways:
            manager.requestLocation()
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        case .authorizedWhenInUse:
            manager.requestLocation()
        #endif
        case .denied, .restricted:
            // Nothing useful we can do programmatically; the
            // PrivacyDetailView is responsible for surfacing a
            // "Open Settings" link in this state.
            break
        @unknown default:
            break
        }
    }

    /// Returns the cached fix if it's still inside the TTL,
    /// otherwise nil. DeviceFactsProvider reads this synchronously
    /// at send time — by design we don't block the send waiting
    /// for a fresh fix; the user's grounding block uses whatever
    /// we last saw, refreshed in the background as new fixes
    /// arrive.
    public func freshFact() -> (city: String?, coords: String)? {
        guard let coords = lastCoords, let at = lastFixAt else { return nil }
        guard Date().timeIntervalSince(at) <= cacheTTL else { return nil }
        return (lastCity, coords)
    }

    /// Kick a refresh in the background. Called from the iOS
    /// composer's send path so the *next* turn benefits from the
    /// latest position even when the cache is still warm enough
    /// for *this* turn.
    public func refreshIfAuthorized() {
        let status = manager.authorizationStatus
        if status == .authorizedAlways {
            manager.requestLocation()
            return
        }
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        if status == .authorizedWhenInUse {
            manager.requestLocation()
        }
        #endif
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // CLLocationManager.requestLocation() is callable from any
        // queue per its docs — fire it directly rather than
        // hopping through Task @MainActor (which would `send` the
        // non-Sendable manager into the closure).
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            manager.requestLocation()
        }
        #else
        if status == .authorizedAlways {
            manager.requestLocation()
        }
        #endif
        Task { @MainActor in
            self.authorization = status
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coords = String(format: "%.4f,%.4f", loc.coordinate.latitude, loc.coordinate.longitude)
        Task { @MainActor in
            let at = Date()
            self.lastCoords = coords
            self.lastFixAt = at
            Self.saveCachedFix(coords: coords, city: self.lastCity, at: at)
            self.geocoder.reverseGeocodeLocation(loc) { placemarks, _ in
                let city = Self.formatPlace(placemarks?.first)
                Task { @MainActor in
                    if let city, !city.isEmpty {
                        self.lastCity = city
                        Self.saveCachedFix(coords: coords, city: city, at: at)
                    }
                }
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Swallow — failures here are common (no signal, network
        // hiccup during geocode) and there's no useful recovery
        // beyond letting the next refresh try again. The cached
        // fix from the previous successful update keeps riding
        // along on sends until the TTL expires.
    }

    // ---- Disk cache (UserDefaults) -----------------------------------
    // The in-memory state is lost on app kill; persisting it lets the
    // very first SendMessage after a relaunch include location (so long
    // as the cached fix is within freshFact's TTL). Stored under a
    // single key as a small dict — no Codable types needed.
    private static let cacheKey = "spalt.location.lastFix"

    private static func loadCachedFix() -> (coords: String, city: String?, at: Date)? {
        let d = UserDefaults.standard
        guard
            let dict = d.dictionary(forKey: cacheKey),
            let coords = dict["coords"] as? String,
            let ts = dict["at"] as? TimeInterval
        else { return nil }
        let city = dict["city"] as? String
        return (coords, city, Date(timeIntervalSince1970: ts))
    }

    private static func saveCachedFix(coords: String, city: String?, at: Date) {
        var dict: [String: Any] = [
            "coords": coords,
            "at": at.timeIntervalSince1970,
        ]
        if let city, !city.isEmpty { dict["city"] = city }
        UserDefaults.standard.set(dict, forKey: cacheKey)
    }

    // Pure: no actor-isolated state touched. Marked nonisolated so the
    // CLGeocoder reverse-geocode callback (which runs off-actor) can
    // call it without warnings.
    nonisolated private static func formatPlace(_ p: CLPlacemark?) -> String? {
        guard let p else { return nil }
        // Prefer "City, ST" (US-style) when both halves are
        // present. Falls back to country + locality in
        // international cases.
        let city = p.locality ?? p.subAdministrativeArea
        let region = p.administrativeArea ?? p.country
        if let city, let region {
            return "\(city), \(region)"
        }
        return city ?? region
    }
}

#endif
