import Foundation
import EventKit

/// Handlers + registration for the EventKit-backed device tools:
/// `calendar_list_events`, `calendar_create_event`,
/// `calendar_update_event`, `calendar_delete_event`. EventKit is
/// available on iOS and macOS but the permission flow here is
/// written for iOS 17+; the Mac handler bundles can reuse the same
/// EventStore + JSON encoding by importing this file when the time
/// comes.
///
/// One shared `EKEventStore` per process — Apple's docs explicitly
/// say to reuse a single instance because it owns a Core Data
/// stack. Permission state is queried per call (cheap, cached) so
/// each handler can short-circuit with a clean error before the
/// EventKit call.
public enum CalendarTools {

    // EKEventStore manages its own Core Data stack and is documented
    // as thread-safe for the methods we call; @unchecked Sendable
    // here is a deliberate concurrency-system override matching
    // Apple's documented contract.
    nonisolated(unsafe) private static let store = EKEventStore()

    /// Registers all calendar handlers with the shared
    /// DeviceToolRegistry. Called from the iOS app's bootstrap.
    /// Idempotent — `register(name:handler:)` replaces by name.
    public static func register() {
        let r = DeviceToolRegistry.shared
        r.register(name: "calendar_list_events", handler: listEvents)
        r.register(name: "calendar_create_event", handler: createEvent)
        r.register(name: "calendar_update_event", handler: updateEvent)
        r.register(name: "calendar_delete_event", handler: deleteEvent)
    }

    // MARK: - Handlers

    private static let listEvents: DeviceToolHandler = { inputJSON in
        let input = try decode(ListInput.self, from: inputJSON)
        try await ensureCalendarAccess()

        let calendars = filterCalendars(by: input.calendar)
        let predicate = store.predicateForEvents(
            withStart: input.startDate,
            end: input.endDate,
            calendars: calendars
        )
        let events = store.events(matching: predicate)
        let payload = ListOutput(events: events.map(EventDTO.init(from:)))
        return try JSONEncoder.iso8601.encode(payload)
    }

    private static let createEvent: DeviceToolHandler = { inputJSON in
        let input = try decode(CreateInput.self, from: inputJSON)
        try await ensureCalendarAccess()

        let event = EKEvent(eventStore: store)
        event.title = input.title
        event.startDate = input.start
        event.endDate = input.end
        if let location = input.location { event.location = location }
        if let notes = input.notes { event.notes = notes }
        event.calendar = pickCalendar(title: input.calendar)
            ?? store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first
        guard event.calendar != nil else {
            throw DeviceToolError.message("no writable calendar available")
        }
        try store.save(event, span: .thisEvent, commit: true)
        return try JSONEncoder.iso8601.encode(EventDTO(from: event))
    }

    private static let updateEvent: DeviceToolHandler = { inputJSON in
        let input = try decode(UpdateInput.self, from: inputJSON)
        try await ensureCalendarAccess()

        guard let event = store.event(withIdentifier: input.id) else {
            throw DeviceToolError.message("event '\(input.id)' not found")
        }
        if let title = input.title { event.title = title }
        if let start = input.start { event.startDate = start }
        if let end = input.end { event.endDate = end }
        if let location = input.location { event.location = location }
        if let notes = input.notes { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
        return try JSONEncoder.iso8601.encode(EventDTO(from: event))
    }

    private static let deleteEvent: DeviceToolHandler = { inputJSON in
        let input = try decode(DeleteInput.self, from: inputJSON)
        try await ensureCalendarAccess()

        guard let event = store.event(withIdentifier: input.id) else {
            throw DeviceToolError.message("event '\(input.id)' not found")
        }
        try store.remove(event, span: .thisEvent, commit: true)
        return try JSONEncoder.iso8601.encode(["deleted": input.id])
    }

    // MARK: - Permission

    /// Requests full calendar access if needed; throws on denial so
    /// the dispatcher returns a structured error to the model.
    /// iOS 17 split read/write into separate grants; we go straight
    /// for full so create/update/delete don't need a second prompt.
    private static func ensureCalendarAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return
        case .writeOnly:
            // The list handler needs read too; ask for full.
            fallthrough
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            if !granted {
                throw DeviceToolError.permissionDenied("calendar")
            }
        case .denied, .restricted:
            throw DeviceToolError.permissionDenied("calendar")
        @unknown default:
            throw DeviceToolError.permissionDenied("calendar")
        }
    }

    // MARK: - Calendar lookup

    private static func filterCalendars(by title: String?) -> [EKCalendar]? {
        guard let title, !title.isEmpty else { return nil }
        let match = store.calendars(for: .event).filter {
            $0.title.compare(title, options: .caseInsensitive) == .orderedSame
        }
        return match.isEmpty ? nil : match
    }

    private static func pickCalendar(title: String?) -> EKCalendar? {
        guard let title, !title.isEmpty else { return nil }
        return store.calendars(for: .event).first {
            $0.title.compare(title, options: .caseInsensitive) == .orderedSame
        }
    }

    // MARK: - Wire types

    private struct ListInput: Decodable {
        let startDate: Date
        let endDate: Date
        let calendar: String?
        enum CodingKeys: String, CodingKey {
            case startDate = "start_date"
            case endDate = "end_date"
            case calendar
        }
    }
    private struct ListOutput: Encodable {
        let events: [EventDTO]
    }
    private struct CreateInput: Decodable {
        let title: String
        let start: Date
        let end: Date
        let location: String?
        let notes: String?
        let calendar: String?
    }
    private struct UpdateInput: Decodable {
        let id: String
        let title: String?
        let start: Date?
        let end: Date?
        let location: String?
        let notes: String?
    }
    private struct DeleteInput: Decodable {
        let id: String
    }

    private struct EventDTO: Codable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let location: String?
        let notes: String?
        let calendar: String

        init(from e: EKEvent) {
            self.id = e.eventIdentifier ?? UUID().uuidString
            self.title = e.title ?? ""
            self.start = e.startDate
            self.end = e.endDate
            self.allDay = e.isAllDay
            self.location = e.location
            self.notes = e.notes
            self.calendar = e.calendar?.title ?? ""
        }
    }
}

/// Generic decoder for handler inputs. Centralised so each handler
/// gets the same date-handling + decoded-error surface (the
/// dispatcher will wrap whatever's thrown into the response.error
/// the model sees).
@inline(__always)
public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    if data.isEmpty { return try JSONDecoder.iso8601.decode(T.self, from: "{}".data(using: .utf8)!) }
    return try JSONDecoder.iso8601.decode(T.self, from: data)
}

/// Structured device-tool error surfaced to the model when the
/// handler can give a clean reason. The dispatcher catches anything
/// thrown and stringifies via `String(describing:)`, so a custom
/// description here is what the model sees.
public enum DeviceToolError: Error, CustomStringConvertible {
    case permissionDenied(String)
    case message(String)

    public var description: String {
        switch self {
        case .permissionDenied(let what):
            return "permission denied: \(what) — the user can grant access in system privacy settings"
        case .message(let m):
            return m
        }
    }
}

// MARK: - Shared JSON config

public extension JSONEncoder {
    /// ISO-8601 timestamps everywhere — matches the catalog's
    /// schema descriptions and what every model emits when asked
    /// for a date.
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

public extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
