//
//  LogModels.swift
//  dime
//
//  App target only. Value copies of Log rows: rows are drawn from these and never
//  read a managed object in body.
//

import CoreData
import SwiftUI

struct LogRowModel: Identifiable, Equatable {
    let id: UUID
    let objectID: NSManagedObjectID
    /// What the row shows: the note, or the category name when the note is empty.
    let note: String
    /// The stored note, for copies.
    let rawNote: String
    let categoryName: String
    let categoryID: NSManagedObjectID?
    let emoji: String
    let colour: String
    let amount: Double
    let income: Bool
    let date: Date
    let recurringType: Int16
    let onceRecurring: Bool
    /// Dated before the start of tomorrow.
    let isCurrent: Bool
    /// The date shown in the UPCOMING block: its own date for a future row,
    /// the next occurrence for a recurring row that is already in the Log.
    let upcomingDate: Date

    var signedAmount: Double {
        income ? amount : -amount
    }

    /// The row in the UPCOMING block stands for the recurrence itself, not for a future entry.
    func stopsRecurring(future: Bool) -> Bool {
        future && isCurrent && recurringType > 0
    }

    init(_ transaction: Transaction, cutoff: Date) {
        objectID = transaction.objectID
        id = transaction.id ?? LogRowModel.fallbackID(for: transaction.objectID)

        let category = transaction.category
        let stored = transaction.note ?? ""

        categoryName = category?.wrappedName ?? ""
        categoryID = category?.objectID
        emoji = category?.wrappedEmoji ?? ""
        colour = category?.wrappedColour ?? "#FFFFFF"
        rawNote = stored
        note = stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (category?.wrappedName ?? "") : stored
        amount = transaction.amount
        income = transaction.income
        recurringType = transaction.recurringType
        onceRecurring = transaction.onceRecurring

        let rowDate = transaction.wrappedDate
        date = rowDate
        isCurrent = rowDate < cutoff
        upcomingDate = rowDate >= cutoff ? rowDate : transaction.nextTransactionDate
    }

    static func newestFirst(_ lhs: LogRowModel, _ rhs: LogRowModel) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }

        if lhs.note != rhs.note {
            return lhs.note < rhs.note
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    // Rows saved by very old versions can lack an id. They still need a stable identity
    // in ForEach, so one is made up per object and kept for the session.
    private static var fallbackIDs = [NSManagedObjectID: UUID]()
    private static let fallbackLock = NSLock()

    private static func fallbackID(for objectID: NSManagedObjectID) -> UUID {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }

        if let known = fallbackIDs[objectID] {
            return known
        }

        let created = UUID()
        fallbackIDs[objectID] = created
        return created
    }
}

struct LogDaySection: Identifiable, Equatable {
    /// Start of the day.
    let id: Date
    let rows: [LogRowModel]
    /// Income minus expenses.
    let total: Double
}

struct LogRowStyle: Equatable {
    var swapTimeLabel: Bool
    var showSign: Bool
}

struct LogTotals: Equatable {
    var spent = 0.0
    var income = 0.0

    var net: Double {
        income - spent
    }
}

enum LogSections {
    /// Groups rows that are already sorted newest first by local day.
    /// Rows that repeat an id inside one day are drawn once (a double import leaves such twins).
    static func group(_ rows: [LogRowModel]) -> [LogDaySection] {
        let calendar = Calendar.current

        var sections = [LogDaySection]()
        var dayStart = Date.distantPast
        var dayEnd = Date.distantPast
        var bucket = [LogRowModel]()
        var seen = Set<UUID>()
        var total = 0.0

        for row in rows {
            if row.date < dayStart || row.date >= dayEnd {
                if !bucket.isEmpty {
                    sections.append(LogDaySection(id: dayStart, rows: bucket, total: total))
                }

                bucket = []
                seen = []
                total = 0
                dayStart = calendar.startOfDay(for: row.date)
                dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            }

            if seen.insert(row.id).inserted {
                bucket.append(row)
                total += row.signedAmount
            }
        }

        if !bucket.isEmpty {
            sections.append(LogDaySection(id: dayStart, rows: bucket, total: total))
        }

        return sections
    }

    /// For screens that still own a sectioned fetch (Insights and Budget day lists).
    static func make(from results: SectionedFetchResults<Date?, Transaction>) -> [LogDaySection] {
        let cutoff = LogCutoff.startOfTomorrow()
        var sections = [LogDaySection]()
        var usedDays = Set<Date>()

        for section in results {
            var seen = Set<UUID>()
            var rows = [LogRowModel]()
            var total = 0.0

            for transaction in section where !transaction.isDeleted {
                let row = LogRowModel(transaction, cutoff: cutoff)

                if seen.insert(row.id).inserted {
                    rows.append(row)
                    total += row.signedAmount
                }
            }

            guard let first = rows.first else {
                continue
            }

            let day = section.id ?? Calendar.current.startOfDay(for: first.date)

            // Section ids must be unique for ForEach.
            if usedDays.insert(day).inserted {
                sections.append(LogDaySection(id: day, rows: rows, total: total))
            }
        }

        return sections
    }
}

/// The blended category colour behind the emoji. Blending goes through UIColor and back,
/// which is too slow to repeat for every row.
enum LogTint {
    private static var cache = [String: Color]()
    private static let lock = NSLock()

    static func fill(_ hex: String) -> Color {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[hex] {
            return cached
        }

        let created = blend(over: Color(hex: hex), withAlpha: 0.73)
        cache[hex] = created
        return created
    }
}
