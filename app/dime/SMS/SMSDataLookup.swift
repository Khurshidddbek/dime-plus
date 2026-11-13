//
//  SMSDataLookup.swift
//  dime
//
//  Read-only Core Data lookups of the SMS feature. Each one runs on its own background
//  context and returns plain values, so an intent running in background never touches
//  (or saves) what the UI holds in the view context.
//

import CoreData
import Foundation

struct SMSCategoryInfo: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let emoji: String
    let colour: String // hex
    let income: Bool
}

extension SMSCategoryInfo {
    init?(_ category: Category) {
        guard let id = category.id else {
            return nil
        }

        self.init(
            id: id, name: category.wrappedName, emoji: category.wrappedEmoji,
            colour: category.wrappedColour, income: category.income
        )
    }
}

struct SMSTransactionInfo {
    let id: UUID
    let amount: Double
    let income: Bool
    let date: Date
    let note: String
    let categoryID: UUID?
}

enum SMSDataLookup {
    static var isStoreLoaded: Bool {
        DataController.shared.isStoreLoaded
    }

    static func categories() -> [SMSCategoryInfo] {
        read([]) { (context: NSManagedObjectContext) throws -> [SMSCategoryInfo] in
            let request: NSFetchRequest<Category> = Category.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]

            return try context.fetch(request).compactMap { SMSCategoryInfo($0) }
        }
    }

    /// Transactions dated in [from, to), newest first.
    static func transactions(from: Date, to: Date) -> [SMSTransactionInfo] {
        read([]) { (context: NSManagedObjectContext) throws -> [SMSTransactionInfo] in
            let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@ AND date < %@", from as NSDate, to as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

            return try context.fetch(request).compactMap { info($0) }
        }
    }

    /// The category of the newest transaction whose note mentions `token`
    /// ("yandexgo" finds what the owner typed by hand before the first SMS).
    static func historyCategory(token: String, income: Bool) -> UUID? {
        guard token.count >= 3 else {
            return nil
        }

        return read(nil) { (context: NSManagedObjectContext) throws -> UUID? in
            let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "note CONTAINS[cd] %@ AND income == %@", token, NSNumber(value: income))
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 5

            for transaction in try context.fetch(request) {
                if let category = transaction.category, category.income == income, let id = category.id {
                    return id
                }
            }

            return nil
        }
    }

    static func transaction(withID id: UUID) -> SMSTransactionInfo? {
        read(nil) { (context: NSManagedObjectContext) throws -> SMSTransactionInfo? in
            let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            return try context.fetch(request).first.flatMap { info($0) }
        }
    }

    private static func info(_ transaction: Transaction) -> SMSTransactionInfo? {
        guard let id = transaction.id, let date = transaction.date else {
            return nil
        }

        return SMSTransactionInfo(
            id: id, amount: transaction.amount, income: transaction.income, date: date,
            note: transaction.note ?? "", categoryID: transaction.category?.id
        )
    }

    private static func read<T>(_ fallback: T, _ work: (NSManagedObjectContext) throws -> T) -> T {
        let controller = DataController.shared

        guard controller.isStoreLoaded else {
            return fallback
        }

        let context = controller.makeBackgroundContext(name: "sms read")
        var value = fallback

        context.performAndWait {
            do {
                value = try work(context)
            } catch {
                DiagnosticsLog.shared.log("sms", "read FAILED \(DataController.describe(error as NSError))")
            }
        }

        return value
    }
}
