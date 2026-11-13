//
//  NoteSuggestionIndex.swift
//  dime
//

import Combine
import CoreData
import Foundation

struct NoteSuggestion: Identifiable, Equatable {
    let id: String // income flag + folded note
    let note: String // most recent spelling
    let folded: String
    let income: Bool
    let categoryID: UUID? // category last used with this note
    let lastAmount: Double
    let amountIsStable: Bool // the last 3 uses had the same amount
    let count: Int
    let lastUsed: Date
    let score: Double
}

// Past notes of the last 12 months, read once per presentation of the entry screen on a
// background context. Typing only filters the in-memory list, it never fetches.
final class NoteSuggestionIndex: ObservableObject {
    @Published private(set) var suggestions: [NoteSuggestion] = [] // best score first
    @Published private(set) var frequentExpenseCategoryIDs: [UUID] = []
    @Published private(set) var frequentIncomeCategoryIDs: [UUID] = []
    @Published private(set) var isLoaded = false

    private var isLoading = false

    private struct Row {
        let note: String
        let categoryName: String
        let categoryID: UUID?
        let amount: Double
        let date: Date
        let income: Bool
    }

    private struct Built {
        var suggestions: [NoteSuggestion] = []
        var frequentExpense: [UUID] = []
        var frequentIncome: [UUID] = []
    }

    // MARK: Loading

