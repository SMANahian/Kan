import Foundation

/// Calls of one day in the list ("Today", "Yesterday", "Monday 10 Nov").
struct LibraryDaySection<Item: Identifiable>: Identifiable {
    /// Start of the day in the calendar used for grouping.
    let id: Date
    let title: String
    var items: [Item]
}

/// Groups list items by day in the viewer's calendar (not the call's own time zone: the list reads
/// like a calendar). Pure and thread-safe.
enum LibraryDayGrouping {
    /// Sections newest first; items keep their relative order inside a section.
    static func sections<Item: Identifiable>(_ items: [Item], date: (Item) -> Date, now: Date = Date(),
                                             calendar: Calendar = .current,
                                             locale: Locale = .current) -> [LibraryDaySection<Item>] {
        var sections: [LibraryDaySection<Item>] = []
        var indexByDay: [Date: Int] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if let index = indexByDay[day] {
                sections[index].items.append(item)
            } else {
                indexByDay[day] = sections.count
                sections.append(LibraryDaySection(id: day, title: title(forDay: day, now: now, calendar: calendar, locale: locale),
                                           items: [item]))
            }
        }
        return sections.sorted { $0.id > $1.id }
    }

    /// "Today", "Yesterday", otherwise the weekday and date ("Monday 10 Nov"; the year is added
    /// when it isn't the current one).
    static func title(forDay day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).day().month(.abbreviated)
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return day.formatted(style)
    }
}
