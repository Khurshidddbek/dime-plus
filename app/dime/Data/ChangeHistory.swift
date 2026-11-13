//
//  ChangeHistory.swift
//  dime
//
//  App target only. Settings > History of changes: every insert, edit and delete of a
//  Transaction made in this process, from any context (view, SMS, import, restore,
//  CloudKit import). Values are copied in willSave (committed values are still readable
//  there) and written after didSave, so a failed save leaves no record.
//  Storage: JSON lines in the app group, 90 days / 5000 records, appended on a utility queue.
//

import CoreData
import Foundation
import SwiftUI
import UIKit

struct ChangeField: Codable, Equatable {
    enum Field: String, Codable {
        case amount, income, note, category, date
    }

    var field: Field
    var oldText: String?
    var newText: String?
    var oldNumber: Double?
    var newNumber: Double?
    var oldDate: Date?
    var newDate: Date?
    var oldFlag: Bool?
    var newFlag: Bool?
}

struct ChangeRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case added, edited, deleted, restored, bulk, erased
    }

    var id: UUID
    var at: Date
    var kind: Kind
    /// manual, shortcut, recurring, trash, sms, sms-auto, import, restore, icloud, system
    var source: String
    /// Raw context name, for diagnostics.
    var origin: String?
    var transactionID: UUID?
    var amount: Double
    var income: Bool
    var note: String
    var categoryName: String
    var categoryEmoji: String
    var date: Date?
    var changes: [ChangeField]?
    /// Bulk records only.
    var addedCount: Int?
    var deletedCount: Int?
    var editedCount: Int?
    /// What this change did to the balance: income counts plus, expenses minus.
    var effect: Double

    var signedAmount: Double {
        income ? amount : -amount
    }

    var isFromSMS: Bool {
        source == ChangeHistory.Source.sms || source == ChangeHistory.Source.smsAuto
    }
}

final class ChangeHistory: ObservableObject {
    enum Source {
        static let manual = "manual"
        static let shortcut = "shortcut"
        static let recurring = "recurring"
        static let trash = "trash"
        static let sms = "sms"
        static let smsAuto = "sms-auto"
        static let importing = "import"
        static let restore = "restore"
        static let icloud = "icloud"
        static let system = "system"
    }

    static let shared = ChangeHistory()

    static let maxRecords = 5000
    static let retention: TimeInterval = 90 * 24 * 60 * 60
    /// One save touching more rows than this (import, restore, first iCloud sync) becomes one summary record.
    static let bulkThreshold = 200

    /// Newest first. Main thread.
    @Published private(set) var records: [ChangeRecord] = []
    @Published private(set) var isLoaded = false

