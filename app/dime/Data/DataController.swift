//
//  DataController.swift
//  Bonsai
//
//  Created by Rafael Soh on 3/6/22.
//

import CoreData
import Foundation
import SwiftUI
import WidgetKit

@available(iOS 16, *)
enum CustomError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notFound,
         coreDataSave,
         unknownId(id: String),
         unknownError(message: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .unknownError(message): return "An unknown error occurred: \(message)"
        case let .unknownId(id): return "No category with an ID matching: \(id)"
        case .notFound: return "Category not found"
        case .coreDataSave: return "Couldn't save the transaction. Open Dime and try again."
        }
    }
}

/// Plain error type: this file is shared with the extensions, so it cannot throw CustomError.
enum PersistenceError: Error, LocalizedError {
    case storeNotLoaded
    case saveFailed(NSError)
    case notFound

    var errorDescription: String? {
        switch self {
        case .storeNotLoaded:
            return NSLocalizedString("Your data could not be opened.", comment: "")
        case let .saveFailed(error):
            return error.localizedDescription
        case .notFound:
            return NSLocalizedString("This item no longer exists.", comment: "")
        }
    }

    var underlyingError: NSError? {
        if case let .saveFailed(error) = self {
            return error
        }

        return nil
    }
}

enum SaveOutcome {
    case saved
    case nothingToSave
    case failed(NSError)

    var isFailure: Bool {
        if case .failed = self {
            return true
        }

        return false
    }
}

struct SaveFailure {
    let reason: String
    let error: NSError
    let date: Date
}

extension Notification.Name {
    /// View context save failed. userInfo: "error" (NSError), "reason" (String). Posted on the saving thread (main).
    static let dimeSaveFailed = Notification.Name("dime.persistence.saveFailed")
    /// A view context save went through after an earlier failure.
    static let dimeSaveRecovered = Notification.Name("dime.persistence.saveRecovered")
    /// `isStoreLoaded` / `storeLoadError` changed.
    static let dimeStoreLoadStateChanged = Notification.Name("dime.persistence.storeLoadStateChanged")
    /// `deleteAll()` finished (batch deletes post no context notifications).
    static let dimeStoreErased = Notification.Name("dime.persistence.storeErased")
}

class DataController: ObservableObject {
    enum Role {
        case app, appExtension
    }

    /// Widgets and intent extensions open the same sqlite without CloudKit mirroring.
    static let role: Role = Bundle.main.bundlePath.hasSuffix(".appex") ? .appExtension : .app

    static let shared = DataController()

    var container = NSPersistentCloudKitContainer(name: "MainModel")

    let role: Role = DataController.role

    // Deliberately not @Published: this object is an @EnvironmentObject of most views.
    // The app observes the notifications above (see PersistenceStatus).
    private(set) var isStoreLoaded = false
    private(set) var storeLoadError: NSError?
    private(set) var lastSaveFailure: SaveFailure?
    private(set) var lastCloudExportDate: Date?
    private(set) var lastCloudError: NSError?

    private var fallbackStore: NSPersistentStore?
    private var observers = [NSObjectProtocol]()
    private var historyContext: NSManagedObjectContext?
    private let historyTokenKey = "persistentHistoryToken"

    init() {
        // Widgets can run before the app's first launch; 0 is not a valid weekday.
        UserDefaults.appGroup.register(defaults: ["firstWeekday": UserDefaults.regionFirstWeekday, "firstDayOfMonth": 1, "haptics": 1])

        let description = NSPersistentStoreDescription()

        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        // History tracking stays on in every process, the app's mirroring relies on it.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        if role == .app && AppIdentifiers.cloudSyncEnabled {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: AppIdentifiers.cloudContainer)
        } else {
            description.cloudKitContainerOptions = nil
        }

        if let url = AppIdentifiers.appGroupContainerURL {
            description.url = url.appendingPathComponent("Main.sqlite")
        } else {
            description.url = NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("Main.sqlite")
            DiagnosticsLog.shared.log("store", "app group container missing, using the default directory")
        }

        container.persistentStoreDescriptions = [description]

        loadStore()

