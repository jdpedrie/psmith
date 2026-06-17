import Foundation
import EventKit
import SpaltKit

/// Reminders handlers — same EKEventStore as CalendarTools, but
/// EventKit's permission for reminders is independent from
/// calendars (the user can grant one without the other), so the
/// permission check lives separately.
enum RemindersTools {

    nonisolated(unsafe) private static let store = EKEventStore()

    static func register() {
        let r = DeviceToolRegistry.shared
        r.register(name: "reminders_list", handler: listReminders)
        r.register(name: "reminders_create", handler: createReminder)
        r.register(name: "reminders_complete", handler: completeReminder)
    }

    // MARK: - Handlers

    private static let listReminders: DeviceToolHandler = { inputJSON in
        let input = try decode(ListInput.self, from: inputJSON)
        try await ensureRemindersAccess()

        let calendars = filterLists(by: input.list)
        let predicate: NSPredicate
        switch input.completed {
        case .some(true):
            predicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: nil, ending: nil, calendars: calendars)
        case .some(false):
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
        case .none:
            predicate = store.predicateForReminders(in: calendars)
        }

        let dtos = try await fetchReminderDTOs(matching: predicate)
        let payload = ListOutput(reminders: dtos)
        return try JSONEncoder.iso8601.encode(payload)
    }

    private static let createReminder: DeviceToolHandler = { inputJSON in
        let input = try decode(CreateInput.self, from: inputJSON)
        try await ensureRemindersAccess()

        let reminder = EKReminder(eventStore: store)
        reminder.title = input.title
        if let notes = input.notes { reminder.notes = notes }
        if let due = input.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }
        reminder.calendar = pickList(title: input.list)
            ?? store.defaultCalendarForNewReminders()
            ?? store.calendars(for: .reminder).first
        guard reminder.calendar != nil else {
            throw DeviceToolError.message("no writable reminders list available")
        }
        try store.save(reminder, commit: true)
        return try JSONEncoder.iso8601.encode(ReminderDTO(from: reminder))
    }

    private static let completeReminder: DeviceToolHandler = { inputJSON in
        let input = try decode(CompleteInput.self, from: inputJSON)
        try await ensureRemindersAccess()

        guard let reminder = store.calendarItem(withIdentifier: input.id) as? EKReminder else {
            throw DeviceToolError.message("reminder '\(input.id)' not found")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return try JSONEncoder.iso8601.encode(["completed": input.id])
    }

    // MARK: - Permission

    private static func ensureRemindersAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            return
        case .writeOnly, .notDetermined:
            let granted = try await store.requestFullAccessToReminders()
            if !granted {
                throw DeviceToolError.permissionDenied("reminders")
            }
        case .denied, .restricted:
            throw DeviceToolError.permissionDenied("reminders")
        @unknown default:
            throw DeviceToolError.permissionDenied("reminders")
        }
    }

    // MARK: - List lookup

    private static func filterLists(by title: String?) -> [EKCalendar]? {
        guard let title, !title.isEmpty else { return nil }
        let match = store.calendars(for: .reminder).filter {
            $0.title.compare(title, options: .caseInsensitive) == .orderedSame
        }
        return match.isEmpty ? nil : match
    }

    private static func pickList(title: String?) -> EKCalendar? {
        guard let title, !title.isEmpty else { return nil }
        return store.calendars(for: .reminder).first {
            $0.title.compare(title, options: .caseInsensitive) == .orderedSame
        }
    }

    // MARK: - Fetch helper

    /// EventKit's `fetchReminders(matching:completion:)` is a
    /// callback API; bridge to async/await once so the handlers
    /// stay flat. The fetched reminders are passed back to the
    /// caller wrapped in DTOs so we never cross a Sendable
    /// boundary with the non-Sendable EKReminder type.
    private static func fetchReminderDTOs(matching predicate: NSPredicate) async throws -> [ReminderDTO] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[ReminderDTO], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                let dtos = (reminders ?? []).map(ReminderDTO.init(from:))
                cont.resume(returning: dtos)
            }
        }
    }

    // MARK: - Wire types

    private struct ListInput: Decodable {
        let list: String?
        let completed: Bool?
    }
    private struct ListOutput: Encodable {
        let reminders: [ReminderDTO]
    }
    private struct CreateInput: Decodable {
        let title: String
        let dueDate: Date?
        let list: String?
        let notes: String?
        enum CodingKeys: String, CodingKey {
            case title
            case dueDate = "due_date"
            case list
            case notes
        }
    }
    private struct CompleteInput: Decodable {
        let id: String
    }

    private struct ReminderDTO: Codable {
        let id: String
        let title: String
        let dueDate: Date?
        let completed: Bool
        let list: String
        let notes: String?

        init(from r: EKReminder) {
            self.id = r.calendarItemIdentifier
            self.title = r.title ?? ""
            self.dueDate = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            self.completed = r.isCompleted
            self.list = r.calendar?.title ?? ""
            self.notes = r.notes
        }

        enum CodingKeys: String, CodingKey {
            case id, title, completed, list, notes
            case dueDate = "due_date"
        }
    }
}