    // Main thread. Does nothing when a load already ran or is running.
    func load(from dataController: DataController) {
        guard !isLoaded, !isLoading else { return }

        isLoading = true

        let context = dataController.makeBackgroundContext(name: "note suggestions")
        let now = Date()
        let oldest = Calendar.current.date(byAdding: .month, value: -12, to: now) ?? now.addingTimeInterval(-365 * 86400)

        context.perform { [weak self] in
            let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "date > %@ AND date <= %@", oldest as NSDate, now as NSDate)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Transaction.date, ascending: false)]
            request.fetchLimit = 6000
            request.relationshipKeyPathsForPrefetching = ["category"]

            var rows: [Row] = []

            do {
                let fetched = try context.fetch(request)
                rows.reserveCapacity(fetched.count)

                for transaction in fetched {
                    rows.append(
                        Row(
                            note: transaction.note ?? "",
                            categoryName: transaction.category?.name ?? "",
                            categoryID: transaction.category?.id,
                            amount: transaction.amount,
                            date: transaction.date ?? now,
                            income: transaction.income
                        )
                    )
                }
            } catch {
                DiagnosticsLog.shared.log("entry", "note suggestions fetch failed: \((error as NSError).code)")
            }

            let built = NoteSuggestionIndex.build(rows: rows, now: now)

            DispatchQueue.main.async {
                guard let self else { return }

                self.suggestions = built.suggestions
                self.frequentExpenseCategoryIDs = built.frequentExpense
                self.frequentIncomeCategoryIDs = built.frequentIncome
                self.isLoading = false
                self.isLoaded = true
            }
        }
    }

    // MARK: Queries (main thread, in memory)

    func frequentCategoryIDs(income: Bool) -> [UUID] {
        income ? frequentIncomeCategoryIDs : frequentExpenseCategoryIDs
    }

    // Empty query: the usual notes. Otherwise prefix matches, then word starts, then the rest.
    func matches(_ query: String, income: Bool, limit: Int = 8) -> [NoteSuggestion] {
        let folded = NoteSuggestionIndex.fold(query)

        var prefixMatches: [NoteSuggestion] = []
        var wordMatches: [NoteSuggestion] = []
        var otherMatches: [NoteSuggestion] = []

        for suggestion in suggestions where suggestion.income == income {
            if folded.isEmpty {
                prefixMatches.append(suggestion)

                if prefixMatches.count == limit {
                    break
                }
            } else if suggestion.folded.hasPrefix(folded) {
                prefixMatches.append(suggestion)
            } else if suggestion.folded.contains(" " + folded) {
                wordMatches.append(suggestion)
            } else if suggestion.folded.contains(folded) {
                otherMatches.append(suggestion)
            }
        }

        return Array((prefixMatches + wordMatches + otherMatches).prefix(limit))
    }

    func exact(_ note: String, income: Bool) -> NoteSuggestion? {
        let folded = NoteSuggestionIndex.fold(note)

        guard !folded.isEmpty else { return nil }

        return suggestions.first { $0.income == income && $0.folded == folded }
    }

    // MARK: Building (any thread, no Core Data objects)

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private struct NoteGroup {
        var note: String
        var folded: String
        var income: Bool
        var categoryID: UUID?
        var amounts: [Double]
        var count: Int
        var lastUsed: Date
        var score: Double
    }

    private struct CategoryUse {
        var recent = 0
        var total = 0
    }

    // rows must be sorted newest first.
    private static func build(rows: [Row], now: Date) -> Built {
        var groups: [String: NoteGroup] = [:]
        var expenseUse: [UUID: CategoryUse] = [:]
        var incomeUse: [UUID: CategoryUse] = [:]

        let recentCutoff = now.addingTimeInterval(-30 * 86400)

        for row in rows {
            if let categoryID = row.categoryID {
                let isRecent = row.date > recentCutoff

                if row.income {
                    var use = incomeUse[categoryID] ?? CategoryUse()
                    use.total += 1
                    if isRecent { use.recent += 1 }
                    incomeUse[categoryID] = use
                } else {
                    var use = expenseUse[categoryID] ?? CategoryUse()
                    use.total += 1
                    if isRecent { use.recent += 1 }
                    expenseUse[categoryID] = use
                }
            }

            let trimmed = row.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = fold(trimmed)

            // Empty notes used to be saved as the category name. Those are not real notes.
            if folded.isEmpty || folded == fold(row.categoryName) {
                continue
            }

            let ageInDays = max(0, now.timeIntervalSince(row.date) / 86400)
            let weight = exp(-ageInDays / 45)
            let key = (row.income ? "1" : "0") + folded

            if var group = groups[key] {
                group.count += 1
                group.score += weight

                if group.amounts.count < 3 {
                    group.amounts.append(row.amount)
                }

                groups[key] = group
            } else {
                // First seen is the newest use: its spelling, category and amount win.
                groups[key] = NoteGroup(
                    note: trimmed,
                    folded: folded,
                    income: row.income,
                    categoryID: row.categoryID,
                    amounts: [row.amount],
                    count: 1,
                    lastUsed: row.date,
                    score: weight
                )
            }
        }

        var built = Built()

        built.suggestions = groups
            .map { key, group in
                NoteSuggestion(
                    id: key,
                    note: group.note,
                    folded: group.folded,
                    income: group.income,
                    categoryID: group.categoryID,
                    lastAmount: group.amounts.first ?? 0,
                    amountIsStable: isStable(group.amounts),
                    count: group.count,
                    lastUsed: group.lastUsed,
                    score: group.score
                )
            }
            .sorted { first, second in
                if first.score != second.score {
                    return first.score > second.score
                }
                return first.id < second.id
            }

        built.frequentExpense = rank(expenseUse)
        built.frequentIncome = rank(incomeUse)

        return built
    }

    private static func isStable(_ amounts: [Double]) -> Bool {
        guard amounts.count == 3, let first = amounts.first, first > 0 else { return false }

        return amounts.allSatisfy { abs($0 - first) < 0.005 }
    }

    // Most used in the last 30 days first, the rest of the year breaks ties.
    private static func rank(_ use: [UUID: CategoryUse]) -> [UUID] {
        use
            .sorted { first, second in
                if first.value.recent != second.value.recent {
                    return first.value.recent > second.value.recent
                }
                if first.value.total != second.value.total {
                    return first.value.total > second.value.total
                }
                return first.key.uuidString < second.key.uuidString
            }
            .map { $0.key }
    }
}
