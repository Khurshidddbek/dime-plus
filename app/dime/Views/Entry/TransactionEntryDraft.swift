//
//  TransactionEntryDraft.swift
//  dime
//

import CoreData
import Foundation

// Values the entry screen opens with for a new transaction that is not typed from scratch
// (an SMS, a duplicate, a deep link). Nothing is written until the user confirms.
struct TransactionEntryDraft {
    var amount: Double
    var income: Bool
    // nil = "now", stamped when the user confirms. A set date is kept as is.
    var date: Date?
    var note: String
    var category: Category?

    init(amount: Double, income: Bool, date: Date? = nil, note: String = "", category: Category? = nil) {
        self.amount = amount
        self.income = income
        self.date = date
        self.note = note
        self.category = category
    }

    // Main thread: looks the category up on the view context. An unknown id leaves the category empty.
    init(amount: Double, income: Bool, date: Date? = nil, note: String = "", categoryID: UUID?) {
        var resolved: Category?

        if let categoryID {
            resolved = DataController.shared.findCategoryOrNil(withId: categoryID)
        }

        self.init(amount: amount, income: income, date: date, note: note, category: resolved)
    }

    // Copy of an existing row, dated now.
    init(duplicating transaction: Transaction) {
        var copiedNote = transaction.wrappedNote

        // Old rows carry the category name as the note when none was typed.
        if let name = transaction.category?.name, copiedNote == name {
            copiedNote = ""
        }

        self.init(
            amount: transaction.wrappedAmount,
            income: transaction.income,
            date: nil,
            note: copiedNote,
            category: transaction.category
        )
    }
}
