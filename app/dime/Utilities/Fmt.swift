//
//  Fmt.swift
//  dime
//

import Foundation
import UIKit

// App target only. DateFormatter creation is one of the most expensive Foundation calls and the Log
// used to do it per row on every body pass. Files shared with the extensions must not call this.

enum Fmt {
    // The exact fixed patterns the Log, Insights and Budget screens print today.
    // Localised templates would reorder the fields, that is a separate design change.
    enum Pattern: String, CaseIterable {
        case day = "d"
        case dayMonth = "d MMM"
        case dayMonthYear = "d MMM yyyy"
        case dayMonthShortYear = "d MMM yy"
        case monthYear = "MMM yyyy"
        case monthShortYear = "MMM yy"
        case year = "yyyy"
        case weekday = "EEE"
        case monthNumber = "M"
        case weekdayDayMonth = "EEE, d MMM"
        case weekdayDayMonthShortYear = "EEE, d MMM ''yy"
        case weekdayDayMonthYear = "EEE, d MMM yyyy"
        case shortWeekdayDayMonth = "E, d MMM"
    }

    // MARK: Dates

    static func string(_ pattern: Pattern, from date: Date) -> String {
        formatter(pattern).string(from: date)
    }

    // "3 NOV", the subtitle of upcoming rows and the share image.
    static func uppercased(_ pattern: Pattern, from date: Date) -> String {
        string(pattern, from: date).uppercased()
    }

    // "3 Nov - 9 Nov"
    static func range(_ pattern: Pattern, from start: Date, to end: Date) -> String {
        let shared = formatter(pattern)
        return shared.string(from: start) + " - " + shared.string(from: end)
    }

    // Shared instance: read only, never change its properties.
    static func formatter(_ pattern: Pattern) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        installObserversIfNeeded()

        if let cached = dateFormatters[pattern] { return cached }
        let created = DateFormatter()
        created.dateFormat = pattern.rawValue
        dateFormatters[pattern] = created
        return created
    }

    // MARK: Time

    // "19:30" or "7:30 PM", whatever the device clock setting is.
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static var timeFormatter: DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        installObserversIfNeeded()

        if let cached = cachedTimeFormatter { return cached }
        let created = DateFormatter()
        created.setLocalizedDateFormatFromTemplate("jmm")
        cachedTimeFormatter = created
        return created
    }

    static var uses24HourClock: Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return !template.contains("a")
    }

    // MARK: Log day header

    // "today", "yesterday", "Mon, 3 Nov" or "Mon, 3 Nov '24" for earlier years. Memoised per day.
    static func dayHeader(_ date: Date) -> String {
        lock.lock()
        installObserversIfNeeded()
        let cached = dayHeaders[date]
        lock.unlock()
        if let cached { return cached }

        let calendar = Calendar.current
        let result: String
        if calendar.isDateInToday(date) {
            result = String(localized: "today")
        } else if calendar.isDateInYesterday(date) {
            result = String(localized: "yesterday")
        } else if calendar.component(.year, from: date) < calendar.component(.year, from: Date.now) {
            result = string(.weekdayDayMonthShortYear, from: date)
        } else {
            result = string(.weekdayDayMonth, from: date)
        }

        lock.lock()
        if dayHeaders.count > 4000 { dayHeaders.removeAll() }
        dayHeaders[date] = result
        lock.unlock()
        return result
    }

    // VoiceOver twin of dayHeader: always with the full year.
    static func dayHeaderSpoken(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "today")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "yesterday")
        }
        return string(.weekdayDayMonthYear, from: date)
    }

    // MARK: Relative

    // "2 weeks ago", "in 3 days", "yesterday"
    static func relative(_ date: Date, to reference: Date = Date.now) -> String {
        relativeFormatter(short: false).localizedString(for: date, relativeTo: reference)
    }

    // "2 wk. ago"
    static func relativeShort(_ date: Date, to reference: Date = Date.now) -> String {
        relativeFormatter(short: true).localizedString(for: date, relativeTo: reference)
    }

    // MARK: Invalidation

    // Runs by itself on locale, 12/24 h, time zone and day changes.
    static func reset() {
        lock.lock()
        dateFormatters.removeAll()
        dayHeaders.removeAll()
        cachedTimeFormatter = nil
        fullRelativeFormatter = nil
        shortRelativeFormatter = nil
        lock.unlock()
    }

    // MARK: Internals

    private static let lock = NSLock()
    private static var dateFormatters: [Pattern: DateFormatter] = [:]
    private static var dayHeaders: [Date: String] = [:]
    private static var cachedTimeFormatter: DateFormatter?
    private static var fullRelativeFormatter: RelativeDateTimeFormatter?
    private static var shortRelativeFormatter: RelativeDateTimeFormatter?
    private static var observers: [NSObjectProtocol] = []

    private static func relativeFormatter(short: Bool) -> RelativeDateTimeFormatter {
        lock.lock()
        defer { lock.unlock() }
        installObserversIfNeeded()

        if let cached = short ? shortRelativeFormatter : fullRelativeFormatter { return cached }
        let created = RelativeDateTimeFormatter()
        created.dateTimeStyle = .named
        created.unitsStyle = short ? .short : .full
        if short {
            shortRelativeFormatter = created
        } else {
            fullRelativeFormatter = created
        }
        return created
    }

    // Caller holds the lock.
    private static func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSLocale.currentLocaleDidChangeNotification,
            Notification.Name.NSSystemTimeZoneDidChange,
            Notification.Name.NSCalendarDayChanged,
            UIApplication.significantTimeChangeNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Fmt.reset()
            }
            observers.append(token)
        }
    }
}
