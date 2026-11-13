//
//  InsightsData.swift
//  dime
//

import CoreData
import SwiftUI

// nil objectID is the explicit "No category" slice, so shares always add up to 100 %.
struct InsightsCategoryKey: Hashable {
    let objectID: NSManagedObjectID?

    static let uncategorised = InsightsCategoryKey(objectID: nil)
}

struct InsightsCategoryInfo {
    let key: InsightsCategoryKey
    let name: String
    let emoji: String
    let colour: Color
    let income: Bool

    static var uncategorised: InsightsCategoryInfo {
        InsightsCategoryInfo(
            key: InsightsCategoryKey.uncategorised,
            name: String(localized: "No category"),
            emoji: "",
            colour: Color(hex: "#9A9AA2"),
            income: false
        )
    }
}

// Value copy of one transaction: the views never hold managed objects.
struct InsightsRow: Identifiable {
    let id: NSManagedObjectID
    let amount: Double
    let date: Date
    let income: Bool
    let note: String
    let category: InsightsCategoryKey
    let bucket: Int
}

struct InsightsSnapshot {
    let period: InsightsPeriod
    let bucketStarts: [Date]
    let cutoff: Date // rows from this moment on are upcoming and not counted
    let elapsedBuckets: Int
    let elapsedDays: Int
    let rows: [InsightsRow] // newest first
    let previousPeriod: InsightsPeriod
    let previousCutoff: Date // same number of days into the previous period
    let previousIsWhole: Bool
    let previousRows: [InsightsRow]
    let expenseByBucket: [Double]
    let incomeByBucket: [Double]
    let categories: [InsightsCategoryKey: InsightsCategoryInfo]
}

enum InsightsAggregator {
    // One fetch and one pass for a period plus its like-for-like comparison window.
    // Reads through the view context, so unsaved edits and pending deletes are already reflected.
    static func snapshot(for period: InsightsPeriod, rules: InsightsRules, now: Date,
                         context: NSManagedObjectContext) -> InsightsSnapshot {
        let calendar = rules.calendar
        let starts = period.bucketStarts(rules)
        let cutoff = max(period.start, min(period.end, rules.startOfTomorrow(now)))
        let elapsedDays = max(1, calendar.dateComponents([.day], from: period.start, to: cutoff).day ?? 1)
        let elapsedBuckets = max(1, starts.filter { $0 < cutoff }.count)

        let previous = period.previous(rules)
        let previousIsWhole = cutoff >= period.end
        var previousCutoff = previous.end
        if !previousIsWhole, let shifted = calendar.date(byAdding: .day, value: elapsedDays, to: previous.start) {
            previousCutoff = min(previous.end, shifted)
        }

        let request = NSFetchRequest<Transaction>(entityName: "Transaction")
        request.predicate = NSPredicate(
            format: "(date >= %@ AND date < %@) OR (date >= %@ AND date < %@)",
            period.start as NSDate, cutoff as NSDate, previous.start as NSDate, previousCutoff as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.returnsObjectsAsFaults = false
        let fetched = (try? context.fetch(request)) ?? []

        var rows: [InsightsRow] = []
        var previousRows: [InsightsRow] = []
        var expense = [Double](repeating: 0, count: starts.count)
        var income = [Double](repeating: 0, count: starts.count)
        rows.reserveCapacity(fetched.count)

        for transaction in fetched {
            guard let date = transaction.date else { continue }
            let key = InsightsCategoryKey(objectID: transaction.category?.objectID)

            if date >= period.start {
                guard let bucket = period.bucketIndex(for: date, rules: rules), bucket >= 0, bucket < starts.count else { continue }
                rows.append(InsightsRow(id: transaction.objectID, amount: transaction.amount, date: date,
                                        income: transaction.income, note: transaction.note ?? "",
                                        category: key, bucket: bucket))
                if transaction.income {
                    income[bucket] += transaction.amount
                } else {
                    expense[bucket] += transaction.amount
                }
            } else {
                previousRows.append(InsightsRow(id: transaction.objectID, amount: transaction.amount, date: date,
                                                income: transaction.income, note: transaction.note ?? "",
                                                category: key, bucket: 0))
            }
        }

        return InsightsSnapshot(
            period: period,
            bucketStarts: starts,
            cutoff: cutoff,
            elapsedBuckets: elapsedBuckets,
            elapsedDays: elapsedDays,
            rows: rows,
            previousPeriod: previous,
            previousCutoff: previousCutoff,
            previousIsWhole: previousIsWhole,
            previousRows: previousRows,
            expenseByBucket: expense,
            incomeByBucket: income,
            categories: categories(context: context)
        )
    }

    static func categories(context: NSManagedObjectContext) -> [InsightsCategoryKey: InsightsCategoryInfo] {
        let request = NSFetchRequest<Category>(entityName: "Category")
        request.sortDescriptors = [
            NSSortDescriptor(key: "order", ascending: true),
            NSSortDescriptor(key: "name", ascending: true)
        ]
        let fetched = (try? context.fetch(request)) ?? []

        // Income categories store an asset name instead of a hex colour, so they take the palette in a stable order.
        let palette = Color.colorArray
        var incomeIndex = 0
        var result: [InsightsCategoryKey: InsightsCategoryInfo] = [:]

        for category in fetched {
            let key = InsightsCategoryKey(objectID: category.objectID)
            let colour: Color
            if category.income, !palette.isEmpty {
                colour = Color(hex: palette[incomeIndex % palette.count])
                incomeIndex += 1
            } else {
                colour = Color(hex: category.wrappedColour)
            }
            result[key] = InsightsCategoryInfo(key: key, name: category.wrappedName, emoji: category.wrappedEmoji,
                                               colour: colour, income: category.income)
        }

        return result
    }

    static func earliestDate(context: NSManagedObjectContext) -> Date? {
        let request = NSFetchRequest<Transaction>(entityName: "Transaction")
        request.predicate = NSPredicate(format: "date != nil")
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        request.fetchLimit = 1
        let first = (try? context.fetch(request))?.first
        return first?.date
    }

    // Totals of one category over several periods, for the trend in the category screen.
    static func categoryTotals(key: InsightsCategoryKey, income: Bool, periods: [InsightsPeriod], cutoff: Date,
                               context: NSManagedObjectContext) -> [Double] {
        var totals = [Double](repeating: 0, count: periods.count)
        guard let first = periods.map({ $0.start }).min(), let last = periods.map({ $0.end }).max() else { return totals }

        let range = NSPredicate(format: "date >= %@ AND date < %@", first as NSDate, min(last, cutoff) as NSDate)
        let kind = NSPredicate(format: "income == %@", NSNumber(value: income))
        let owner: NSPredicate
        if let objectID = key.objectID {
            owner = NSPredicate(format: "category == %@", objectID)
        } else {
            owner = NSPredicate(format: "category == nil")
        }

        let request = NSFetchRequest<Transaction>(entityName: "Transaction")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [range, kind, owner])
        request.returnsObjectsAsFaults = false
        let fetched = (try? context.fetch(request)) ?? []

        for transaction in fetched {
            guard let date = transaction.date else { continue }
            if let index = periods.firstIndex(where: { $0.contains(date) }) {
                totals[index] += transaction.amount
            }
        }

        return totals
    }
}
