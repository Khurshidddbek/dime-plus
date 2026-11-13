//
//  DataController+BulkWrites.swift
//  dime
//
//  App target only. Bulk and automated writes (CSV import, SMS) go through a background
//  context: one save, one widget reload, and the view context is never saved, so a
//  pending UI change is not committed by an automation.
//

import CoreData
import Foundation

struct TransactionDraft {
    var id: UUID
    var note: String
    var categoryID: UUID?
    var income: Bool
    var amount: Double
    var date: Date

    init(note: String, categoryID: UUID?, income: Bool, amount: Double, date: Date, id: UUID = UUID()) {
        self.id = id
        self.note = note
        self.categoryID = categoryID
        self.income = income
        self.amount = amount
        self.date = date
    }
}

extension DataController {
    /// Inserts all drafts with one save on a background context and returns their ids
    /// (`Transaction.id`, same order as `drafts`). All or nothing: when a category id is
    /// unknown (`PersistenceError.notFound`) or the save fails, nothing is written.
    /// Blocks until saved; callable from any thread. The Log picks the rows up by itself.
    @discardableResult
    func newTransactions(_ drafts: [TransactionDraft], reason: String = "bulk insert") throws -> [UUID] {
        guard !drafts.isEmpty else {
            return []
        }

        let ids: [UUID] = try performBackgroundWrite(reason) { (context: NSManagedObjectContext) -> [UUID] in
            var categories = [UUID: Category]()
            let wanted = Set(drafts.compactMap { $0.categoryID })

            if !wanted.isEmpty {
                let request: NSFetchRequest<Category> = Category.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", argumentArray: [Array(wanted)])

                for category in try context.fetch(request) {
                    if let id = category.id {
                        categories[id] = category
                    }
                }
            }

            let calendar = Calendar(identifier: .gregorian)
            var created = [UUID]()

            for draft in drafts {
                var category: Category?

                if let categoryID = draft.categoryID {
                    guard let match = categories[categoryID] else {
                        throw PersistenceError.notFound
                    }

                    category = match
                }

                let transaction = Transaction(context: context)
                let trimmed = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)

                transaction.note = trimmed.isEmpty ? (category?.name ?? "") : trimmed
                transaction.income = draft.income
                transaction.category = category
                transaction.amount = draft.amount
                transaction.date = draft.date
                transaction.id = draft.id

                // Same day and month keys as DataController.newTransaction.
                transaction.day = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: draft.date) ?? draft.date

                let components = calendar.dateComponents([.month, .year], from: draft.date)
                transaction.month = calendar.date(from: components) ?? draft.date

                created.append(draft.id)
            }

            return created
        }

        let noteIDs = ids
        DispatchQueue.main.async {
            PersistenceStatus.shared.noteInserted(noteIDs)
        }

        return ids
    }

    /// Hard delete by id on a background context (undo of an automated add).
    /// Ids that do not exist are ignored. Returns how many rows were deleted.
    @discardableResult
    func deleteTransactions(ids: [UUID], reason: String = "bulk delete") throws -> Int {
        guard !ids.isEmpty else {
            return 0
        }

        let count: Int = try performBackgroundWrite(reason) { (context: NSManagedObjectContext) -> Int in
            let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", argumentArray: [ids])

            let matches = try context.fetch(request)
            matches.forEach { context.delete($0) }

            return matches.count
        }

        DispatchQueue.main.async {
            PersistenceStatus.shared.noteDeleted(ids)
        }

        return count
    }

    /// For the launch line of the diagnostics log. -1 when the count is unknown.
    func transactionCountForLog() -> Int {
        guard isStoreLoaded else {
            return -1
        }

        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        return (try? container.viewContext.count(for: request)) ?? -1
    }

    /// View context lookup. Main thread only.
    func findTransaction(withId id: UUID) -> Transaction? {
        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        return results(for: request).first
    }

    /// View context lookup. Main thread only.
    func findCategoryOrNil(withId id: UUID) -> Category? {
        let request: NSFetchRequest<Category> = Category.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        return results(for: request).first
    }

    /// Candidates for "already entered by hand": same direction, dated from the start of
    /// the day before `date` up to the end of the day after it, newest first.
    /// The caller compares amounts. Main thread only.
    func possibleDuplicates(amount _: Double, income: Bool, around date: Date) -> [Transaction] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        guard let from = calendar.date(byAdding: .day, value: -1, to: dayStart),
              let to = calendar.date(byAdding: .day, value: 2, to: dayStart)
        else {
            return []
        }

        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "income == %@ AND date >= %@ AND date < %@", NSNumber(value: income), from as NSDate, to as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Transaction.date, ascending: false)]

        return results(for: request)
    }
}
