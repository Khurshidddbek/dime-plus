//
//  Helper.swift
//  dime
//
//  Created by Rafael Soh on 13/8/22.
//

import Foundation

extension Transaction {
    var wrappedAmount: Double {
        amount
    }

    var wrappedDate: Date {
        date ?? Date.now
    }

    var wrappedNote: String {
        note ?? ""
    }

    var wrappedCategoryName: String {
        category?.wrappedName ?? ""
    }

    var wrappedColour: String {
        category?.wrappedColour ?? ""
    }

    var nextTransactionDate: Date {
        let base = day ?? Date.now

        if recurringType == 1 {
            return Calendar.current.date(byAdding: .day, value: Int(recurringCoefficient), to: base) ?? base
        } else if recurringType == 2 {
            return Calendar.current.date(byAdding: .day, value: Int(recurringCoefficient) * 7, to: base) ?? base
        } else if recurringType == 3 {
            return Calendar.current.date(byAdding: .month, value: Int(recurringCoefficient), to: base) ?? base
        }

        return date ?? Date.now
    }
}

extension TemplateTransaction {
    var wrappedAmount: Double {
        amount
    }

    var wrappedNote: String {
        note ?? ""
    }

    var wrappedEmoji: String {
        category?.wrappedEmoji ?? ""
    }

    var wrappedColour: String {
        category?.wrappedColour ?? ""
    }
}

extension Category {
    var wrappedColour: String {
        colour ?? "#FFFFFF"
    }

    var wrappedEmoji: String {
        emoji ?? "😄️"
    }

    var wrappedName: String {
        name ?? ""
    }

    var wrappedDate: Date {
        dateCreated ?? Date.now
    }

    var fullName: String {
        wrappedEmoji + "  " + wrappedName
    }

    var allTransactions: [Transaction] {
        let set = transactions as? Set<Transaction> ?? []
        return set.sorted {
            $0.wrappedDate < $1.wrappedDate
        }
    }

    var transactionCount: Int {
        transactions?.count ?? 0
    }
}

public extension Budget {
    var wrappedColour: String {
        category?.wrappedColour ?? "#FFFFFF"
    }

    var wrappedName: String {
        category?.wrappedName ?? ""
    }

    var wrappedEmoji: String {
        category?.wrappedEmoji ?? ""
    }

    var fullName: String {
        return wrappedEmoji + " " + wrappedName
    }

    var wrappedDate: Date {
        return startDate ?? Date.now
    }

    var endDate: Date {
        let start = startDate ?? Date.now
        return BudgetPeriod.end(of: start, type: type) ?? start
    }

    /// Start of the period that contains `now`. Does not change the object,
    /// so widgets (which never save) can show the right period too.
    func currentPeriodStart(now: Date = Date.now) -> Date {
        BudgetPeriod.currentStart(from: startDate ?? now, type: type, now: now)
    }
}

public extension MainBudget {
    var wrappedDate: Date {
        return startDate ?? Date.now
    }

    var endDate: Date {
        let start = startDate ?? Date.now
        return BudgetPeriod.end(of: start, type: type) ?? start
    }

    /// Start of the period that contains `now`. Does not change the object.
    func currentPeriodStart(now: Date = Date.now) -> Date {
        BudgetPeriod.currentStart(from: startDate ?? now, type: type, now: now)
    }
}

/// Budget period maths shared by Budget and MainBudget (type: 1 day, 2 week, 3 month, 4 year).
public enum BudgetPeriod {
    /// nil for an unknown type, so callers cannot loop on a period that never advances.
    public static func end(of start: Date, type: Int16) -> Date? {
        let calendar = Calendar.current

        switch type {
        case 1:
            return calendar.date(byAdding: .day, value: 1, to: start)
        case 2:
            return calendar.date(byAdding: .day, value: 7, to: start)
        case 3:
            return calendar.date(byAdding: .month, value: 1, to: start)
        case 4:
            return calendar.date(byAdding: .year, value: 1, to: start)
        default:
            return nil
        }
    }

    /// Rolls `start` forward until its period contains `now`. Bounded.
    public static func currentStart(from start: Date, type: Int16, now: Date = Date.now) -> Date {
        var current = start
        var steps = 0

        while steps < 5000, let next = end(of: current, type: type), next > current, next <= now {
            current = next
            steps += 1
        }

        return current
    }
}

/// Date cutoffs for Log predicates. A row dated today is always "current",
/// whatever its time, so `date <= now` must not be used to hide rows.
public enum LogCutoff {
    public static func startOfToday(_ now: Date = Date.now) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    public static func startOfTomorrow(_ now: Date = Date.now) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
    }

    /// Seconds until the next local midnight, for a timer that refreshes cutoffs.
    public static func secondsUntilTomorrow(_ now: Date = Date.now) -> TimeInterval {
        max(1, startOfTomorrow(now).timeIntervalSince(now))
    }

    /// `date < start of tomorrow`: everything up to and including the whole of today.
    public static func currentPredicate(now: Date = Date.now) -> NSPredicate {
        NSPredicate(format: "date < %@", startOfTomorrow(now) as NSDate)
    }

    /// `date >= start of tomorrow`: strictly future days.
    public static func upcomingPredicate(now: Date = Date.now) -> NSPredicate {
        NSPredicate(format: "date >= %@", startOfTomorrow(now) as NSDate)
    }

    /// Future days plus every row that still carries a recurrence (the UPCOMING block).
    public static func upcomingOrRecurringPredicate(now: Date = Date.now) -> NSPredicate {
        NSPredicate(format: "date >= %@ OR recurringType > 0", startOfTomorrow(now) as NSDate)
    }

    /// Range on `date` for one local day. Use it instead of equality on the stored
    /// `day`, which stops matching after a time zone change.
    public static func dayPredicate(for day: Date) -> NSPredicate {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return NSPredicate(format: "date >= %@ AND date < %@", start as NSDate, end as NSDate)
    }
}