        if role == .app {
            startObserving()
        }
    }

    // MARK: store loading

    @discardableResult
    private func loadStore() -> Bool {
        var loadError: NSError?
        var loadedURL: URL?

        // Synchronous: shouldAddStoreAsynchronously is off.
        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                loadError = error
            } else {
                loadedURL = description.url
            }
        }

        if let loadError = loadError {
            isStoreLoaded = false
            storeLoadError = loadError
            DiagnosticsLog.shared.log("store", "load FAILED \(Self.describe(loadError))")

            // Stray fetches then return nothing instead of raising. save() refuses to write here.
            if fallbackStore == nil {
                fallbackStore = try? container.persistentStoreCoordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
            }
        } else {
            isStoreLoaded = true
            storeLoadError = nil

            let viewContext = container.viewContext
            viewContext.automaticallyMergesChangesFromParent = true
            // The default error policy turns any conflict into a save that fails forever.
            viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
            viewContext.transactionAuthor = role == .app ? "app" : "extension"
            viewContext.name = "view"

            DiagnosticsLog.shared.log("store", "loaded role=\(role == .app ? "app" : "extension") cloudKit=\(role == .app && AppIdentifiers.cloudSyncEnabled) url=\(loadedURL?.path ?? "?")")
        }

        NotificationCenter.default.post(name: .dimeStoreLoadStateChanged, object: self)

        return isStoreLoaded
    }

    /// For the recovery screen. Returns true when the store is open.
    @discardableResult
    func retryLoadStore() -> Bool {
        guard !isStoreLoaded else {
            return true
        }

        if let store = fallbackStore {
            try? container.persistentStoreCoordinator.remove(store)
            fallbackStore = nil
        }

        container.viewContext.reset()

        return loadStore()
    }

    // MARK: remote changes and CloudKit events (app only)

    private func startObserving() {
        let center = NotificationCenter.default

        let context = container.newBackgroundContext()
        context.name = "history"
        historyContext = context

        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator, queue: nil) { [weak self] _ in
            self?.consumeRemoteChanges()
        })

        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: nil) { [weak self] notification in
            self?.handleCloudEvent(notification)
        })
    }

    private var storedHistoryToken: NSPersistentHistoryToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: historyTokenKey) else {
                return nil
            }

            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
        }

        set {
            if let token = newValue, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: historyTokenKey)
            }
        }
    }

    // Saves from this process (view context, background contexts, CloudKit import) reach the
    // view context through automaticallyMergesChangesFromParent. Only writes of another
    // process (author "extension") have to be merged from persistent history.
    private func consumeRemoteChanges() {
        guard isStoreLoaded, let context = historyContext else {
            return
        }

        context.perform { [weak self] in
            guard let self = self else {
                return
            }

            guard let lastToken = self.storedHistoryToken else {
                // First run: nothing older can be missing from a view context created after it.
                self.storedHistoryToken = self.container.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: nil)
                return
            }

            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: lastToken)

            guard let result = (try? context.execute(request)) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction]
            else {
                // An expired or foreign token fails on every fetch: start again from now,
                // otherwise writes of the extensions would never be merged again.
                self.storedHistoryToken = self.container.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: nil)
                DiagnosticsLog.shared.log("store", "history fetch failed, token reset")
                return
            }

            guard let newest = transactions.last else {
                return
            }

            self.storedHistoryToken = newest.token

            let foreign = transactions.filter { $0.author == "extension" }

            guard !foreign.isEmpty else {
                return
            }

            let notifications = foreign.map { $0.objectIDNotification() }
            let viewContext = self.container.viewContext

            viewContext.perform {
                notifications.forEach { viewContext.mergeChanges(fromContextDidSave: $0) }
            }

            DiagnosticsLog.shared.log("store", "merged \(foreign.count) history transaction(s) written by an extension")
        }
    }

    private func handleCloudEvent(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
              let endDate = event.endDate
        else {
            return
        }

        let kind: String

        switch event.type {
        case .setup:
            kind = "setup"
        case .import:
            kind = "import"
        case .export:
            kind = "export"
        @unknown default:
            kind = "other"
        }

        let error = event.error as NSError?
        let succeeded = event.succeeded
        let isExport = event.type == .export

        if let error = error {
            DiagnosticsLog.shared.log("cloudkit", "\(kind) FAILED \(Self.describe(error))")
        } else {
            DiagnosticsLog.shared.log("cloudkit", "\(kind) \(succeeded ? "ok" : "not finished")")
        }

        DispatchQueue.main.async {
            if let error = error {
                self.lastCloudError = error
            } else if succeeded {
                self.lastCloudError = nil

                if isExport {
                    self.lastCloudExportDate = endDate
                }
            }
        }
    }

    static func describe(_ error: NSError) -> String {
        var parts = ["\(error.domain) \(error.code)", error.localizedDescription]

        if let conflicts = error.userInfo[NSPersistentStoreSaveConflictsErrorKey] as? [NSMergeConflict] {
            let names = conflicts.map { $0.sourceObject.entity.name ?? "?" }
            parts.append("conflicts: \(names.joined(separator: ","))")
        }

        if let detailed = error.userInfo[NSDetailedErrorsKey] as? [NSError] {
            let codes = detailed.map { "\($0.domain) \($0.code)" }
            parts.append("details: \(codes.joined(separator: ","))")
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying: \(underlying.domain) \(underlying.code)")
        }

        return parts.joined(separator: " | ")
    }

    // internal variables

    var tipCounter: Int {
        get {
            UserDefaults.standard.integer(forKey: "tipCounter")
        }

        set {
            UserDefaults.standard.set(newValue, forKey: "tipCounter")
        }
    }

    var addedTransaction: Bool {
        get {
            UserDefaults.appGroup.bool(forKey: "newTransactionAdded")
        }

        set {
            UserDefaults.appGroup.set(newValue, forKey: "newTransactionAdded")
        }
    }

    // adding or deleting

    /// Erases every entity. Returns false when at least one batch delete failed.
    @discardableResult
    func deleteAll() -> Bool {
        guard isStoreLoaded else {
            return false
        }

        var failures = [String]()

        for entity in ["Transaction", "TemplateTransaction", "Budget", "MainBudget", "Category"] {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

            do {
                try container.viewContext.executeAndMergeChanges(using: batchDeleteRequest)
            } catch {
                failures.append(entity)
                DiagnosticsLog.shared.log("erase", "\(entity) FAILED \(Self.describe(error as NSError))")
            }
        }

        DiagnosticsLog.shared.log("erase", failures.isEmpty ? "all entities erased" : "incomplete: \(failures.joined(separator: ","))")

        NotificationCenter.default.post(name: .dimeStoreErased, object: self)
        reloadWidgets()

        return failures.isEmpty
    }

    // MARK: saving

    /// Legacy entry point. Never throws, but a failure is logged and broadcast
    /// (`.dimeSaveFailed`), it is no longer swallowed.
    func save() {
        _ = save("unspecified")
    }

    /// Saves the view context and reports the outcome instead of throwing.
    @discardableResult
    func save(_ reason: String) -> SaveOutcome {
        do {
            return try saveOrThrow(reason) ? .saved : .nothingToSave
        } catch let PersistenceError.saveFailed(error) {
            return .failed(error)
        } catch {
            return .failed(error as NSError)
        }
    }

    /// Saves the view context. Main thread only. Returns false when there was nothing to save.
    /// A failure is logged and broadcast before it is thrown; the context is left as it is.
    @discardableResult
    func saveOrThrow(_ reason: String) throws -> Bool {
        let context = container.viewContext

        guard context.hasChanges else {
            // The failed changes were undone, nothing is unsaved: without this the
            // "Not saved" state would stay on until the next real save.
            if lastSaveFailure != nil {
                lastSaveFailure = nil
                NotificationCenter.default.post(name: .dimeSaveRecovered, object: self)
            }

            return false
        }

        guard isStoreLoaded else {
            let error = NSError(domain: "dime.persistence", code: 1, userInfo: [NSLocalizedDescriptionKey: "The store is not loaded"])
            reportSaveFailure(error, reason: reason)
            throw PersistenceError.storeNotLoaded
        }

        let counts = "+\(context.insertedObjects.count) ~\(context.updatedObjects.count) -\(context.deletedObjects.count)"

        do {
            try context.save()
        } catch {
            let firstError = error as NSError

            guard Self.isMergeConflict(firstError) else {
                reportSaveFailure(firstError, reason: reason)
                throw PersistenceError.saveFailed(firstError)
            }

            // refreshAllObjects keeps pending changes and drops the stale snapshots behind the conflict.
            DiagnosticsLog.shared.log("save", "\(reason): merge conflict, retrying once | \(Self.describe(firstError))")
            context.refreshAllObjects()

            do {
                try context.save()
            } catch {
                let secondError = error as NSError
                reportSaveFailure(secondError, reason: reason)
                throw PersistenceError.saveFailed(secondError)
            }
        }

        DiagnosticsLog.shared.log("save", "\(reason): ok \(counts)")

        if lastSaveFailure != nil {
            lastSaveFailure = nil
            NotificationCenter.default.post(name: .dimeSaveRecovered, object: self)
        }

        reloadWidgets()

        return true
    }

    private static func isMergeConflict(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && (error.code == NSManagedObjectMergeError || error.code == NSPersistentStoreSaveConflictsError)
    }

    private func reportSaveFailure(_ error: NSError, reason: String) {
        DiagnosticsLog.shared.log("save", "\(reason): FAILED \(Self.describe(error))")

        lastSaveFailure = SaveFailure(reason: reason, error: error, date: Date())

        NotificationCenter.default.post(name: .dimeSaveFailed, object: self, userInfo: ["error": error, "reason": reason])
    }

    /// Widgets are reloaded only by the app and only after data really reached the store.
    func reloadWidgets() {
        if role == .app {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: background writes

    /// A private-queue context for bulk or automated writes. Its saves reach the view
    /// context through automaticallyMergesChangesFromParent.
    func makeBackgroundContext(name: String) -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.transactionAuthor = role == .app ? "app" : "extension"
        context.name = name
        context.undoManager = nil
        return context
    }

    /// Runs `work` on a fresh background context and saves that context once.
    /// Blocks the caller until done, callable from any thread. Never saves the view
    /// context, so nothing the UI holds unsaved is committed as a side effect.
    /// When `work` or the save throws nothing is written.
    func performBackgroundWrite<T>(_ reason: String, _ work: (NSManagedObjectContext) throws -> T) throws -> T {
        guard isStoreLoaded else {
            DiagnosticsLog.shared.log("save", "\(reason): refused, the store is not loaded")
            throw PersistenceError.storeNotLoaded
        }

        let context = makeBackgroundContext(name: reason)
        var counts = ""

        let value: T = try context.performAndWait { () throws -> T in
            let result = try work(context)

            guard context.hasChanges else {
                return result
            }

            counts = "+\(context.insertedObjects.count) ~\(context.updatedObjects.count) -\(context.deletedObjects.count)"

            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                DiagnosticsLog.shared.log("save", "\(reason): FAILED (background) \(Self.describe(nsError))")
                context.reset()
                throw PersistenceError.saveFailed(nsError)
            }

            return result
        }

        if !counts.isEmpty {
            DiagnosticsLog.shared.log("save", "\(reason): ok (background) \(counts)")
            reloadWidgets()
        }

        return value
    }

    // MARK: recurring transactions and budget periods

    /// Inserts the instances that are due for one recurring source row. Does not save.
    /// Returns true when the context was changed.
    @discardableResult
    func generateRecurring(for transaction: Transaction) -> Bool {
        let type = transaction.recurringType
        let coefficient = Int(transaction.recurringCoefficient)

        // A zero or negative step would never advance the date.
        guard type >= 1, type <= 3, coefficient > 0 else {
            return false
        }

        let tomorrow = LogCutoff.startOfTomorrow()
        var holdingDate = transaction.nextTransactionDate

        guard holdingDate < tomorrow else {
            return false
        }

        let calendar = Calendar.current
        let monthCalendar = Calendar(identifier: .gregorian)
        var lastCreated: Transaction?
        var handedOver = false
        var created = 0

        while holdingDate < tomorrow {
            guard created < 1000 else {
                DiagnosticsLog.shared.log("recurring", "stopped after 1000 instances for one series")
                break
            }

            let nextDate: Date?

            if type == 1 {
                nextDate = calendar.date(byAdding: .day, value: coefficient, to: holdingDate)
            } else if type == 2 {
                nextDate = calendar.date(byAdding: .day, value: coefficient * 7, to: holdingDate)
            } else {
                nextDate = calendar.date(byAdding: .month, value: coefficient, to: holdingDate)
            }

            guard let newDate = nextDate, newDate > holdingDate else {
                DiagnosticsLog.shared.log("recurring", "next date does not advance, series skipped")
                break
            }

            let newTransaction = Transaction(context: container.viewContext)
            newTransaction.note = transaction.wrappedNote
            newTransaction.category = transaction.category
            newTransaction.amount = transaction.wrappedAmount
            newTransaction.date = holdingDate
            newTransaction.id = UUID()
            newTransaction.income = transaction.income
            newTransaction.day = holdingDate

            let dateComponents = monthCalendar.dateComponents([.month, .year], from: holdingDate)
            newTransaction.month = monthCalendar.date(from: dateComponents) ?? holdingDate

            newTransaction.onceRecurring = true

            if newDate >= tomorrow {
                newTransaction.recurringType = type
                newTransaction.recurringCoefficient = transaction.recurringCoefficient
                handedOver = true
            } else {
                newTransaction.recurringType = 0
            }

            lastCreated = newTransaction
            created += 1
            holdingDate = newDate
        }

        guard let last = lastCreated else {
            return false
        }

        // The loop was cut short: the newest instance keeps the series alive for the next run.
        if !handedOver {
            last.recurringType = type
            last.recurringCoefficient = transaction.recurringCoefficient
        }

        transaction.recurringType = 0

        return true
    }

    func updateRecurringTransaction(transaction: Transaction) {
        if generateRecurring(for: transaction) {
            save("recurring")
        }
    }

    func updateRecurringTransactions() {
        guard isStoreLoaded else {
            return
        }

        let recurringTransactions = results(for: fetchRequestForRecurringTransactions())
        var changed = false

        recurringTransactions.forEach { transaction in
            if generateRecurring(for: transaction) {
                changed = true
            }
        }

        if changed {
            save("recurring")
        }
    }

    func updateBudgetDates() {
        guard isStoreLoaded else {
            return
        }

        let budgets = results(for: fetchRequestForBudgets())
        let mainBudget = results(for: fetchRequestForMainBudget())

        budgets.forEach { budget in
            guard let start = budget.startDate else {
                return
            }

            let rolled = BudgetPeriod.currentStart(from: start, type: budget.type)

            if rolled != start {
                budget.startDate = rolled
            }
        }

        mainBudget.forEach { budget in
            guard let start = budget.startDate else {
                return
            }

            let rolled = BudgetPeriod.currentStart(from: start, type: budget.type)

            if rolled != start {
                budget.startDate = rolled
            }
        }

        save("budget periods")
    }

    // MARK: new transaction

    private func insertTransaction(note: String, category: Category?, income: Bool, amount: Double, date: Date, repeatType: Int, repeatCoefficient: Int) -> Transaction {
        let transaction = Transaction(context: container.viewContext)

        if note.trimmingCharacters(in: .whitespacesAndNewlines) == "" {
            transaction.note = category?.wrappedName ?? ""
        } else {
            transaction.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        transaction.income = income

        if let unwrappedCategory = category {
            transaction.category = unwrappedCategory
        }

        transaction.amount = amount
        transaction.date = date
        transaction.id = UUID()

        let calendar = Calendar(identifier: .gregorian)

        transaction.day = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: date) ?? Date.now

        let dateComponents = calendar.dateComponents([.month, .year], from: date)

        transaction.month = calendar.date(from: dateComponents) ?? Date.now

        if repeatType > 0 {
            transaction.onceRecurring = true
            transaction.recurringType = Int16(clamping: repeatType)
            transaction.recurringCoefficient = Int16(clamping: repeatCoefficient)
            generateRecurring(for: transaction)
        }

        return transaction
    }

    /// Old signature, kept for existing call sites. A failed save leaves the row in the
    /// context and is broadcast. New code should call `newTransactionOrThrow`.
    func newTransaction(note: String, category: Category?, income: Bool, amount: Double, date: Date, repeatType: Int, repeatCoefficient: Int, delay _: Bool) -> Transaction {
        let transaction = insertTransaction(note: note, category: category, income: income, amount: amount, date: date, repeatType: repeatType, repeatCoefficient: repeatCoefficient)

        save("new transaction")

        return transaction
    }

    /// Inserts and saves on the view context. When the save fails, everything this call
    /// inserted is removed again, so no ghost row stays in the Log, and the error is thrown.
    func newTransactionOrThrow(note: String, category: Category?, income: Bool, amount: Double, date: Date, repeatType: Int = 0, repeatCoefficient: Int = 1) throws -> Transaction {
        guard isStoreLoaded else {
            throw PersistenceError.storeNotLoaded
        }

        let context = container.viewContext
        let insertedBefore = context.insertedObjects

        let transaction = insertTransaction(note: note, category: category, income: income, amount: amount, date: date, repeatType: repeatType, repeatCoefficient: repeatCoefficient)

        do {
            try saveOrThrow("new transaction")
        } catch {
            context.insertedObjects.subtracting(insertedBefore).forEach { context.delete($0) }
            throw error
        }

        return transaction
    }

    func newTemplateTransaction(order: Int) {
        if let match = getTemplateTransaction(order: order) {
            if let unwrappedCategory = match.category {
                _ = newTransaction(note: match.note ?? "", category: unwrappedCategory, income: match.income, amount: match.amount, date: Date.now, repeatType: Int(match.recurringType), repeatCoefficient: Int(match.recurringCoefficient), delay: false)

                addedTransaction = true
            }
        }
    }

    // fetching

    func fetchRequestForRecurringTransactions() -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        itemRequest.predicate = NSPredicate(format: "%K > %i", #keyPath(Transaction.recurringType), 0)
        return itemRequest
    }

    func getTemplateTransaction(order: Int) -> TemplateTransaction? {
        let itemRequest: NSFetchRequest<TemplateTransaction> = TemplateTransaction.fetchRequest()

        itemRequest.predicate = NSPredicate(format: "order == %d", order)

        let results = results(for: itemRequest)

        if results.count > 1 {
            let output = results.first

            for i in 1 ..< results.count {
                container.viewContext.delete(results[i])
            }

            save()

            return output
        } else {
            return results.first
        }
    }

    func getAllTemplateTransactions() -> [TemplateTransaction] {
        let itemRequest: NSFetchRequest<TemplateTransaction> = TemplateTransaction.fetchRequest()

        return results(for: itemRequest)
    }

    func fetchRequestForRecentTransactions(type: TimePeriod) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        var calendar = Calendar(identifier: .gregorian)

        calendar.firstWeekday = UserDefaults.appGroup.storedFirstWeekday
        calendar.minimumDaysInFirstWeek = 4

        switch type {
        case .unknown:
            return itemRequest
        case .day:
            let today = calendar.startOfDay(for: Date.now)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: today)!

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), today as CVarArg)
            let endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), nextDay as CVarArg)

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]

            return itemRequest
        case .week:
            let dateComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: Date.now)

            let thisWeek = calendar.date(from: dateComponents)!
            let nextWeek = calendar.date(byAdding: .day, value: 7, to: thisWeek)!

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisWeek as CVarArg)
            let endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), nextWeek as CVarArg)

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]

            return itemRequest
        case .month:
            let dateComponents = calendar.dateComponents([.month, .year], from: Date.now)

            let thisMonth = calendar.date(from: dateComponents)!
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: thisMonth)!

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisMonth as CVarArg)
            let endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), nextMonth as CVarArg)

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]

            return itemRequest
        case .year:
            let dateComponents = calendar.dateComponents([.year], from: Date.now)

            let thisYear = calendar.date(from: dateComponents)!
            let nextYear = calendar.date(byAdding: .year, value: 1, to: thisYear)!

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisYear as CVarArg)
            let endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), nextYear as CVarArg)

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]

            return itemRequest
        }
    }

    func fetchRequestForExport() -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        itemRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return itemRequest
    }

    func fetchRequestForCategoriesMigration(income: Bool? = nil) -> NSFetchRequest<Category> {
        let itemRequest: NSFetchRequest<Category> = Category.fetchRequest()
        itemRequest.sortDescriptors = [NSSortDescriptor(key: "dateCreated", ascending: true)]

        if let unwrappedIncome = income {
            itemRequest.predicate = NSPredicate(format: "income = %d", unwrappedIncome)
            return itemRequest
        } else {
            return itemRequest
        }
    }

    func fetchRequestForCategories(income: Bool) -> NSFetchRequest<Category> {
        let itemRequest: NSFetchRequest<Category> = Category.fetchRequest()
        itemRequest.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        itemRequest.predicate = NSPredicate(format: "income = %d", income)
        return itemRequest
    }

    func getAllCategories(income: Bool) -> [Category] {
        let request: NSFetchRequest<Category> = Category.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
        request.predicate = NSPredicate(format: "income = %d", income)

        return results(for: request)
    }

    func getSuggestedNotes(searchQuery: String, category: Category?, income: Bool) -> [Transaction] {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        itemRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Transaction.date, ascending: false)]

        let beginPredicate = NSPredicate(format: "%K BEGINSWITH[cd] %@", #keyPath(Transaction.note), searchQuery)
        let containPredicate = NSPredicate(format: "%K CONTAINS[cd] %@", #keyPath(Transaction.note), searchQuery)
        let compound = NSCompoundPredicate(orPredicateWithSubpredicates: [beginPredicate, containPredicate])

        let incomePredicate = NSPredicate(format: "income = %d", income)

        if let unwrappedCategory = category {
            let categoryPredicate = NSPredicate(format: "%K == %@", #keyPath(Transaction.category), unwrappedCategory)

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [compound, categoryPredicate, incomePredicate])

            itemRequest.predicate = andPredicate
        } else {
            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [compound, incomePredicate])
            itemRequest.predicate = andPredicate
        }

        let transactions = results(for: itemRequest)

        var seen = [Transaction]()
        let filtered = transactions.filter { entity -> Bool in
            if seen.contains(where: { $0.wrappedNote == entity.wrappedNote }) {
                return false
            } else {
                seen.append(entity)
                return true
            }
        }

        return filtered
//
//        let notes = transactions.map { $0.wrappedNote }
//
//        return Array(Set(notes))
    }

    @available(iOS 16, *)
    func findCategory(withId id: UUID) throws -> Category {
        let request: NSFetchRequest<Category> = Category.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id as CVarArg)

        do {
            guard let foundCategory = try container.viewContext.fetch(request).first else {
                throw CustomError.notFound
            }
            return foundCategory
        } catch {
            throw CustomError.notFound
        }
    }

    func getAllBudgets() -> [Budget] {
        let request: NSFetchRequest<Budget> = Budget.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "dateCreated", ascending: true)]
        return results(for: request)
    }

    @available(iOS 16, *)
    func findBudget(withId id: UUID) throws -> Budget {
        let request: NSFetchRequest<Budget> = Budget.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id = %@", id as CVarArg)

        do {
            guard let foundBudget = try container.viewContext.fetch(request).first else {
                throw CustomError.notFound
            }
            return foundBudget
        } catch {
            throw CustomError.notFound
        }
    }

    func categoryCheck(name: String, emoji: String, income: Bool) -> (error: CategoryError, order: Int64) {
        let existing = results(for: fetchRequestForCategories(income: income))

        return categoryCheck(name: name, emoji: emoji, among: existing)
    }

    func categoryCheckEdit(name: String, emoji: String, toEdit: Category) -> (error: CategoryError, order: Int64) {
        var existing = results(for: fetchRequestForCategories(income: toEdit.income))

        if let position = existing.firstIndex(of: toEdit) {
            existing.remove(at: position)
        }

        return categoryCheck(name: name, emoji: emoji, among: existing)
    }

    // Two categories may share an emoji. Names are compared trimmed and without case,
    // so "Food" and " food" count as the same category.
    private func categoryCheck(name: String, emoji: String, among existing: [Category]) -> (error: CategoryError, order: Int64) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty && emoji.isEmpty {
            return (CategoryError.incomplete, 0)
        } else if trimmedName.isEmpty {
            return (CategoryError.missingName, 0)
        } else if emoji.isEmpty {
            return (CategoryError.missingEmoji, 0)
        }

        let key = trimmedName.lowercased()
        let taken = existing.contains { category in
            category.wrappedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }

        if taken {
            return (CategoryError.duplicateName, 0)
        }

        return (CategoryError.none, (existing.last?.order ?? 0) + 1)
    }

    func fetchRequestForBudgets() -> NSFetchRequest<Budget> {
        let itemRequest: NSFetchRequest<Budget> = Budget.fetchRequest()

        return itemRequest
    }

    func fetchRequestForMainBudget() -> NSFetchRequest<MainBudget> {
        let itemRequest: NSFetchRequest<MainBudget> = MainBudget.fetchRequest()

        return itemRequest
    }

    func fetchRequestForLogView(type: Int, optionalIncome: Bool?, categoryFilters: [Category] = []) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        var calendar = Calendar(identifier: .gregorian)

        calendar.firstWeekday = UserDefaults.appGroup.storedFirstWeekday
        calendar.minimumDaysInFirstWeek = 4

        // Whole of today counts: a row dated later today must not drop out of the totals.
        let dateCapPredicate = LogCutoff.currentPredicate()

        // all time
        if type == 5 {
            let andPredicate: NSCompoundPredicate
            let superPredicate: NSCompoundPredicate

            var categoryPredicates = [NSPredicate]()

            for category in categoryFilters {
                categoryPredicates.append(NSPredicate(format: "%K == %@", #keyPath(Transaction.category), category))
            }

            let categoryCompoundPredicate = NSCompoundPredicate(type: .or, subpredicates: categoryPredicates)

            if let income = optionalIncome {
                let incomePredicate = NSPredicate(format: "income = %d", income)

                andPredicate = NSCompoundPredicate(type: .and, subpredicates: [incomePredicate, dateCapPredicate])

                superPredicate = NSCompoundPredicate(type: .and, subpredicates: [andPredicate, categoryCompoundPredicate])
            } else {
                andPredicate = NSCompoundPredicate(type: .and, subpredicates: [dateCapPredicate])

                superPredicate = NSCompoundPredicate(type: .and, subpredicates: [andPredicate, categoryCompoundPredicate])
            }

            if categoryFilters.isEmpty {
                itemRequest.predicate = andPredicate
            } else {
                itemRequest.predicate = superPredicate
            }

            return itemRequest
        } else {
            let startPredicate: NSPredicate

            if type == 1 {
                let today = calendar.startOfDay(for: Date.now)
                startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), today as CVarArg)
            } else if type == 2 {
                let dateComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: Date.now)
                let thisWeek = calendar.date(from: dateComponents)!
                startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisWeek as CVarArg)
            } else if type == 3 {
                let startOfMonth = UserDefaults.appGroup.integer(forKey: "firstDayOfMonth")

                let thisMonth = getStartOfMonth(startDay: startOfMonth)
                startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisMonth as CVarArg)
            } else {
                let dateComponents = calendar.dateComponents([.year], from: Date.now)
                let thisYear = calendar.date(from: dateComponents)!
                startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisYear as CVarArg)
            }

            let andPredicate: NSCompoundPredicate
            let superPredicate: NSCompoundPredicate

            var categoryPredicates = [NSPredicate]()

            for category in categoryFilters {
                categoryPredicates.append(NSPredicate(format: "%K == %@", #keyPath(Transaction.category), category))
            }

            let categoryCompoundPredicate = NSCompoundPredicate(type: .or, subpredicates: categoryPredicates)

            if let income = optionalIncome {
                let incomePredicate = NSPredicate(format: "income = %d", income)

                andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, incomePredicate, dateCapPredicate])

                superPredicate = NSCompoundPredicate(type: .and, subpredicates: [andPredicate, categoryCompoundPredicate])
            } else {
                andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, dateCapPredicate])

                superPredicate = NSCompoundPredicate(type: .and, subpredicates: [andPredicate, categoryCompoundPredicate])
            }

            if categoryFilters.isEmpty {
                itemRequest.predicate = andPredicate
            } else {
                itemRequest.predicate = superPredicate
            }

            return itemRequest
        }

    }

    func getShortcutInsights(type: Int, timeframe: Int, optionalIncome: Bool?, categories: [Category]) -> Double {
        let fetchRequest = fetchRequestForLogView(type: timeframe, optionalIncome: optionalIncome, categoryFilters: categories)
        let allTransactions = results(for: fetchRequest)

        if type == 1 {
            var total = 0.0

            allTransactions.forEach { transaction in
                if transaction.income {
                    total += transaction.amount
                } else {
                    total -= transaction.amount
                }
            }

            return total
        } else {
            var total = 0.0

            allTransactions.forEach { transaction in
                total += transaction.amount
            }

            return total
        }
    }

    func getLogViewTotalSpent(type: Int) -> Double {
        let fetchRequest = fetchRequestForLogView(type: type, optionalIncome: false)
        let allTransactions = results(for: fetchRequest)

        var total = 0.0

        allTransactions.forEach { transaction in
            total += transaction.amount
        }

        return total
    }

    func getLogViewTotalIncome(type: Int) -> Double {
        let fetchRequest = fetchRequestForLogView(type: type, optionalIncome: true)
        let allTransactions = results(for: fetchRequest)

        var total = 0.0

        allTransactions.forEach { transaction in
            total += transaction.amount
        }

        return total
    }

    func getLogViewTotalNet(type: Int) -> (value: Double, positive: Bool) {
        let fetchRequest = fetchRequestForLogView(type: type, optionalIncome: nil)
        let allTransactions = results(for: fetchRequest)

        var total = 0.0

        allTransactions.forEach { transaction in
            if transaction.income {
                total += transaction.amount
            } else {
                total -= transaction.amount
            }
        }

        if total >= 0 {
            return (total, true)
        } else {
            return (abs(total), false)
        }
    }

    func getLineGraphDataNet(type: Int) -> [LineGraphDataPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date.now)

        let fetchRequest = fetchRequestForLineGraph(optionalIncome: nil)
        let transactions = results(for: fetchRequest)

        var holdingDataPoints = [LineGraphDataPoint]()
        var totalForDay = 0.0

        if type < 3 {
            let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: today)!
            var changingDate = Calendar.current.date(byAdding: .second, value: 86399, to: lastWeek)!

            for transaction in transactions {
                if transaction.wrappedDate < changingDate {
                    if transaction.income {
                        totalForDay += transaction.amount
                    } else {
                        totalForDay -= transaction.amount
                    }
                } else {
                    let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                    holdingDataPoints.append(newData)
                    changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!

                    while transaction.wrappedDate > changingDate {
                        let anotherNewData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                        holdingDataPoints.append(anotherNewData)
                        changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                    }

                    if transaction.income {
                        totalForDay += transaction.amount
                    } else {
                        totalForDay -= transaction.amount
                    }
                }
            }

            let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
            holdingDataPoints.append(newData)

            if changingDate < today {
                changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!

                while changingDate < today {
                    let anotherNewData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                    holdingDataPoints.append(anotherNewData)
                    changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                }

                let finalDate = LineGraphDataPoint(date: today, amount: totalForDay)
                holdingDataPoints.append(finalDate)
            }
        } else if type == 3 {
            let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: today)!
            var changingDate = Calendar.current.date(byAdding: .second, value: 86399, to: lastMonth)!

            for transaction in transactions {
                if transaction.wrappedDate < changingDate {
                    if transaction.income {
                        totalForDay += transaction.amount
                    } else {
                        totalForDay -= transaction.amount
                    }
                } else {
                    let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                    holdingDataPoints.append(newData)
                    changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!

                    while transaction.wrappedDate > changingDate {
                        let anotherNewData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                        holdingDataPoints.append(anotherNewData)
                        changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                    }

                    if transaction.income {
                        totalForDay += transaction.amount
                    } else {
                        totalForDay -= transaction.amount
                    }
                }
            }

            let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
            holdingDataPoints.append(newData)

            if changingDate < today {
                changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!

                while changingDate < today {
                    let anotherNewData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                    holdingDataPoints.append(anotherNewData)
                    changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                }

                let finalDate = LineGraphDataPoint(date: today, amount: totalForDay)
                holdingDataPoints.append(finalDate)
            }
        } else if type == 4 {
            let dateComponents = calendar.dateComponents([.month, .year], from: Date.now)
            let thisMonth = calendar.date(from: dateComponents)!
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: thisMonth)!
            var changingDate = calendar.date(byAdding: .year, value: -1, to: nextMonth)!

            for transaction in transactions {
                if transaction.wrappedDate < changingDate {
                    if transaction.income {
                        totalForDay += transaction.amount
                    } else {
                        totalForDay -= transaction.amount
                    }
                } else {
                    let dataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
                    let newData = LineGraphDataPoint(date: dataDate, amount: totalForDay)
                    holdingDataPoints.append(newData)
                    changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!

                    while transaction.wrappedDate > changingDate {
                        let newDataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
                        let anotherNewData = LineGraphDataPoint(date: newDataDate, amount: totalForDay)
                        holdingDataPoints.append(anotherNewData)
                        changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!
                    }

                    if transaction.income {
                        totalForDay += transaction.amount
                    } else {
                        totalForDay -= transaction.amount
                    }
                }
            }

            let dataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
            let newData = LineGraphDataPoint(date: dataDate, amount: totalForDay)
            holdingDataPoints.append(newData)

            if changingDate < nextMonth {
                changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!

                while changingDate < nextMonth {
                    let anotherDataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
                    let anotherNewData = LineGraphDataPoint(date: anotherDataDate, amount: totalForDay)
                    holdingDataPoints.append(anotherNewData)
                    changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!
                }

                let finalDate = LineGraphDataPoint(date: today, amount: totalForDay)
                holdingDataPoints.append(finalDate)
            }
        }

        return holdingDataPoints
    }

    func getLineGraphData(income: Bool, type: Int) -> [LineGraphDataPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date.now)

        let fetchRequest = fetchRequestForLineGraph(optionalIncome: income)
        let transactions = results(for: fetchRequest)

        var holdingDataPoints = [LineGraphDataPoint]()
        var totalForDay = 0.0

        if type < 3 {
            let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: today)!
            var changingDate = Calendar.current.date(byAdding: .second, value: 86399, to: lastWeek)!

            for transaction in transactions {
                if transaction.wrappedDate > lastWeek {
                    if transaction.wrappedDate < changingDate {
                        totalForDay += transaction.wrappedAmount
                    } else {
                        let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                        holdingDataPoints.append(newData)
                        changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                        totalForDay = 0

                        while transaction.wrappedDate > changingDate {
                            let anotherNewData = LineGraphDataPoint(date: changingDate, amount: 0)
                            holdingDataPoints.append(anotherNewData)
                            changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                        }

                        totalForDay += transaction.wrappedAmount
                    }
                }
            }

            let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
            holdingDataPoints.append(newData)
            totalForDay = 0

            if changingDate < today {
                changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!

                while changingDate < today {
                    let anotherNewData = LineGraphDataPoint(date: changingDate, amount: 0)
                    holdingDataPoints.append(anotherNewData)
                    changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                }

                let finalDate = LineGraphDataPoint(date: today, amount: totalForDay)
                holdingDataPoints.append(finalDate)
            }
        } else if type == 3 {
            let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: today)!
            var changingDate = Calendar.current.date(byAdding: .second, value: 86399, to: lastMonth)!

            for transaction in transactions {
                if transaction.wrappedDate > lastMonth {
                    if transaction.wrappedDate < changingDate {
                        totalForDay += transaction.wrappedAmount
                    } else {
                        let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
                        holdingDataPoints.append(newData)
                        changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                        totalForDay = 0

                        while transaction.wrappedDate > changingDate {
                            let anotherNewData = LineGraphDataPoint(date: changingDate, amount: 0)
                            holdingDataPoints.append(anotherNewData)
                            changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                        }

                        totalForDay += transaction.wrappedAmount
                    }
                }
            }

            let newData = LineGraphDataPoint(date: changingDate, amount: totalForDay)
            holdingDataPoints.append(newData)

            if changingDate < today {
                changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!

                while changingDate < today {
                    let anotherNewData = LineGraphDataPoint(date: changingDate, amount: 0)
                    holdingDataPoints.append(anotherNewData)
                    changingDate = Calendar.current.date(byAdding: .day, value: 1, to: changingDate)!
                }

                let finalDate = LineGraphDataPoint(date: today, amount: 0)
                holdingDataPoints.append(finalDate)
            }
        } else if type == 4 {
            let dateComponents = calendar.dateComponents([.month, .year], from: Date.now)
            let thisMonth = calendar.date(from: dateComponents)!
            let thisMonthLastYear = calendar.date(byAdding: .year, value: -1, to: thisMonth)!
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: thisMonth)!
            var changingDate = calendar.date(byAdding: .year, value: -1, to: nextMonth)!

            for transaction in transactions {
                if transaction.wrappedDate > thisMonthLastYear {
                    if transaction.wrappedDate < changingDate {
                        totalForDay += transaction.wrappedAmount
                    } else {
                        let dataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
                        let newData = LineGraphDataPoint(date: dataDate, amount: totalForDay)
                        holdingDataPoints.append(newData)
                        changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!
                        totalForDay = 0

                        while transaction.wrappedDate > changingDate {
                            let newDataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
                            let anotherNewData = LineGraphDataPoint(date: newDataDate, amount: 0)
                            holdingDataPoints.append(anotherNewData)
                            changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!
                        }

                        totalForDay += transaction.wrappedAmount
                    }
                }
            }

            let dataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
            let newData = LineGraphDataPoint(date: dataDate, amount: totalForDay)
            holdingDataPoints.append(newData)

            if changingDate < nextMonth {
                changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!

                while changingDate < nextMonth {
                    let anotherDataDate = calendar.date(byAdding: .day, value: -1, to: changingDate)!
                    let anotherNewData = LineGraphDataPoint(date: anotherDataDate, amount: 0)
                    holdingDataPoints.append(anotherNewData)
                    changingDate = Calendar.current.date(byAdding: .month, value: 1, to: changingDate)!
                }

                let finalDate = LineGraphDataPoint(date: today, amount: 0)
                holdingDataPoints.append(finalDate)
            }
        }

        return holdingDataPoints
    }

    func getBudgetLeftover(budget: Budget? = nil, overallBudget: MainBudget? = nil) -> Double {
        let itemRequest: NSFetchRequest<Transaction>
        let budgetAmount: Double

        if let unwrappedOverallBudget = overallBudget {
            itemRequest = fetchRequestForMainBudgetTransactions(budget: unwrappedOverallBudget)
            budgetAmount = unwrappedOverallBudget.amount
        } else if let unwrappedBudget = budget {
            itemRequest = fetchRequestForBudgetTransactions(budget: unwrappedBudget)
            budgetAmount = unwrappedBudget.amount
        } else {
            itemRequest = Transaction.fetchRequest()
            budgetAmount = 0
        }

        let transactions = results(for: itemRequest)

        var totalSpent = 0.0

        transactions.forEach { transaction in
            totalSpent += transaction.wrappedAmount
        }

        return budgetAmount - totalSpent
    }

    func fetchRequestForMainBudgetTransactions(budget: MainBudget) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        // Rolled start: widgets read the budget without updateBudgetDates() having run.
        let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), budget.currentPeriodStart() as CVarArg)
        let endPredicate = LogCutoff.currentPredicate()
        let incomePredicate = NSPredicate(format: "income = %d", false)

        let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate, incomePredicate])

        itemRequest.predicate = andPredicate

        return itemRequest
    }

    func fetchRequestForBudgetTransactions(budget: Budget) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), budget.currentPeriodStart() as CVarArg)
        let endPredicate = LogCutoff.currentPredicate()
        let categoryPredicate: NSPredicate

        if let category = budget.category {
            categoryPredicate = NSPredicate(format: "%K == %@", #keyPath(Transaction.category), category)
        } else {
            categoryPredicate = NSPredicate(value: false)
        }
        let incomePredicate = NSPredicate(format: "income = %d", false)

        let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate, categoryPredicate, incomePredicate])

        itemRequest.predicate = andPredicate

        return itemRequest
    }

    func fetchRequestForLineGraph(optionalIncome: Bool?) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        itemRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Transaction.date, ascending: true)]

        if let income = optionalIncome {
            itemRequest.predicate = NSPredicate(format: "income = %d", income)
            return itemRequest
        } else {
            return itemRequest
        }
    }

    func fetchRequestForLogViewCategoryFilter(income: Bool) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        itemRequest.predicate = NSPredicate(format: "income = %d", income)
        return itemRequest
    }

    func getInsights(type: Int, date: Date, income: Bool) -> (amount: Double, maximum: Double, average: Double, numberOfDays: Int, dates: [Date], dateDictionary: [Date: Double]) {
        let currentItemRequest: NSFetchRequest<Transaction> = fetchRequestForInsights(type: type, date: date, income: income)
        let currentTransactions = results(for: currentItemRequest)

        var iterativeDate = date

        if type == 1 {
            // tracking dates
            var dates = [Date]()
            var nextDate = date

            // calendar initialization
            var calendar = Calendar(identifier: .gregorian)

            calendar.firstWeekday = UserDefaults.appGroup.storedFirstWeekday
            calendar.minimumDaysInFirstWeek = 4

            var dictionary = [Date: Double]()
            var totalForWeek = 0.0
            var maximum = 0.0
            var numberOfDays = 0
            var weekAverage = 0.0

            for _ in 1 ... 7 {
                nextDate = calendar.date(byAdding: .day, value: 1, to: iterativeDate)!

                let holding = currentTransactions.filter {
                    $0.wrappedDate >= iterativeDate && $0.wrappedDate < nextDate
                }

                var total = 0.0

                holding.forEach { transaction in
                    total += transaction.wrappedAmount
                }

                totalForWeek += total

                dictionary[iterativeDate] = total

                if total > maximum {
                    maximum = total
                }

                if total != 0 {
                    numberOfDays += 1
                }

                dates.append(iterativeDate)
                iterativeDate = nextDate
            }

            let dateComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: Date.now)

            let currentWeek = calendar.date(from: dateComponents)!

            if currentWeek == date {
//                let fromDate = Calendar.current.startOfDay(for: currentWeek)
//                let toDate = Calendar.current.startOfDay(for: Date.now)
                let numberOfDays = Calendar.current.dateComponents([.day], from: currentWeek, to: Date.now)

                weekAverage = totalForWeek / Double((numberOfDays.day! + 1))
            } else {
                weekAverage = totalForWeek / 7
            }

            return (totalForWeek, maximum, weekAverage, numberOfDays, dates, dictionary)
        } else if type == 2 {
            // tracking dates
            var dates = [Date]()
            var nextDate = date

            let calendar = Calendar(identifier: .gregorian)
            let range = calendar.range(of: .day, in: .month, for: iterativeDate)!

            var dictionary = [Date: Double]()
            var totalForMonth = 0.0
            var maximum = 0.0
            var numberOfDays = 0
            var monthAverage = 0.0

            for _ in 1 ... range.count {
                nextDate = calendar.date(byAdding: .day, value: 1, to: iterativeDate)!

                let holding = currentTransactions.filter {
                    $0.wrappedDate >= iterativeDate && $0.wrappedDate < nextDate
                }

                var total = 0.0

                holding.forEach { transaction in
                    total += transaction.wrappedAmount
                }

                totalForMonth += total

                dictionary[iterativeDate] = total

                if total > maximum {
                    maximum = total
                }

                if total != 0 {
                    numberOfDays += 1
                }

                dates.append(iterativeDate)
                iterativeDate = nextDate
            }

            let next = calendar.date(byAdding: .month, value: 1, to: date) ?? Date.now

            if next > Date.now {
                let numDays = Calendar.current.dateComponents([.day], from: date, to: Date.now)

                monthAverage = totalForMonth / Double((numDays.day! + 1))
            } else {
                monthAverage = totalForMonth / Double(range.count)
            }

            return (totalForMonth, maximum, monthAverage, numberOfDays, dates, dictionary)
        } else if type == 3 {
            // trackin dates
            var dates = [Date]()
            var nextDate = date

            let calendar = Calendar(identifier: .gregorian)

            var dictionary = [Date: Double]()
            var totalForYear = 0.0
            var maximum = 0.0
            var numberOfDays = 0
            var monthAverage = 0.0

            for _ in 1 ... 12 {
                nextDate = calendar.date(byAdding: .month, value: 1, to: iterativeDate)!

                let holding = currentTransactions.filter {
                    $0.wrappedDate >= iterativeDate && $0.wrappedDate < nextDate
                }

                var total = 0.0

                holding.forEach { transaction in
                    total += transaction.wrappedAmount
                }

                totalForYear += total

                dictionary[iterativeDate] = total

                if total > maximum {
                    maximum = total
                }

                if total != 0 {
                    numberOfDays += 1
                }

                dates.append(iterativeDate)
                iterativeDate = nextDate
            }

            let dateComponents = calendar.dateComponents([.year], from: Date.now)

            let currentYear = calendar.date(from: dateComponents)!

            if currentYear == date {
                let fromDate = Calendar.current.startOfDay(for: currentYear)
                let toDate = Calendar.current.startOfDay(for: Date.now)
                let numDays = Calendar.current.dateComponents([.month], from: fromDate, to: toDate)

                monthAverage = totalForYear / Double((numDays.month! + 1))
            } else {
                monthAverage = totalForYear / 12
            }

            return (totalForYear, maximum, monthAverage, numberOfDays, dates, dictionary)
        } else {
            return (0, 0, 0, 0, [Date](), [Date: Double]())
        }
    }

    func fetchRequestForInsights(type: Int, date: Date, income: Bool? = nil) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        var calendar = Calendar(identifier: .gregorian)

        calendar.firstWeekday = UserDefaults.appGroup.storedFirstWeekday
        calendar.minimumDaysInFirstWeek = 4

        let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), date as CVarArg)

        let endPredicate: NSPredicate

        if type == 1 {
            if calendar.isDate(date, equalTo: Date.now, toGranularity: .weekOfYear) {
                endPredicate = LogCutoff.currentPredicate()
            } else {
                let next = calendar.date(byAdding: .day, value: 7, to: date) ?? Date.now
                endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), next as CVarArg)
            }
        } else if type == 2 {
            let next = calendar.date(byAdding: .month, value: 1, to: date) ?? Date.now

//            let endOfPeriod = calendar.date(byAdding: .day, value: -1, to: next) ?? Date.now
//
            if next > Date.now {
                endPredicate = LogCutoff.currentPredicate()
            } else {
                endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), next as CVarArg)
            }
