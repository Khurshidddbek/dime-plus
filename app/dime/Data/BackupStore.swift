//
//  BackupStore.swift
//  dime
//
//  App target only. Lossless JSON snapshots of the whole store in Documents/Backups.
//  Reads and writes happen on background contexts; the synchronous calls block the
//  caller, the `...Async` variants run on a utility queue and answer on the main queue.
//

import CoreData
import Foundation

struct BackupDocument: Codable {
    struct Meta: Codable {
        /// Dates in this file are seconds since 2001-01-01 UTC (lossless). This is the readable copy.
        var createdAtText: String
        var createdAt: Date
        var appVersion: String
        var tag: String
        var timeZone: String
        var currency: String?
        var transactionCount: Int
        /// Sum of all amounts, a cheap check that a file was read back completely.
        var amountChecksum: Double
    }

    var schemaVersion: Int
    var meta: Meta
    var categories: [CategoryRecord]
    var transactions: [TransactionSnapshot]
    var budgets: [BudgetRecord]
    var mainBudgets: [MainBudgetRecord]
    var templates: [TemplateRecord]
}

struct BackupInfo: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    /// "auto", "manual", "pre-restore" or whatever the caller passed.
    let tag: String
    let size: Int64

    var id: String { url.lastPathComponent }
    var isAutomatic: Bool { tag == BackupStore.automaticTag }
}

struct RestoreResult: Equatable {
    var categories = 0
    var transactions = 0
    var budgets = 0
    var mainBudgets = 0
    var templates = 0
    /// Rows of the file that were left out because they already exist (merge mode).
    var skipped = 0
    /// The backup taken right before a replace-all restore.
    var safetyBackup: URL?
}

enum BackupError: Error, LocalizedError {
    case unreadable
    case unsupportedVersion(Int)
    case damaged

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return NSLocalizedString("This file is not a Dime backup.", comment: "")
        case .unsupportedVersion:
            return NSLocalizedString("This backup was made by a newer version of the app.", comment: "")
        case .damaged:
            return NSLocalizedString("This backup is incomplete and cannot be restored.", comment: "")
        }
    }
}

final class BackupStore {
    enum RestoreMode {
        /// Takes a safety backup, then replaces everything with the file's content.
        case replaceAll
        /// Inserts only the rows whose ids are not in the store.
        case mergeMissing
    }

    static let shared = BackupStore()

    static let automaticTag = "auto"
    static let manualTag = "manual"
    static let safetyTag = "pre-restore"
    static let schemaVersion = 1
    static let keepCount = 14

    /// Posted on the main queue after a backup was written, deleted or restored.
    static let didChangeNotification = Notification.Name("dime.backup.didChange")

    private let dataController = DataController.shared
    private let queue = DispatchQueue(label: "uz.khurshidbek.dime.backup", qos: .utility)
    private let lastAutomaticKey = "lastAutomaticBackup"

    private init() {}

    // MARK: locations

    /// Documents/Backups, created on demand.
    var directory: URL {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let url = documents.appendingPathComponent("Backups", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The backup file itself; it lives in Documents and can be handed to a share sheet.
    func shareURL(for backup: BackupInfo) -> URL {
        backup.url
    }

    var lastAutomaticBackupDate: Date? {
        UserDefaults.standard.object(forKey: lastAutomaticKey) as? Date
    }

    /// Newest first.
    func list() -> [BackupInfo] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]

        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }

        let backups: [BackupInfo] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json" else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let parsed = Self.parse(fileName: url.deletingPathExtension().lastPathComponent)
            let created = parsed?.date ?? values?.contentModificationDate ?? Date.distantPast

