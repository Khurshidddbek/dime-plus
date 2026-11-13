//
//  TrashStore.swift
//  dime
//
//  App target only. "Recently deleted": a deleted transaction is copied by value into a
//  JSON file in the app group, then deleted and saved at once. There is no unsaved window
//  and no rollback; undo re-inserts the copy with the same id. Main thread only.
//

import CoreData
import Foundation
import SwiftUI

struct TrashedTransaction: Codable, Identifiable, Equatable {
    var snapshot: TransactionSnapshot
    /// Copy of the category at delete time, so a restore can bring it back if it is gone too.
    var category: CategoryRecord?
    var deletedAt: Date
    /// Rows deleted by one action (a burst, or a category with its rows) share a group.
    var groupID: UUID?

    var id: UUID { snapshot.id }
}

struct TrashedCategory: Codable, Identifiable, Equatable {
    var category: CategoryRecord
    var budget: BudgetRecord?
    var deletedAt: Date
    var groupID: UUID

    var id: UUID { category.id }
}

final class TrashStore: ObservableObject {
    static let shared = TrashStore()

    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Newest first.
    @Published private(set) var items: [TrashedTransaction] = []
    /// Categories deleted through `deleteCategory`, newest first.
    @Published private(set) var categories: [TrashedCategory] = []

    private struct FileContents: Codable {
        var version = 1
        var items: [TrashedTransaction]
        var categories: [TrashedCategory]
    }

    private let dataController = DataController.shared
    private let fileURL: URL

    private init() {
        fileURL = AppFiles.sharedDirectory("Trash").appendingPathComponent("trash.json")
        load()
    }

    // MARK: delete

    /// Copies the transaction to the trash, deletes it and saves immediately.
    /// Throws when the save fails; the copy then stays in the trash (the delete is still
    /// pending in the context and goes through with the next successful save).
    @discardableResult
    func delete(_ transaction: Transaction, groupID: UUID? = nil) throws -> TrashedTransaction {
        let trashed = try delete([transaction], groupID: groupID)

        guard let first = trashed.first else {
            throw PersistenceError.notFound
        }

        return first
    }

    /// Same as `delete(_:)` for several rows with one save.
    @discardableResult
    func delete(_ transactions: [Transaction], groupID: UUID? = nil) throws -> [TrashedTransaction] {
        let context = dataController.container.viewContext
        let live = transactions.filter { !$0.isDeleted && $0.managedObjectContext != nil }

        guard !live.isEmpty else {
            return []
        }

        let now = Date()
        let trashed = live.map { makeTrashed($0, deletedAt: now, groupID: groupID) }

        // The copy is on disk before the row goes away.
        insertIntoTrash(trashed)

        live.forEach { context.delete($0) }

        DiagnosticsLog.shared.log("trash", "deleted \(trashed.count) transaction(s)")

        try dataController.saveOrThrow("delete transaction")

        return trashed
    }

    /// Moves a category, its budget and all its transactions to the trash as one group,
    /// deletes the category (the model cascades to the rows) and saves immediately.
    /// Returns the group id for `restoreGroup`.
    @discardableResult
    func deleteCategory(_ category: Category) throws -> UUID {
        let context = dataController.container.viewContext
        let groupID = UUID()
        let now = Date()

        if category.id == nil {
            category.id = UUID()
        }

        let rows = (category.transactions as? Set<Transaction> ?? []).filter { !$0.isDeleted }
        let trashed = rows.map { makeTrashed($0, deletedAt: now, groupID: groupID) }

        if let record = CategoryRecord(category) {
            let budget = category.budget.map { BudgetRecord($0) }
            var all = categories.filter { $0.id != record.id }
            all.insert(TrashedCategory(category: record, budget: budget, deletedAt: now, groupID: groupID), at: 0)
            categories = all
        }

        insertIntoTrash(trashed)

        context.delete(category)

        DiagnosticsLog.shared.log("trash", "deleted a category with \(trashed.count) transaction(s)")

        // Cascade-deleted rows must not be reported as missing by the integrity check.
        // Before the save: when it fails, the delete still goes out with a later save.
        PersistenceStatus.shared.noteDeleted(trashed.map { $0.id })

        try dataController.saveOrThrow("delete category")

        return groupID
    }

    // MARK: restore