    private static let startedAtKey = "changeHistoryStartedAt"

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "dime.change-history", qos: .utility)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Oldest first. ioQueue only.
    private var stored = [ChangeRecord]()

    private let pendingLock = NSLock()
    private var pending = [ObjectIdentifier: [ChangeRecord]]()

    private var observers = [NSObjectProtocol]()
    private var started = false

    private init() {
        fileURL = AppFiles.sharedDirectory("History").appendingPathComponent("changes.jsonl")

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    /// The day the recorder first ran. Older changes are not in the history.
    var startedAt: Date {
        UserDefaults.appGroup.object(forKey: Self.startedAtKey) as? Date ?? Date()
    }

    /// Call once, as early as possible at launch (before any save). Main thread.
    func start() {
        guard !started else {
            return
        }

        started = true

        if UserDefaults.appGroup.object(forKey: Self.startedAtKey) == nil {
            UserDefaults.appGroup.set(Date(), forKey: Self.startedAtKey)
        }

        let center = NotificationCenter.default

        // queue nil: delivered synchronously on the saving context's own queue.
        observers.append(center.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { [weak self] notification in
            guard let context = notification.object as? NSManagedObjectContext else {
                return
            }

            self?.contextWillSave(context)
        })

        observers.append(center.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { [weak self] notification in
            guard let context = notification.object as? NSManagedObjectContext else {
                return
            }

            self?.contextDidSave(context)
        })

        observers.append(center.addObserver(forName: .dimeStoreErased, object: nil, queue: nil) { [weak self] _ in
            self?.recordErase()
        })

        ioQueue.async { [weak self] in
            self?.load()
        }
    }

    // MARK: capture

    private struct Values: Equatable {
        var id: UUID?
        var amount: Double
        var income: Bool
        var note: String
        var categoryName: String
        var categoryEmoji: String
        var date: Date?

        var signed: Double {
            income ? amount : -amount
        }
    }

    private func contextWillSave(_ context: NSManagedObjectContext) {
        // A child context only pushes into its parent; the parent's save is the one that reaches the store.
        guard context.parent == nil else {
            return
        }

        let key = ObjectIdentifier(context)
        let made = capture(context)

        pendingLock.lock()
        if made.isEmpty {
            pending.removeValue(forKey: key)
        } else {
            pending[key] = made
        }
        pendingLock.unlock()
    }

    private func contextDidSave(_ context: NSManagedObjectContext) {
        let key = ObjectIdentifier(context)

        pendingLock.lock()
        let made = pending.removeValue(forKey: key)
        pendingLock.unlock()

        guard let made = made, !made.isEmpty else {
            return
        }

        append(made)
    }

    // Runs on the saving context's queue, inside save().
    private func capture(_ context: NSManagedObjectContext) -> [ChangeRecord] {
        let inserted = context.insertedObjects.compactMap { $0 as? Transaction }
        let updated = context.updatedObjects.compactMap { $0 as? Transaction }
        var deleted = context.deletedObjects.compactMap { $0 as? Transaction }

        // Category -> transactions is a cascade; it may not be propagated yet when willSave fires.
        let deletedCategories = context.deletedObjects.compactMap { $0 as? Category }

        if !deletedCategories.isEmpty {
            var seen = Set(deleted.map { $0.objectID })

            for category in deletedCategories {
                let rows = category.transactions as? Set<Transaction> ?? []

                for row in rows where !row.isInserted && !seen.contains(row.objectID) {
                    seen.insert(row.objectID)
                    deleted.append(row)
                }
            }
        }

        guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty else {
            return []
        }

        let name = context.name ?? ""
        let author = context.transactionAuthor ?? ""
        let isViewContext = name == "view"
        let baseSource = Self.source(name: name, author: author)
        let now = Date()

        var trashIDs = Set<UUID>()
        var isBackground = false

        if isViewContext, Thread.isMainThread, !inserted.isEmpty {
            trashIDs = Set(TrashStore.shared.items.map { $0.id })
            isBackground = UIApplication.shared.applicationState == .background
        }

        // A recurring series hands over: the source row loses its recurringType in the same save.
        let generatesRecurring = updated.contains { row in
            let old = row.committedValues(forKeys: ["recurringType"])["recurringType"]
            return Self.int(old) > 0 && row.recurringType == 0
        }

        var deletedValues = deleted.map { committedValues(of: $0, in: context) }
        var records = [ChangeRecord]()

        // Delete and insert of the same id in one save (backup restore) is an edit or nothing.
        var insertedRows = [(Transaction, Values)]()

        for row in inserted {
            let values = currentValues(of: row, in: context)

            if let id = values.id, let index = deletedValues.firstIndex(where: { $0.id == id }) {
                let old = deletedValues.remove(at: index)
                let fields = Self.diff(old: old, new: values)

                if !fields.isEmpty {
                    records.append(makeRecord(kind: .edited, source: baseSource, origin: name, values: values, changes: fields, effect: values.signed - old.signed, at: now))
                }

                continue
            }

            insertedRows.append((row, values))
        }

        for (row, values) in insertedRows {
            var kind = ChangeRecord.Kind.added
            var source = baseSource

            if isViewContext {
                if let id = values.id, trashIDs.contains(id) {
                    kind = .restored
                    source = Source.trash
                } else if generatesRecurring, row.onceRecurring {
                    source = Source.recurring
                } else if isBackground {
                    source = Source.shortcut
                }
            } else if source == Source.restore || source == Source.trash {
                kind = .restored
            }

            records.append(makeRecord(kind: kind, source: source, origin: name, values: values, changes: nil, effect: values.signed, at: now))
        }

        for row in updated {
            let changed = row.changedValues()
            let tracked = ["amount", "income", "note", "date", "category"]

            guard tracked.contains(where: { changed[$0] != nil }) else {
                continue
            }

            let old = committedValues(of: row, in: context)
            let new = currentValues(of: row, in: context)
            let fields = Self.diff(old: old, new: new)

            guard !fields.isEmpty else {
                continue
            }

            records.append(makeRecord(kind: .edited, source: baseSource, origin: name, values: new, changes: fields, effect: new.signed - old.signed, at: now))
        }

        for values in deletedValues {
            records.append(makeRecord(kind: .deleted, source: baseSource, origin: name, values: values, changes: nil, effect: -values.signed, at: now))
        }

        guard records.count > Self.bulkThreshold else {
            return records
        }

        let added = records.filter { $0.kind == .added || $0.kind == .restored }.count
        let removed = records.filter { $0.kind == .deleted }.count
        let edited = records.filter { $0.kind == .edited }.count
        let effect = records.reduce(0.0) { $0 + $1.effect }

        let summary = ChangeRecord(
            id: UUID(), at: now, kind: .bulk, source: baseSource, origin: name, transactionID: nil,
            amount: abs(effect), income: effect > 0, note: "", categoryName: "", categoryEmoji: "", date: nil,
            changes: nil, addedCount: added, deletedCount: removed, editedCount: edited, effect: effect
        )

        return [summary]
    }

    private func makeRecord(kind: ChangeRecord.Kind, source: String, origin: String, values: Values, changes: [ChangeField]?, effect: Double, at: Date) -> ChangeRecord {
        ChangeRecord(
            id: UUID(), at: at, kind: kind, source: source, origin: origin.isEmpty ? nil : origin,
            transactionID: values.id, amount: values.amount, income: values.income, note: values.note,
            categoryName: values.categoryName, categoryEmoji: values.categoryEmoji, date: values.date,
            changes: changes, addedCount: nil, deletedCount: nil, editedCount: nil, effect: effect
        )
    }

    private func currentValues(of row: Transaction, in _: NSManagedObjectContext) -> Values {
        Values(
            id: row.id,
            amount: row.amount,
            income: row.income,
            note: row.note ?? "",
            categoryName: row.category?.name ?? "",
            categoryEmoji: row.category?.emoji ?? "",
            date: row.date
        )
    }

    /// Values as they are in the store. Falls back to the in-memory value for a key that has none.
    private func committedValues(of row: Transaction, in context: NSManagedObjectContext) -> Values {
        let current = currentValues(of: row, in: context)
        let committed = row.committedValues(forKeys: ["id", "amount", "income", "note", "date", "category"])

        guard !committed.isEmpty else {
            return current
        }

        var values = current

        if let id = committed["id"] as? UUID {
            values.id = id
        }

        if let amount = committed["amount"] as? NSNumber {
            values.amount = amount.doubleValue
        }

        if let income = committed["income"] as? NSNumber {
            values.income = income.boolValue
        }

        if committed.keys.contains("note") {
            values.note = committed["note"] as? String ?? ""
        }

        if committed.keys.contains("date") {
            values.date = committed["date"] as? Date
        }

        if committed.keys.contains("category") {
            let category = Self.category(from: committed["category"], in: context)
            values.categoryName = category?.name ?? ""
            values.categoryEmoji = category?.emoji ?? ""
        }

        return values
    }

    private static func category(from value: Any?, in context: NSManagedObjectContext) -> Category? {
        if let category = value as? Category {
            return category
        }

        if let objectID = value as? NSManagedObjectID {
            return (try? context.existingObject(with: objectID)) as? Category
        }

        return nil
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }

        return 0
    }

    private static func diff(old: Values, new: Values) -> [ChangeField] {
        var fields = [ChangeField]()

        if old.amount != new.amount {
            fields.append(ChangeField(field: .amount, oldNumber: old.amount, newNumber: new.amount))
        }

        if old.income != new.income {
            fields.append(ChangeField(field: .income, oldFlag: old.income, newFlag: new.income))
        }

        if old.note != new.note {
            fields.append(ChangeField(field: .note, oldText: old.note, newText: new.note))
        }

        if old.categoryName != new.categoryName || old.categoryEmoji != new.categoryEmoji {
            fields.append(ChangeField(field: .category, oldText: categoryText(old), newText: categoryText(new)))
        }

        if old.date != new.date {
            fields.append(ChangeField(field: .date, oldDate: old.date, newDate: new.date))
        }

        return fields
    }

    private static func categoryText(_ values: Values) -> String {
        [values.categoryEmoji, values.categoryName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func source(name: String, author: String) -> String {
        let lowered = (name + " " + author).lowercased()

        if lowered.contains("cloudkit") {
            return Source.icloud
        }

        if name == "view" {
            return Source.manual
        }

        if lowered.contains("sms auto") || lowered.contains("sms-auto") {
            return Source.smsAuto
        }

        if lowered.contains("sms") {
            return Source.sms
        }

        if lowered.contains("restore backup") {
            return Source.restore
        }

        if lowered.contains("csv") || lowered.contains("import") {
            return Source.importing
        }

        if lowered.contains("recurring") {
            return Source.recurring
        }

        if lowered.contains("trash") {
            return Source.trash
        }

        if lowered.contains("shortcut") || lowered.contains("intent") {
            return Source.shortcut
        }

        return Source.system
    }

    private func recordErase() {
        let record = ChangeRecord(
            id: UUID(), at: Date(), kind: .erased, source: Source.manual, origin: "erase", transactionID: nil,
            amount: 0, income: false, note: "", categoryName: "", categoryEmoji: "", date: nil,
            changes: nil, addedCount: nil, deletedCount: nil, editedCount: nil, effect: 0
        )

        append([record])
    }

    /// The entry screen saves through the view context, so an SMS confirmed there is first recorded as manual.
    /// Queued after that save's append, so the record is already stored when this runs.
    func relabelAdded(transactionID: UUID, source: String) {
        ioQueue.async { [weak self] in
            guard let self = self,
                  let index = self.stored.lastIndex(where: { $0.transactionID == transactionID && $0.kind == .added }),
                  self.stored[index].source == Source.manual
            else {
                return
            }

            self.stored[index].source = source
            self.rewrite()
            self.publish()
        }
    }

    // MARK: storage (ioQueue)

    private func append(_ new: [ChangeRecord]) {
        ioQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            self.stored.append(contentsOf: new)

            let cutoff = Date().addingTimeInterval(-Self.retention)
            let overLimit = self.stored.count > Self.maxRecords + 500
            let expired = (self.stored.first?.at ?? Date()) < cutoff.addingTimeInterval(-24 * 60 * 60)

            if overLimit || expired {
                self.prune()
                self.rewrite()
            } else {
                self.appendLines(new)
            }

            self.publish()
        }
    }

    private func load() {
        var decoded = [ChangeRecord]()
        var damaged = 0

        if let data = try? Data(contentsOf: fileURL) {
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let record = try? decoder.decode(ChangeRecord.self, from: Data(line)) {
                    decoded.append(record)
                } else {
                    damaged += 1
                }
            }
        }

        // Appends that arrived before the file was read are already in `stored`.
        let early = stored
        let earlyIDs = Set(early.map { $0.id })
        stored = decoded.filter { !earlyIDs.contains($0.id) } + early
        stored.sort { $0.at < $1.at }

        let before = stored.count
        prune()

        if damaged > 0 || stored.count != before || !early.isEmpty {
            rewrite()
        }

        if damaged > 0 {
            DiagnosticsLog.shared.log("history", "skipped \(damaged) unreadable line(s)")
        }

        publish()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        stored.removeAll { $0.at < cutoff }

        if stored.count > Self.maxRecords {
            stored.removeFirst(stored.count - Self.maxRecords)
        }
    }

    private func lines(_ records: [ChangeRecord]) -> Data {
        var data = Data()

        for record in records {
            if let line = try? encoder.encode(record) {
                data.append(line)
                data.append(0x0A)
            }
        }

        return data
    }

    private func appendLines(_ records: [ChangeRecord]) {
        let data = lines(records)

        guard !data.isEmpty else {
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            rewrite()
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            DiagnosticsLog.shared.log("history", "append FAILED \(DataController.describe(error as NSError))")
            rewrite()
        }
    }

    private func rewrite() {
        do {
            try lines(stored).write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticsLog.shared.log("history", "write FAILED \(DataController.describe(error as NSError))")
        }
    }

    private func publish() {
        let snapshot = Array(stored.reversed())

        DispatchQueue.main.async {
            self.records = snapshot
            self.isLoaded = true
        }
    }
}