            return BackupInfo(url: url, createdAt: created, tag: parsed?.tag ?? "file", size: Int64(values?.fileSize ?? 0))
        }

        return backups.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ backup: BackupInfo) {
        try? FileManager.default.removeItem(at: backup.url)
        DiagnosticsLog.shared.log("backup", "deleted \(backup.url.lastPathComponent)")
        notifyChange()
    }

    // MARK: writing

    /// Writes a snapshot now and returns it. Blocks the caller.
    @discardableResult
    func backupNow(tag: String = BackupStore.manualTag) throws -> BackupInfo {
        do {
            let document = try makeDocument(tag: tag)
            let info = try write(document)

            if tag == Self.automaticTag {
                UserDefaults.standard.set(document.meta.createdAt, forKey: lastAutomaticKey)
            }

            prune()
            DiagnosticsLog.shared.log("backup", "\(tag) ok \(info.url.lastPathComponent) transactions=\(document.transactions.count) bytes=\(info.size)")
            notifyChange()

            return info
        } catch {
            DiagnosticsLog.shared.log("backup", "\(tag) FAILED \(DataController.describe(error as NSError))")
            throw error
        }
    }

    func backupNowAsync(tag: String = BackupStore.manualTag, completion: @escaping (Result<BackupInfo, Error>) -> Void) {
        queue.async {
            let result = Result { try self.backupNow(tag: tag) }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// True when no automatic backup was written today.
    var isAutomaticBackupDue: Bool {
        guard let last = lastAutomaticBackupDate else {
            return true
        }

        return !Calendar.current.isDateInToday(last)
    }

    /// Automatic daily backup: at most one per calendar day, skipped while the store is
    /// empty (an empty snapshot must not push good ones out of the last 14).
    /// Returns at once; `completion` (main queue) gets true when a file was written.
    func backupIfDue(completion: ((Bool) -> Void)? = nil) {
        guard dataController.isStoreLoaded, isAutomaticBackupDue else {
            completion?(false)
            return
        }

        queue.async {
            var written = false

            // Checked again on the queue: launch and background can both ask.
            if self.isAutomaticBackupDue, self.storeHasData() {
                written = (try? self.backupNow(tag: Self.automaticTag)) != nil
            }

            if let completion = completion {
                DispatchQueue.main.async {
                    completion(written)
                }
            }
        }
    }

    // MARK: reading and restoring

    /// Reads and validates a backup file (also one picked from Files).
    func readDocument(at url: URL) throws -> BackupDocument {
        let scoped = url.startAccessingSecurityScopedResource()

        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url) else {
            throw BackupError.unreadable
        }

        guard let document = try? JSONDecoder().decode(BackupDocument.self, from: data) else {
            throw BackupError.unreadable
        }

        guard document.schemaVersion <= Self.schemaVersion else {
            throw BackupError.unsupportedVersion(document.schemaVersion)
        }

        guard document.transactions.count == document.meta.transactionCount else {
            throw BackupError.damaged
        }

        return document
    }

    /// How many transactions of the file are not in the store (for a restore preview).
    func missingTransactionCount(in document: BackupDocument) -> Int {
        guard dataController.isStoreLoaded else {
            return document.transactions.count
        }

        let context = dataController.makeBackgroundContext(name: "backup preview")

        return context.performAndWait { () -> Int in
            let existing = Self.existingIDs(entity: "Transaction", in: context)
            return document.transactions.filter { !existing.contains($0.id) }.count
        }
    }

    /// Restores a backup file. Blocks the caller. Either everything is saved or nothing.
    /// `.replaceAll` first writes a "pre-restore" backup and aborts when that fails.
    @discardableResult
    func restore(from url: URL, mode: RestoreMode) throws -> RestoreResult {
        let modeName = mode == .replaceAll ? "replace" : "merge"

        do {
            let document = try readDocument(at: url)
            var safetyURL: URL?

            if mode == .replaceAll, storeHasData() {
                safetyURL = try backupNow(tag: Self.safetyTag).url
            }

            var result: RestoreResult = try dataController.performBackgroundWrite("restore backup (\(modeName))") { (context: NSManagedObjectContext) -> RestoreResult in
                switch mode {
                case .replaceAll:
                    return try Self.replaceAll(with: document, in: context)
                case .mergeMissing:
                    return try Self.mergeMissing(from: document, in: context)
                }
            }

            result.safetyBackup = safetyURL

            if mode == .replaceAll {
                // The rows this device saved before the restore are gone on purpose.
                DispatchQueue.main.async {
                    PersistenceStatus.shared.forgetRecentSaves()
                }
            }

            DiagnosticsLog.shared.log("backup", "restore \(modeName) ok from \(url.lastPathComponent): categories=\(result.categories) transactions=\(result.transactions) budgets=\(result.budgets) templates=\(result.templates) skipped=\(result.skipped)")
            notifyChange()

            return result
        } catch {
            DiagnosticsLog.shared.log("backup", "restore \(modeName) FAILED \(DataController.describe(error as NSError))")
            throw error
        }
    }

    func restoreAsync(from url: URL, mode: RestoreMode, completion: @escaping (Result<RestoreResult, Error>) -> Void) {
        queue.async {
            let result = Result { try self.restore(from: url, mode: mode) }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: private, snapshot

    private func storeHasData() -> Bool {
        guard dataController.isStoreLoaded else {
            return false
        }

        let context = dataController.makeBackgroundContext(name: "backup check")

        return context.performAndWait { () -> Bool in
            for entity in ["Transaction", "Category"] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)

                if ((try? context.count(for: request)) ?? 0) > 0 {
                    return true
                }
            }

            return false
        }
    }

    private func makeDocument(tag: String) throws -> BackupDocument {
        // Categories without an id cannot be referenced from the file. Give them one first.
        try dataController.performBackgroundWrite("backup ids") { (context: NSManagedObjectContext) -> Void in
            let request: NSFetchRequest<Category> = Category.fetchRequest()
            request.predicate = NSPredicate(format: "id == nil")

            for category in try context.fetch(request) {
                category.id = UUID()
            }
        }

        let context = dataController.makeBackgroundContext(name: "backup")
        let now = Date()

        return try context.performAndWait { () throws -> BackupDocument in
            let categoryRequest: NSFetchRequest<Category> = Category.fetchRequest()
            categoryRequest.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
            let categories = try context.fetch(categoryRequest).compactMap { CategoryRecord($0) }

            let transactionRequest: NSFetchRequest<Transaction> = Transaction.fetchRequest()
            transactionRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            transactionRequest.relationshipKeyPathsForPrefetching = ["category"]
            let transactions = try context.fetch(transactionRequest).map { TransactionSnapshot($0) }

            let budgetRequest: NSFetchRequest<Budget> = Budget.fetchRequest()
            let budgets = try context.fetch(budgetRequest).map { BudgetRecord($0) }

            let mainBudgetRequest: NSFetchRequest<MainBudget> = MainBudget.fetchRequest()
            let mainBudgets = try context.fetch(mainBudgetRequest).map { MainBudgetRecord($0) }

            let templateRequest: NSFetchRequest<TemplateTransaction> = TemplateTransaction.fetchRequest()
            let templates = try context.fetch(templateRequest).map { TemplateRecord($0) }

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

            let meta = BackupDocument.Meta(
                createdAtText: ISO8601DateFormatter().string(from: now),
                createdAt: now,
                appVersion: "\(version) (\(build))",
                tag: tag,
                timeZone: TimeZone.current.identifier,
                currency: UserDefaults.appGroup.string(forKey: "currency"),
                transactionCount: transactions.count,
                amountChecksum: transactions.reduce(0) { $0 + $1.amount }
            )

            return BackupDocument(
                schemaVersion: Self.schemaVersion,
                meta: meta,
                categories: categories,
                transactions: transactions,
                budgets: budgets,
                mainBudgets: mainBudgets,
                templates: templates
            )
        }
    }

    private func write(_ document: BackupDocument) throws -> BackupInfo {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)

        let baseName = "dime-\(Self.fileStamp(document.meta.createdAt))-\(document.meta.tag)"
        var url = directory.appendingPathComponent("\(baseName).json")
        var attempt = 2

        // Two backups in the same second must not overwrite each other.
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName)-\(attempt).json")
            attempt += 1
        }

        try data.write(to: url, options: .atomic)

        return BackupInfo(url: url, createdAt: document.meta.createdAt, tag: document.meta.tag, size: Int64(data.count))
    }

    // Keeps the newest 14 automatic backups and, separately, the newest 14 of the others.
    private func prune() {
        let all = list()

        for group in [all.filter { $0.isAutomatic }, all.filter { !$0.isAutomatic }] {
            for old in group.dropFirst(Self.keepCount) {
                try? FileManager.default.removeItem(at: old.url)
                DiagnosticsLog.shared.log("backup", "pruned \(old.url.lastPathComponent)")
            }
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    // MARK: private, file names

    // dime-20261113-214005-auto(.json): local time, fixed format.
    private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    private static func fileStamp(_ date: Date) -> String {
        stampFormatter().string(from: date)
    }

    private static func parse(fileName: String) -> (date: Date, tag: String)? {
        let parts = fileName.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)

        guard parts.count == 4, parts[0] == "dime",
              let date = stampFormatter().date(from: "\(parts[1])-\(parts[2])")
        else {
            return nil
        }

        var tag = String(parts[3])

        // Strip the "-2" suffix of a same-second duplicate.
        if let dash = tag.lastIndex(of: "-"), Int(tag[tag.index(after: dash)...]) != nil {
            tag = String(tag[..<dash])
        }

        return (date, tag)
    }

    // MARK: private, restore

    private static func existingIDs(entity: String, in context: NSManagedObjectContext) -> Set<UUID> {
        let request = NSFetchRequest<NSDictionary>(entityName: entity)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]

        let rows = (try? context.fetch(request)) ?? []

        return Set(rows.compactMap { $0["id"] as? UUID })
    }

    private static func replaceAll(with document: BackupDocument, in context: NSManagedObjectContext) throws -> RestoreResult {
        // Object deletes (not a batch delete), so the same save that removes the old rows
        // inserts the new ones: a failure leaves the store untouched.
        for entity in ["Transaction", "TemplateTransaction", "Budget", "MainBudget", "Category"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.includesPropertyValues = false

            for object in try context.fetch(request) {
                context.delete(object)
            }
        }

        return insert(document, in: context, existingCategories: [:], skipTransactions: [], skipBudgets: [], skipTemplates: [], insertMainBudgets: true)
    }

    private static func mergeMissing(from document: BackupDocument, in context: NSManagedObjectContext) throws -> RestoreResult {
        var existingCategories = [UUID: Category]()
        let categoryRequest: NSFetchRequest<Category> = Category.fetchRequest()

        for category in try context.fetch(categoryRequest) {
            if let id = category.id {
                existingCategories[id] = category
            }
        }

        let mainBudgetRequest: NSFetchRequest<MainBudget> = MainBudget.fetchRequest()
        let hasMainBudget = try context.count(for: mainBudgetRequest) > 0

        return insert(
            document,
            in: context,
            existingCategories: existingCategories,
            skipTransactions: existingIDs(entity: "Transaction", in: context),
            skipBudgets: existingIDs(entity: "Budget", in: context),
            skipTemplates: existingIDs(entity: "TemplateTransaction", in: context),
            insertMainBudgets: !hasMainBudget
        )
    }

    private static func insert(
        _ document: BackupDocument,
        in context: NSManagedObjectContext,
        existingCategories: [UUID: Category],
        skipTransactions: Set<UUID>,
        skipBudgets: Set<UUID>,
        skipTemplates: Set<UUID>,
        insertMainBudgets: Bool
    ) -> RestoreResult {
        var result = RestoreResult()
        var categories = existingCategories
        var newCategoryIDs = Set<UUID>()

        for record in document.categories {
            if categories[record.id] != nil {
                result.skipped += 1
                continue
            }

            let category = Category(context: context)
            record.apply(to: category)
            categories[record.id] = category
            newCategoryIDs.insert(record.id)
            result.categories += 1
        }

        var seenTransactions = skipTransactions

        for snapshot in document.transactions {
            // Also guards against a file that carries the same id twice.
            guard seenTransactions.insert(snapshot.id).inserted else {
                result.skipped += 1
                continue
            }

            let transaction = Transaction(context: context)
            snapshot.apply(to: transaction)

            if let categoryID = snapshot.categoryID {
                transaction.category = categories[categoryID]
            }

            result.transactions += 1
        }

        for record in document.budgets {
            guard !skipBudgets.contains(record.id), let categoryID = record.categoryID, let category = categories[categoryID] else {
                result.skipped += 1
                continue
            }

            // One budget per category: an existing category keeps the budget it has.
            guard newCategoryIDs.contains(categoryID) || category.budget == nil else {
                result.skipped += 1
                continue
            }

            let budget = Budget(context: context)
            record.apply(to: budget)
            budget.category = category
            result.budgets += 1
        }

        if insertMainBudgets {
            for record in document.mainBudgets {
                let budget = MainBudget(context: context)
                record.apply(to: budget)
                result.mainBudgets += 1
            }
        } else {
            result.skipped += document.mainBudgets.count
        }

        for record in document.templates {
            guard !skipTemplates.contains(record.id) else {
                result.skipped += 1
                continue
            }

            let template = TemplateTransaction(context: context)
            record.apply(to: template)

            if let categoryID = record.categoryID {
                template.category = categories[categoryID]
            }

            result.templates += 1
        }

        return result
    }
}
