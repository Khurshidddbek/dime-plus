//
//  PersistenceStatus.swift
//  dime
//
//  App target only. Publishes what DataController broadcasts (it is not @Published there,
//  because DataController is an environment object of most views) and runs the launch
//  integrity check. Main thread only.
//

import CoreData
import Foundation
import SwiftUI

final class PersistenceStatus: ObservableObject {
    static let shared = PersistenceStatus()

    @Published private(set) var isStoreLoaded: Bool
    @Published private(set) var storeLoadError: NSError?
    /// Non-nil while the view context holds changes that could not be saved.
    @Published private(set) var saveFailure: SaveFailure?
    /// Transactions this device saved recently that are no longer in the store
    /// and were not deleted through the app. Filled by `checkIntegrity()`.
    @Published private(set) var missingTransactionIDs: [UUID] = []

    private let dataController = DataController.shared
    private var observers = [NSObjectProtocol]()
    private var pendingDeletedIDs = Set<UUID>()
    private var started = false

    private let ringKey = "integrityRing"
    private let ringLimit = 100

    private init() {
        isStoreLoaded = dataController.isStoreLoaded
        storeLoadError = dataController.storeLoadError
        saveFailure = dataController.lastSaveFailure
    }

    /// Starts observing. Safe to call more than once.
    func start() {
        guard !started else {
            return
        }

        started = true

        let center = NotificationCenter.default
        let viewContext = dataController.container.viewContext

        observers.append(center.addObserver(forName: .dimeStoreLoadStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLoadState()
        })

        observers.append(center.addObserver(forName: .dimeSaveFailed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSaveState()
            // Central feedback, so no failed save stays silent whichever screen caused it.
            ToastCenter.shared.saveFailed()
        })

        observers.append(center.addObserver(forName: .dimeSaveRecovered, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSaveState()
        })

        observers.append(center.addObserver(forName: .dimeStoreErased, object: nil, queue: .main) { [weak self] _ in
            self?.clearRing()
        })

        // The ids of deleted rows are readable only before the save.
        observers.append(center.addObserver(forName: .NSManagedObjectContextWillSave, object: viewContext, queue: nil) { [weak self] _ in
            self?.collectPendingDeletes(in: viewContext)
        })

        observers.append(center.addObserver(forName: .NSManagedObjectContextDidSave, object: viewContext, queue: nil) { [weak self] notification in
            self?.viewContextDidSave(notification)
        })

        refreshLoadState()
        refreshSaveState()
    }

    // MARK: state

    private func refreshLoadState() {
        isStoreLoaded = dataController.isStoreLoaded
        storeLoadError = dataController.storeLoadError
    }

    private func refreshSaveState() {
        saveFailure = dataController.lastSaveFailure
    }

    /// For the recovery screen.
    @discardableResult
    func retryLoadStore() -> Bool {
        let loaded = dataController.retryLoadStore()
        refreshLoadState()
        return loaded
    }

    /// For a "Not saved - tap to retry" control. Returns true when nothing is left unsaved.
    @discardableResult
    func retrySave() -> Bool {
        let outcome = dataController.save("retry")
        refreshSaveState()
        return !outcome.isFailure
    }

    // MARK: integrity ring

    // Ring of the last transactions this process saved: [["id": uuidString, "at": seconds]].
    private var ring: [[String: Any]] {
        get {
            UserDefaults.standard.array(forKey: ringKey) as? [[String: Any]] ?? []
        }

        set {
            UserDefaults.standard.set(Array(newValue.suffix(ringLimit)), forKey: ringKey)
        }
    }

    private var ringIDs: [UUID] {
        ring.compactMap { entry in
            (entry["id"] as? String).flatMap { UUID(uuidString: $0) }
        }
    }

    /// Call after rows were inserted outside the view context (bulk writes do it themselves).
    func noteInserted(_ ids: [UUID]) {
        guard !ids.isEmpty else {
            return
        }

        let now = Date().timeIntervalSince1970
        var current = ring
        let known = Set(current.compactMap { $0["id"] as? String })

        for id in ids where !known.contains(id.uuidString) {
            current.append(["id": id.uuidString, "at": now])
        }

        ring = current
    }

    /// Call after rows were deleted on purpose outside the view context.
    func noteDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else {
            return
        }

        let removed = Set(ids.map { $0.uuidString })
        ring = ring.filter { entry in
            guard let id = entry["id"] as? String else {
                return false
            }

            return !removed.contains(id)
        }
    }

    /// Call after the store was replaced on purpose (restore from a backup).
    func forgetRecentSaves() {
        clearRing()
    }

    private func clearRing() {
        UserDefaults.standard.removeObject(forKey: ringKey)
        pendingDeletedIDs.removeAll()
        missingTransactionIDs = []
    }

    private func collectPendingDeletes(in context: NSManagedObjectContext) {
        for object in context.deletedObjects {
            if let transaction = object as? Transaction, let id = transaction.id {
                pendingDeletedIDs.insert(id)
            }
        }
    }

    private func viewContextDidSave(_ notification: Notification) {
        let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
        let insertedIDs = inserted.compactMap { ($0 as? Transaction)?.id }
        let deletedIDs = Array(pendingDeletedIDs)
        pendingDeletedIDs.removeAll()

        noteInserted(insertedIDs)
        noteDeleted(deletedIDs)
    }

    /// Looks for recently saved transactions that vanished from the store without a
    /// delete in this app. Logs `INTEGRITY` and publishes the ids. Cheap: one fetch
    /// of at most 100 ids. Call at launch and when the app becomes active.
    @discardableResult
    func checkIntegrity() -> [UUID] {
        guard dataController.isStoreLoaded else {
            return []
        }

        let ids = ringIDs

        guard !ids.isEmpty else {
            return []
        }

        let context = dataController.container.viewContext

        // Rows waiting for a save or a pending delete would give false alarms.
        guard !context.hasChanges else {
            return []
        }

        let request = NSFetchRequest<NSDictionary>(entityName: "Transaction")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        request.predicate = NSPredicate(format: "id IN %@", argumentArray: [ids])

        let rows: [NSDictionary]

        do {
            rows = try context.fetch(request)
        } catch {
            DiagnosticsLog.shared.log("integrity", "check failed \(DataController.describe(error as NSError))")
            return []
        }

        let found = Set(rows.compactMap { $0["id"] as? UUID })
        let missing = ids.filter { !found.contains($0) }

        guard !missing.isEmpty else {
            return []
        }

        let list = missing.map { $0.uuidString }.joined(separator: ",")
        DiagnosticsLog.shared.log("integrity", "INTEGRITY \(missing.count) of \(ids.count) recently saved transactions are missing: \(list)")

        // Reported once: drop them from the ring so the next launch does not repeat it.
        noteDeleted(missing)

        var all = missingTransactionIDs

        for id in missing where !all.contains(id) {
            all.append(id)
        }

        missingTransactionIDs = all

        return missing
    }

    /// For the UI after it has shown or handled the report.
    func clearMissing() {
        missingTransactionIDs = []
    }
}
