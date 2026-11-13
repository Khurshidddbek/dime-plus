//
//  InsightsPeriod.swift
//  dime
//

import Foundation

enum InsightsFlow: Int, CaseIterable, Identifiable {
    case expense = 0
    case income = 1
    case net = 2

    // A new key: "insightsViewIncomeFiltering" is a Bool that Settings still writes.
    static let storageKey = "insightsKind"

    var id: Int { rawValue }
}

// The only place Insights builds a calendar, so period starts, buckets and "is it current" always agree.
struct InsightsRules: Equatable {
    let calendar: Calendar
    let monthStartDay: Int

    static func current() -> InsightsRules {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale.current
        let weekday = UserDefaults.appGroup.integer(forKey: "firstWeekday")
        calendar.firstWeekday = (1 ... 7).contains(weekday) ? weekday : 1
        calendar.minimumDaysInFirstWeek = 4

        let day = UserDefaults.appGroup.integer(forKey: "firstDayOfMonth")
        return InsightsRules(calendar: calendar, monthStartDay: (1 ... 31).contains(day) ? day : 1)
    }

    func startOfTomorrow(_ now: Date) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
    }
}

struct InsightsPeriod: Hashable {
    let frame: ChartTimeFrame
    let start: Date
    let end: Date // exclusive

    static func containing(_ date: Date, frame: ChartTimeFrame, rules: InsightsRules) -> InsightsPeriod {
        let calendar = rules.calendar

        switch frame {
        case .week:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
                return InsightsPeriod(frame: frame, start: interval.start, end: interval.end)
            }
        case .month:
            if let period = monthPeriod(containing: date, rules: rules) {
                return period
            }
        case .year:
            if let interval = calendar.dateInterval(of: .year, for: date) {
                return InsightsPeriod(frame: frame, start: interval.start, end: interval.end)
            }
        }

        let start = calendar.startOfDay(for: date)
        return InsightsPeriod(frame: frame, start: start, end: start.addingTimeInterval(86400))
    }

    func next(_ rules: InsightsRules) -> InsightsPeriod {
        InsightsPeriod.containing(end, frame: frame, rules: rules)
    }

    func previous(_ rules: InsightsRules) -> InsightsPeriod {
        InsightsPeriod.containing(start.addingTimeInterval(-1), frame: frame, rules: rules)
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    // Days for week and month, calendar months for year.
    func bucketStarts(_ rules: InsightsRules) -> [Date] {
        let calendar = rules.calendar
        var result: [Date] = []

        if frame == .year {
            for index in 0 ..< 12 {
                if let date = calendar.date(byAdding: .month, value: index, to: start), date < end {
                    result.append(date)
                }
            }
        } else {
            for index in 0 ..< 40 {
                guard let date = calendar.date(byAdding: .day, value: index, to: start), date < end else { break }
                result.append(date)
            }
        }

        return result
    }

    func bucketIndex(for date: Date, rules: InsightsRules) -> Int? {
        guard contains(date) else { return nil }
        if frame == .year {
            return rules.calendar.dateComponents([.month], from: start, to: date).month
        }
        return rules.calendar.dateComponents([.day], from: start, to: date).day
    }

    func dayCount(_ rules: InsightsRules) -> Int {
        max(1, rules.calendar.dateComponents([.day], from: start, to: end).day ?? 1)
    }

    // A month runs from the chosen start day to the day before the next one. A start day the
    // month does not have (31 in February) falls back to its last day.
    private static func monthPeriod(containing date: Date, rules: InsightsRules) -> InsightsPeriod? {
        let calendar = rules.calendar
        guard let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let previousFirst = calendar.date(byAdding: .month, value: -1, to: firstOfMonth),
              let nextFirst = calendar.date(byAdding: .month, value: 1, to: firstOfMonth)
        else {
            return nil
        }

        let startHere = monthStart(firstOfMonth, rules: rules)
        if date < startHere {
            return InsightsPeriod(frame: .month, start: monthStart(previousFirst, rules: rules), end: startHere)
        }
        return InsightsPeriod(frame: .month, start: startHere, end: monthStart(nextFirst, rules: rules))
    }

    private static func monthStart(_ firstOfMonth: Date, rules: InsightsRules) -> Date {
        let length = rules.calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        let day = min(max(rules.monthStartDay, 1), length)
        return rules.calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) ?? firstOfMonth
    }
}