//
//            if calendar.isDate(date, equalTo: Date.now, toGranularity: .month) {
//                endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), Date.now as CVarArg)
//            } else {
//
//                endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), next as CVarArg)
//            }
        } else {
            if calendar.isDate(date, equalTo: Date.now, toGranularity: .year) {
                endPredicate = LogCutoff.currentPredicate()
            } else {
                let next = calendar.date(byAdding: .year, value: 1, to: date) ?? Date.now
                endPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), next as CVarArg)
            }
        }

        let andPredicate: NSCompoundPredicate

        if let unwrappedIncome = income {
            let incomePredicate = NSPredicate(format: "income = %d", unwrappedIncome)

            andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, incomePredicate, endPredicate])
        } else {
            andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])
        }

        itemRequest.predicate = andPredicate

        return itemRequest
    }

    func getInsightsSummary(type: Int, date: Date) -> (spent: Double, income: Double, net: Double, positive: Bool, average: Double) {
        let itemRequest: NSFetchRequest<Transaction> = fetchRequestForInsights(type: type, date: date)
        let currentTransactions = results(for: itemRequest)

        var holdingSpent = 0.0
        var holdingIncome = 0.0

        currentTransactions.forEach { transaction in
            if transaction.income {
                holdingIncome += transaction.amount
            } else {
                holdingSpent += transaction.amount
            }
        }

        let net = holdingIncome - holdingSpent
        let absoluteNet: Double
        let positive: Bool

        if net < 0 {
            absoluteNet = abs(net)
            positive = false
        } else {
            absoluteNet = net
            positive = true
        }

        let calendar = Calendar.current

        if type == 1 {
            if calendar.isDate(date, equalTo: Date.now, toGranularity: .weekOfYear) {
                let numberOfDays = Calendar.current.dateComponents([.day], from: date, to: Date.now)

                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / Double(numberOfDays.day! + 1))
            } else {
                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / 7)
            }
        } else if type == 2 {
            let next = calendar.date(byAdding: .month, value: 1, to: date) ?? Date.now

            if next > Date.now {
                let numDays = Calendar.current.dateComponents([.day], from: date, to: Date.now)

                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / Double(numDays.day! + 1))
            } else {
                let numDays = Calendar.current.dateComponents([.day], from: date, to: next)

                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / Double(numDays.day! + 1))
            }