    /// Re-inserts the rows with their original ids and saves. A row that still exists in
    /// the store is only removed from the trash. A missing category is recreated from the
    /// copy. Returns the ids that are back. Throws when the save fails; nothing is
    /// restored then and the trash keeps the rows.
    @discardableResult
    func restore(_ toRestore: [TrashedTransaction]) throws -> [UUID] {
        guard !toRestore.isEmpty else {
            return []
        }

        guard dataController.isStoreLoaded else {
            throw PersistenceError.storeNotLoaded
        }

        let context = dataController.container.viewContext
        let insertedBefore = context.insertedObjects
        let ids = toRestore.map { $0.id }

        let existingRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        existingRequest.predicate = NSPredicate(format: "id IN %@", argumentArray: [ids])
        let existing = Set(dataController.results(for: existingRequest).filter { !$0.isDeleted }.compactMap { $0.id })

        var categoryCache = [UUID: Category]()
        var restoredCategoryIDs = Set<UUID>()

        for item in toRestore where !existing.contains(item.id) {
            let transaction = Transaction(context: context)
            item.snapshot.apply(to: transaction)

            guard let categoryID = item.snapshot.categoryID else {
                continue
            }

            if let cached = categoryCache[categoryID] {
                transaction.category = cached
            } else if let found = dataController.findCategoryOrNil(withId: categoryID), !found.isDeleted {
                categoryCache[categoryID] = found
                transaction.category = found
            } else if let recreated = recreateCategory(id: categoryID, fallback: item.category, in: context) {
                categoryCache[categoryID] = recreated
                restoredCategoryIDs.insert(categoryID)
                transaction.category = recreated
            }
        }

        do {
            try dataController.saveOrThrow("restore from trash")
        } catch {
            context.insertedObjects.subtracting(insertedBefore).forEach { context.delete($0) }
            throw error
        }

        let restored = Set(ids)
        items = items.filter { !restored.contains($0.id) }
        categories = categories.filter { !restoredCategoryIDs.contains($0.id) }
        persist()

        DiagnosticsLog.shared.log("trash", "restored \(ids.count) transaction(s)")

        return ids
    }

    @discardableResult
    func restore(_ item: TrashedTransaction) throws -> [UUID] {
        try restore([item])
    }

    @discardableResult
    func restore(ids: [UUID]) throws -> [UUID] {
        let wanted = Set(ids)
        return try restore(items.filter { wanted.contains($0.id) })
    }

    /// Restores everything deleted by one action. For a deleted category this also brings
    /// back the category itself (and its budget) when it had no transactions.
    @discardableResult
    func restoreGroup(_ groupID: UUID) throws -> [UUID] {
        let rows = items.filter { $0.groupID == groupID }
        let restored = try restore(rows)

        let context = dataController.container.viewContext
        let leftovers = categories.filter { $0.groupID == groupID }

        guard !leftovers.isEmpty else {
            return restored
        }

        let insertedBefore = context.insertedObjects

        for entry in leftovers {
            let found = dataController.findCategoryOrNil(withId: entry.id)

            if found == nil || found?.isDeleted == true {
                _ = recreateCategory(id: entry.id, fallback: entry.category, in: context)
            }
        }

        do {
            try dataController.saveOrThrow("restore category")
        } catch {
            context.insertedObjects.subtracting(insertedBefore).forEach { context.delete($0) }
            throw error
        }

        categories = categories.filter { $0.groupID != groupID }
        persist()

        return restored
    }

    @discardableResult
    func restoreAll() throws -> [UUID] {
        try restore(items)
    }

    // MARK: removing from the trash

    /// Forgets the copies for good.
    func remove(ids: [UUID]) {
        let removed = Set(ids)
        items = items.filter { !removed.contains($0.id) }
        persist()
    }

    func empty() {
        items = []
        categories = []
        persist()
        DiagnosticsLog.shared.log("trash", "emptied")
    }

    /// Drops everything deleted more than 30 days ago. Call at launch and on foreground.
    func purgeExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let keptItems = items.filter { $0.deletedAt >= cutoff }
        let keptCategories = categories.filter { $0.deletedAt >= cutoff }

        guard keptItems.count != items.count || keptCategories.count != categories.count else {
            return
        }

        DiagnosticsLog.shared.log("trash", "purged \(items.count - keptItems.count) expired transaction(s)")

        items = keptItems
        categories = keptCategories
        persist()
    }

    /// Days left before the copy is purged, never negative.
    func daysLeft(for item: TrashedTransaction, now: Date = Date()) -> Int {
        let expires = item.deletedAt.addingTimeInterval(Self.retention)
        return max(0, Int(ceil(expires.timeIntervalSince(now) / 86400)))
    }

    // MARK: private

    private func makeTrashed(_ transaction: Transaction, deletedAt: Date, groupID: UUID?) -> TrashedTransaction {
        TrashedTransaction(
            snapshot: TransactionSnapshot(transaction),
            category: transaction.category.flatMap { CategoryRecord($0) },
            deletedAt: deletedAt,
            groupID: groupID
        )
    }

    private func insertIntoTrash(_ trashed: [TrashedTransaction]) {
        let incoming = Set(trashed.map { $0.id })
        items = trashed + items.filter { !incoming.contains($0.id) }
        persist()
    }

    private func recreateCategory(id: UUID, fallback: CategoryRecord?, in context: NSManagedObjectContext) -> Category? {
        let entry = categories.first { $0.id == id }

        guard let record = entry?.category ?? fallback else {
            return nil
        }

        let category = Category(context: context)
        record.apply(to: category)

        if let budgetRecord = entry?.budget {
            let budget = Budget(context: context)
            budgetRecord.apply(to: budget)
            budget.category = category
        }

        return category
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            let contents = try decoder.decode(FileContents.self, from: data)
            items = contents.items
            categories = contents.categories
        } catch {
            // Keep the unreadable file for a manual look instead of overwriting it.
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("trash-unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            DiagnosticsLog.shared.log("trash", "trash.json unreadable, moved aside: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            // A NaN amount must not stop the copy from reaching the disk before the delete.
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            let data = try encoder.encode(FileContents(items: items, categories: categories))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticsLog.shared.log("trash", "write FAILED \(error.localizedDescription)")
        }
    }
}
