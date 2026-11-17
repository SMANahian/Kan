import EventKit
import Foundation
import KanCore

/// Finds the calendar event a call belongs to, with EventKit (local; covers every account added
/// to macOS Calendar). Only used when `settings.useCalendar` is on and access was granted; access is
/// requested only from an explicit user action.
///
/// Thread-safe: EventKit calls are serialized by a lock (`event(around:)` blocks briefly).
final class CalendarProvider: CalendarProviding, @unchecked Sendable {
    /// A call matches an event it starts up to this long before.
    static let earlyStart: TimeInterval = 5 * 60
    /// …or during, and at least this long after the event's start (late joiners, short events).
    static let lateStart: TimeInterval = 15 * 60

    private let lock = NSLock()
    private var store: EKEventStore?

    func authorizationStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted, .writeOnly: return .denied
        default: return .unknown
        }
    }

    func requestAccess() async -> PermissionStatus {
        let store = lock.withLock { eventStoreLocked() }
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            KanLog.warning("Calendar access request failed: \(error.localizedDescription)", category: "calendar")
        }
        // A store created before access was granted doesn't see the events: start over.
        lock.withLock { self.store = nil }
        return authorizationStatus()
    }

    func event(around start: Date) -> CalendarMatch? {
        guard authorizationStatus() == .granted else { return nil }
        return lock.withLock { () -> CalendarMatch? in
            let store = eventStoreLocked()
            // Events that started up to 12 h before (long workshops) or just after the call started.
            let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-12 * 3600),
                                                     end: start.addingTimeInterval(Self.earlyStart), calendars: nil)
            let candidates = store.events(matching: predicate).filter { Self.isCandidate($0, callStart: start) }
            guard let best = candidates.min(by: { abs($0.startDate.timeIntervalSince(start)) < abs($1.startDate.timeIntervalSince(start)) })
            else { return nil }
            let attendees = (best.attendees ?? [])
                .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
                .compactMap(Self.displayName)
            return CalendarMatch(title: best.title ?? "", attendees: attendees.kanUniquedCaseInsensitive(),
                                 startDate: best.startDate, endDate: best.endDate)
        }
    }

    /// Not all-day, not cancelled, not declined; the call starts between 5 min before the event and
    /// its end (or 15 min after its start, whichever is later).
    static func isCandidate(_ event: EKEvent, callStart: Date) -> Bool {
        guard !event.isAllDay, event.status != .canceled, (event.title ?? "").kanNonEmpty != nil else { return false }
        if event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined { return false }
        let windowStart = event.startDate.addingTimeInterval(-earlyStart)
        let windowEnd = max(event.endDate, event.startDate.addingTimeInterval(lateStart))
        return callStart >= windowStart && callStart <= windowEnd
    }

    private static func displayName(_ participant: EKParticipant) -> String? {
        if let name = participant.name?.kanNonEmpty, !name.contains("@") { return name }
        // No name: use the address's local part ("rahman" from mailto:rahman@mit.edu).
        let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return address.split(separator: "@").first.map(String.init)?.kanNonEmpty
    }

    private func eventStoreLocked() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }
}
