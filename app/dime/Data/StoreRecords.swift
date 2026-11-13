//
//  StoreRecords.swift
//  dime
//
//  App target only. Value copies of the Core Data rows, used by TrashStore and BackupStore.
//  Every attribute of the model is carried, relationships are kept by id.
//

import CoreData
import Foundation

struct CategoryRecord: Codable, Equatable {
    var id: UUID
    var name: String?
    var emoji: String?
    var colour: String?
    var income: Bool
    var order: Int64
    var dateCreated: Date?

    /// nil when the row has no id yet (BackupStore assigns ids before it reads).
    init?(_ category: Category) {
        guard let id = category.id else {
            return nil
        }

        self.id = id
        name = category.name
        emoji = category.emoji
        colour = category.colour
        income = category.income
        order = category.order
        dateCreated = category.dateCreated
    }

    func apply(to category: Category) {
        category.id = id
        category.name = name
        category.emoji = emoji
        category.colour = colour
        category.income = income
        category.order = order
        category.dateCreated = dateCreated
    }
}

/// All attributes of a Transaction plus the id of its category.
struct TransactionSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var amount: Double
    var date: Date?
    var day: Date?
    var month: Date?
    var note: String?
    var income: Bool
    var onceRecurring: Bool
    var recurringType: Int16
    var recurringCoefficient: Int16
    var categoryID: UUID?

    /// A row without an id gets a fresh one in the snapshot.
    init(_ transaction: Transaction) {
        id = transaction.id ?? UUID()
        amount = transaction.amount
        date = transaction.date
        day = transaction.day
        month = transaction.month
        note = transaction.note
        income = transaction.income
        onceRecurring = transaction.onceRecurring
        recurringType = transaction.recurringType
        recurringCoefficient = transaction.recurringCoefficient
        categoryID = transaction.category?.id
    }

    /// Sets the attributes only, the caller links the category.
    func apply(to transaction: Transaction) {
        transaction.id = id
        transaction.amount = amount
        transaction.date = date
        transaction.day = day
        transaction.month = month
        transaction.note = note
        transaction.income = income
        transaction.onceRecurring = onceRecurring
        transaction.recurringType = recurringType
        transaction.recurringCoefficient = recurringCoefficient
    }
}

struct BudgetRecord: Codable, Equatable {
    var id: UUID
    var amount: Double
    var dateCreated: Date?
    var green: Bool
    var startDate: Date?
    var type: Int16
    var categoryID: UUID?

    init(_ budget: Budget) {
        id = budget.id ?? UUID()
        amount = budget.amount
        dateCreated = budget.dateCreated
        green = budget.green
        startDate = budget.startDate
        type = budget.type
        categoryID = budget.category?.id
    }

    func apply(to budget: Budget) {
        budget.id = id
        budget.amount = amount
        budget.dateCreated = dateCreated
        budget.green = green
        budget.startDate = startDate
        budget.type = type
    }
}

/// MainBudget has no id in the model.
struct MainBudgetRecord: Codable, Equatable {
    var amount: Double
    var dateCreated: Date?
    var green: Bool
    var startDate: Date?
    var type: Int16

    init(_ budget: MainBudget) {
        amount = budget.amount
        dateCreated = budget.dateCreated
        green = budget.green
        startDate = budget.startDate
        type = budget.type
    }

    func apply(to budget: MainBudget) {
        budget.amount = amount
        budget.dateCreated = dateCreated
        budget.green = green
        budget.startDate = startDate
        budget.type = type
    }
}

struct TemplateRecord: Codable, Equatable {
    var id: UUID
    var amount: Double
    var income: Bool
    var note: String?
    var order: Int16
    var recurringType: Int16
    var recurringCoefficient: Int16
    var categoryID: UUID?

    init(_ template: TemplateTransaction) {
        id = template.id ?? UUID()
        amount = template.amount
        income = template.income
        note = template.note
        order = template.order
        recurringType = template.recurringType
        recurringCoefficient = template.recurringCoefficient
        categoryID = template.category?.id
    }

    func apply(to template: TemplateTransaction) {
        template.id = id
        template.amount = amount
        template.income = income
        template.note = note
        template.order = order
        template.recurringType = recurringType
        template.recurringCoefficient = recurringCoefficient
    }
}
