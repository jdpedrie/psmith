import Foundation

/// One device-supplied context fact for the active turn — mirrors
/// the proto `spalt.v1.DeviceFact` message. The runtime wraps the
/// proto enum in a Swift enum so call-sites get exhaustive
/// `switch`es and can't pass an unspecified key by accident.
public struct SpaltDeviceFact: Sendable, Hashable {
    public let key: SpaltDeviceFactKey
    public let value: String

    public init(key: SpaltDeviceFactKey, value: String) {
        self.key = key
        self.value = value
    }
}

/// Closed enum of device facts a fact-aware plugin can request.
/// Mirror of `spalt.v1.DeviceFactKey` — keep cases in lockstep
/// with the proto.
public enum SpaltDeviceFactKey: Sendable, Hashable, CaseIterable {
    case locale
    case timezone
    case platform
    case locationCity
    case locationCoords

    var proto: Spalt_V1_DeviceFactKey {
        switch self {
        case .locale: return .locale
        case .timezone: return .timezone
        case .platform: return .platform
        case .locationCity: return .locationCity
        case .locationCoords: return .locationCoords
        }
    }

    init?(proto: Spalt_V1_DeviceFactKey) {
        switch proto {
        case .locale: self = .locale
        case .timezone: self = .timezone
        case .platform: self = .platform
        case .locationCity: self = .locationCity
        case .locationCoords: self = .locationCoords
        case .unspecified, .UNRECOGNIZED:
            return nil
        }
    }
}

extension SpaltDeviceFact {
    var proto: Spalt_V1_DeviceFact {
        var p = Spalt_V1_DeviceFact()
        p.key = key.proto
        p.value = value
        return p
    }
}
