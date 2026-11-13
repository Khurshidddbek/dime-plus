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

    /// Notes and categories of every transaction typed before, counted once for the whole batch.
    static func historyIndex() -> SMSHistoryIndex {
        read(SMSHistoryIndex()) { (context: NSManagedObjectContext) throws -> SMSHistoryIndex in
            let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
            request.predicate = NSPredicate(format: "note != nil AND category != nil")
            request.relationshipKeyPathsForPrefetching = ["category"]
            request.fetchLimit = 50000

            var index = SMSHistoryIndex()

            for transaction in try context.fetch(request) {
                guard let note = transaction.note, let category = transaction.category, let id = category.id,
                      category.income == transaction.income
                else {
                    continue
                }

                index.add(note: note, income: transaction.income, categoryID: id)
            }

            return index
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

/// What the owner typed by hand before, to guess a category for a merchant with no rule yet.
/// "Alifnasiya" finds the notes "Alif Nasiya", "YandexGO Taxi" finds the notes "Taxi" (or the
/// "Taxi" category), and a weak word like the bank name "TBC" alone finds nothing.
struct SMSHistoryIndex {
    struct Stats {
        var total = 0
        var byCategory = [UUID: Int]()
    }

    /// A guess needs at least this many past transactions behind it.
    static let minimumUses = 2

    // Card networks, banks and transfer words say nothing about what was bought.
    static let weakTokens: Set<String> = [
        "p2p", "h2u", "u2h", "h2h", "humo", "uzcard", "visa", "mastercard", "master", "card", "karta",
        "bank", "click", "payme", "edin", "epos", "oplata", "popoln", "perevod", "otkazma",
        "toshkent", "tashkent", "online",
    ]

    private var expense = [String: Stats]()
    private var income = [String: Stats]()

    /// "Alif Nasiya", "ALIFNASIYA.UZ" and "alifnasiyauz" all give "alifnasiya".
    static func compact(_ text: String) -> String {
        var folded = SMSText.fold(text).trimmingCharacters(in: .whitespaces)

        for suffix in [".uz", ".com", ".ru"] where folded.hasSuffix(suffix) {
            folded = String(folded.dropLast(suffix.count))
            break
        }

        var letters = String(folded.filter { character in character.isLetter || character.isNumber })

        if letters.count >= 8, letters.hasSuffix("uz") {
            letters = String(letters.dropLast(2))
        }

        return letters
    }

    mutating func add(note: String, income isIncome: Bool, categoryID: UUID) {
        let key = Self.compact(note)

        if key.count < 3 {
            return
        }

        var stats = (isIncome ? income[key] : expense[key]) ?? Stats()
        stats.total += 1
        stats.byCategory[categoryID, default: 0] += 1

        if isIncome {
            income[key] = stats
        } else {
            expense[key] = stats
        }
    }

    func category(for parsed: ParsedSMS, categories: [SMSCategoryInfo]) -> UUID? {
        let tokens = parsed.merchantKey.split(separator: " ").map { String($0) }
        let full = Self.compact(tokens.joined())
        let strong = tokens.filter { $0.count >= 4 && !Self.weakTokens.contains($0) }.map { Self.compact($0) }
        let core = strong.joined()

        if full.isEmpty {
            return nil
        }

        func hit(_ name: String) -> Bool {
            if name == full || strong.contains(name) {
                return true
            }

            // A longer name that holds the merchant, or the other way round: "tbccashback" and "cashback".
            if core.count >= 6, name.count >= 6 {
                return name.contains(core) || core.contains(name)
            }

            return false
        }

        // 1. Notes: the category used most often for the matching notes.
        var counts = [UUID: Int]()

        let notes = parsed.isIncome ? income : expense

        for (note, stats) in notes where hit(note) {
            for (id, count) in stats.byCategory {
                counts[id, default: 0] += count
            }
        }

        var best: (id: UUID, count: Int)?

        for (id, count) in counts where count >= Self.minimumUses {
            if let current = best, current.count >= count {
                continue
            }

            best = (id: id, count: count)
        }

        if let best = best {
            return best.id
        }

        // 2. A category named like the merchant word: "YandexGO Taxi" and "Taxi".
        for category in categories where category.income == parsed.isIncome {
            let name = Self.compact(category.name)

            if name.count >= 4, hit(name) {
                return category.id
            }
        }

        return nil
    }
}
