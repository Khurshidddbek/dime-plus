//
//  InsightsFormat.swift
//  dime
//

import Foundation

// Labels are built once per snapshot in the model, never inside a view body.
enum InsightsFormat {
    static func title(for period: InsightsPeriod, rules: InsightsRules, now: Date = Date.now) -> String {
        switch period.frame {
        case .year:
            return Fmt.string(.year, from: period.start)
        case .month:
            if rules.calendar.component(.day, from: period.start) == 1 {
                return monthAndYear(period.start)
            }
            return range(from: period.start, toExclusive: period.end, rules: rules, now: now)
        case .week:
            return range(from: period.start, toExclusive: period.end, rules: rules, now: now)
        }
    }

    // "3 Nov - 9 Nov", with the year when it is not the current one.
    static func range(from start: Date, toExclusive end: Date, rules: InsightsRules, now: Date = Date.now) -> String {
        let calendar = rules.calendar
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let sameYear = calendar.component(.year, from: last) == calendar.component(.year, from: now)
        let endPattern: Fmt.Pattern = sameYear ? .dayMonth : .dayMonthShortYear

        if last <= start || calendar.isDate(start, inSameDayAs: last) {
            return Fmt.string(endPattern, from: start)
        }
        return Fmt.string(.dayMonth, from: start) + " - " + Fmt.string(endPattern, from: last)
    }

    static func monthAndYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year()).firstUppercased
    }

    // Short label under a bar.
    static func bucketLabel(_ date: Date, frame: ChartTimeFrame, index: Int) -> String {
        switch frame {
        case .week:
            return Fmt.string(.weekday, from: date)
        case .month:
            return index % 7 == 0 ? Fmt.string(.day, from: date) : ""
        case .year:
            return date.formatted(.dateTime.month(.narrow))
        }
    }

    // Full name of a selected bar.
    static func bucketTitle(_ date: Date, frame: ChartTimeFrame) -> String {
        if frame == .year {
            return monthAndYear(date)
        }
        return Fmt.string(.weekdayDayMonth, from: date)
    }

    static func trendLabel(_ period: InsightsPeriod, rules: InsightsRules) -> String {
        switch period.frame {
        case .week:
            return Fmt.string(.dayMonth, from: period.start)
        case .month:
            if rules.calendar.component(.day, from: period.start) == 1 {
                return period.start.formatted(.dateTime.month(.abbreviated))
            }
            return Fmt.string(.dayMonth, from: period.start)
        case .year:
            return Fmt.string(.year, from: period.start)
        }
    }

    static func comparisonLabel(_ snapshot: InsightsSnapshot, rules: InsightsRules) -> String {
        if snapshot.previousIsWhole {
            return title(for: snapshot.previousPeriod, rules: rules)
        }
        return range(from: snapshot.previousPeriod.start, toExclusive: snapshot.previousCutoff, rules: rules)
    }

    // Share of a total: never "0%" for something that exists.
    static func percent(_ share: Double) -> String {
        guard share.isFinite, share > 0 else { return "0%" }
        if share < 0.005 { return "<1%" }
        return String(Int((share * 100).rounded())) + "%"
    }

    // Callers switch to a money difference past 500%, so no ">999%" cap is needed here.
    static func changePercent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "" }
        let value = abs(fraction) * 100
        return String(Int(value.rounded())) + "%"
    }

    static func flowTitle(_ flow: InsightsFlow) -> String {
        switch flow {
        case .expense: return String(localized: "Expenses")
        case .income: return String(localized: "Income")
        case .net: return String(localized: "Net")
        }
    }

    static func time(_ date: Date) -> String {
        Fmt.time(date)
    }

    static func day(_ date: Date) -> String {
        Fmt.string(.weekdayDayMonth, from: date)
    }
}