//            if calendar.isDate(date, equalTo: Date.now, toGranularity: .month) {
//                let numDays = Calendar.current.dateComponents([.day], from: date, to: Date.now)
//
//                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / Double(numDays.day! + 1))
//            } else {
//
//                let range = calendar.range(of: .day, in: .month, for: date)!
//                let numDays = range.count
//
//                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / Double(numDays))
//            }
        } else {
            if calendar.isDate(date, equalTo: Date.now, toGranularity: .year) {
                let numDays = Calendar.current.dateComponents([.month], from: date, to: Date.now)

                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / Double(numDays.month! + 1))
            } else {
                return (holdingSpent, holdingIncome, absoluteNet, positive, abs(net) / 12)
            }
        }
    }

    func fetchRequestForWidgetInsights(type: InsightsTimePeriod, income: Bool) -> (fetchRequest: NSFetchRequest<Transaction>, date: Date) {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        var calendar = Calendar(identifier: .gregorian)

        calendar.firstWeekday = UserDefaults.appGroup.storedFirstWeekday
        calendar.minimumDaysInFirstWeek = 4

        let endPredicate = LogCutoff.currentPredicate()

        let incomePredicate = NSPredicate(format: "income = %d", income)

        let startDate: Date
        let startPredicate: NSPredicate

        switch type {
        case .unknown:
            startDate = Date.now
            startPredicate = NSPredicate(format: "%K < %@", #keyPath(Transaction.date), Date.now as CVarArg)
        case .week:
            let dateComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: Date.now)

            startDate = calendar.date(from: dateComponents)!

            startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), startDate as CVarArg)
        case .month:
            let startOfMonth = UserDefaults.appGroup.integer(forKey: "firstDayOfMonth")

            startDate = getStartOfMonth(startDay: startOfMonth)

            startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), startDate as CVarArg)
        case .year:
            let dateComponents = calendar.dateComponents([.year], from: Date.now)

            startDate = calendar.date(from: dateComponents)!

            startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), startDate as CVarArg)
        }

        let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate, incomePredicate])

        itemRequest.predicate = andPredicate
        itemRequest.sortDescriptors = [
            NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
        ]

        return (itemRequest, startDate)
    }

    func fetchRequestForRecentTransactionsWithCount(type: TimePeriod, count: Int) -> NSFetchRequest<Transaction> {
        let itemRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()

        var calendar = Calendar(identifier: .gregorian)

        calendar.firstWeekday = UserDefaults.appGroup.storedFirstWeekday
        calendar.minimumDaysInFirstWeek = 4

        switch type {
        case .unknown:
            return itemRequest
        case .day:
            let today = calendar.startOfDay(for: Date.now)

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), today as CVarArg)
            let endPredicate = LogCutoff.currentPredicate()

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]
            itemRequest.fetchLimit = count

            return itemRequest
        case .week:
            let dateComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: Date.now)

            let thisWeek = calendar.date(from: dateComponents)!

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisWeek as CVarArg)
            let endPredicate = LogCutoff.currentPredicate()

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]
            itemRequest.fetchLimit = count

            return itemRequest
        case .month:
            let dateComponents = calendar.dateComponents([.month, .year], from: Date.now)

            let thisMonth = calendar.date(from: dateComponents)!

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisMonth as CVarArg)
            let endPredicate = LogCutoff.currentPredicate()

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]
            itemRequest.fetchLimit = count

            return itemRequest
        case .year:
            let dateComponents = calendar.dateComponents([.year], from: Date.now)

            let thisYear = calendar.date(from: dateComponents)!

            let startPredicate = NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), thisYear as CVarArg)
            let endPredicate = LogCutoff.currentPredicate()

            let andPredicate = NSCompoundPredicate(type: .and, subpredicates: [startPredicate, endPredicate])

            itemRequest.predicate = andPredicate
            itemRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Transaction.date, ascending: false)
            ]
            itemRequest.fetchLimit = count

            return itemRequest
        }
    }

    func fetchRequestForMainBudgetWidget() -> (found: Bool, totalSpent: Double, budgetAmount: Double, percentage: Double, type: Int, startDate: Date) {
        let holding = results(for: fetchRequestForMainBudget())

        if let budget = holding.first {
            let itemRequest = fetchRequestForMainBudgetTransactions(budget: budget)
//
            let transactions = results(for: itemRequest)

            var holdingTotal = 0.0
            transactions.forEach { transaction in
                holdingTotal += transaction.wrappedAmount
            }

            let percentageOfDays: Double

            let calendar = Calendar.current

            // Same rolled period as fetchRequestForMainBudgetTransactions.
            let periodStart = budget.currentPeriodStart()
            let periodEnd = BudgetPeriod.end(of: periodStart, type: budget.type) ?? periodStart

            if budget.type == 1 {
                let components = calendar.dateComponents([.minute], from: periodStart, to: Date.now)
                percentageOfDays = Double(components.minute ?? 0) / 1440
            } else {
                let components1 = calendar.dateComponents([.day], from: periodStart, to: periodEnd)
                let numberOfDays = components1.day ?? 0

                let components2 = calendar.dateComponents([.day], from: periodStart, to: Date.now)
                let numberOfDaysPast = components2.day ?? 0

                percentageOfDays = numberOfDays > 0 ? Double(numberOfDaysPast) / Double(numberOfDays) : 0
            }

            return (true, holdingTotal, budget.amount, percentageOfDays, Int(budget.type), periodStart)

        } else {
            return (false, 0, 0, 0, 0, Date.now)
        }
    }

    func results<T: NSManagedObject>(for fetchRequest: NSFetchRequest<T>) -> [T] {
        do {
            return try container.viewContext.fetch(fetchRequest)
        } catch {
            DiagnosticsLog.shared.log("fetch", "\(fetchRequest.entityName ?? "?") FAILED \(Self.describe(error as NSError))")
            return []
        }
    }
}

public extension NSManagedObjectContext {
    func executeAndMergeChanges(using batchDeleteRequest: NSBatchDeleteRequest) throws {
        batchDeleteRequest.resultType = .resultTypeObjectIDs
        let result = try execute(batchDeleteRequest) as? NSBatchDeleteResult
        let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: result?.result as? [NSManagedObjectID] ?? []]
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self])
    }
}

struct LineGraphDataPoint: Equatable {
    let date: Date
    let amount: Double

    var dateString: String {
        let dateFormatter = DateFormatter()

        dateFormatter.dateFormat = "d MMM"

        return dateFormatter.string(from: date)
    }

    var monthString: String {
        let dateFormatter = DateFormatter()

        dateFormatter.dateFormat = "MMM yy"

        return dateFormatter.string(from: date)
    }

    var amountString: String {
        if abs(amount) < 1000 {
            return String(format: "%.2f", amount)
        } else {
            return String(format: "%.0f", amount)
        }
    }
}

func getStartOfMonth(startDay: Int) -> Date {
    let calendar = Calendar.current

    guard startDay > 0 && startDay <= calendar.maximumRange(of: .day)!.upperBound else {
        let dateComponents = calendar.dateComponents([.month, .year], from: Date.now)
        return calendar.date(from: dateComponents) ?? Date.now
    }

    let today = calendar.startOfDay(for: Date.now)
    let currentDay = calendar.component(.day, from: today)

    var startComponents = DateComponents()
    startComponents.month = currentDay >= startDay ? 0 : -1

    startComponents.day = startDay - currentDay

    return calendar.date(byAdding: startComponents, to: today) ?? Date.now
}

func calculateStartOfMonthPeriod(earliestDate: Date, startOfMonthDay: Int) -> Date {
    var components = Calendar.current.dateComponents([.year, .month, .day], from: earliestDate)
    components.day = startOfMonthDay

    let startOfMonth = Calendar.current.date(from: components) ?? Date.now
    return (earliestDate < startOfMonth) ? (Calendar.current.date(byAdding: .month, value: -1, to: startOfMonth) ?? Date.now) : startOfMonth
}
