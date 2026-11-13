//
//  LogActions.swift
//  dime
//
//  App target only, main thread only. Everything a Log row can do. Rows call these
//  instead of observing a shared object, so a tap on one row does not redraw the others.
//

import CoreData
import SwiftUI
import UIKit

enum LogActions {
    private static var manager: OverallTransactionManager {
        OverallTransactionManager.shared
    }

    private static var dataController: DataController {
        DataController.shared
    }

    // Deletes made while the undo toast is still up are undone together.
    private static var burstIDs = [UUID]()
    private static var burstExpires = Date.distantPast
    private static let burstWindow: TimeInterval = 5

    // MARK: edit

    static func edit(_ row: LogRowModel) {
        guard let transaction = LogFeed.shared.transaction(for: row) else {
            return
        }

        // Search is a cover of its own: the editor has to be presented from inside it.
        if manager.searchActive {
            manager.searchToEdit = transaction
        } else {
            manager.toEdit = transaction
        }
    }

    // MARK: delete

    /// Half swipe: asks first. Inside search the confirmation card is under the cover,
    /// so the row is deleted at once (the toast still offers Undo).
    static func askToDelete(_ row: LogRowModel, future: Bool) {
        if manager.searchActive {
            delete(row, future: future)
            return
        }

        manager.pendingDelete = LogPendingDelete(row: row, future: future, stopsRecurring: row.stopsRecurring(future: future))

        withAnimation {
            manager.showPopup = true
        }
    }

    static func confirmPendingDelete() {
        let pending = manager.pendingDelete

        // The card keeps its text while it slides away, pendingDelete is a value copy.
        withAnimation {
            manager.showPopup = false
        }

        if let pending = pending {
            delete(pending.row, future: pending.future)
        }
    }

    static func cancelPendingDelete() {
        withAnimation {
            manager.showPopup = false
        }
    }

    /// Deletes the row (or stops the recurrence for a recurring row in the UPCOMING block)
    /// and offers Undo. False when nothing was changed.
    @discardableResult
    static func delete(_ row: LogRowModel, future: Bool) -> Bool {
        guard let transaction = LogFeed.shared.transaction(for: row) else {
            return false
        }

        if row.stopsRecurring(future: future) {
            return stopRecurring(transaction)
        }

        let wasRecurring = transaction.recurringType > 0

        do {
            LogFeed.shared.animateNextRebuild = true

            let trashed = try TrashStore.shared.delete(transaction)
            let now = Date()

            if now > burstExpires {
                burstIDs = []
            }

            burstIDs.append(trashed.id)
            burstExpires = now.addingTimeInterval(burstWindow)

            let ids = burstIDs
            let title: String

            if ids.count > 1 {
                title = String(localized: "\(ids.count) logs deleted")
            } else if wasRecurring {
                title = String(localized: "Deleted, repeating stopped")
            } else {
                title = String(localized: "Log Deleted")
            }

            ToastCenter.shared.undo(title) {
                restore(ids)
            }

            return true
        } catch {
            // The "Couldn't save" toast is automatic and the copy stays in Recently Deleted.
            LogFeed.shared.animateNextRebuild = false
            return false
        }
    }

    private static func restore(_ ids: [UUID]) {
        burstIDs = []
        burstExpires = Date.distantPast

        do {
            LogFeed.shared.animateNextRebuild = true
            try TrashStore.shared.restore(ids: ids)
        } catch {
            LogFeed.shared.animateNextRebuild = false
        }
    }

    // MARK: recurring

    static func stopRecurring(_ row: LogRowModel) {
        guard let transaction = LogFeed.shared.transaction(for: row) else {
            return
        }

        stopRecurring(transaction)
    }

    @discardableResult
    private static func stopRecurring(_ transaction: Transaction) -> Bool {
        let previous = transaction.recurringType

        guard previous > 0 else {
            return false
        }

        LogFeed.shared.animateNextRebuild = true
        transaction.recurringType = 0

        if dataController.save("stop recurring").isFailure {
            return false
        }

        ToastCenter.shared.undo(String(localized: "Recurring stopped"), icon: "repeat.circle.fill") {
            guard !transaction.isDeleted, transaction.managedObjectContext != nil else {
                return
            }

            LogFeed.shared.animateNextRebuild = true
            transaction.recurringType = previous
            dataController.save("resume recurring")
        }

        return true
    }

    // MARK: copies

    /// Opens the editor prefilled from the row and dated now. Nothing is saved until the
    /// user confirms, so closing the editor leaves no stray copy.
    static func duplicate(_ row: LogRowModel) {
        guard let source = LogFeed.shared.transaction(for: row) else {
            return
        }

        Haptics.tap()

        if manager.searchActive {
            manager.searchToDuplicate = source
        } else {
            manager.toDuplicate = source
        }
    }

    /// A copy dated now, saved at once.
    static func logAgainToday(_ row: LogRowModel) {
        guard let copy = makeCopy(of: row) else {
            return
        }

        ToastCenter.shared.show(
            .success,
            String(localized: "Logged again today"),
            icon: "plus.circle.fill",
            actionTitle: String(localized: "Undo")
        ) {
            guard !copy.isDeleted, let context = copy.managedObjectContext else {
                return
            }

            LogFeed.shared.animateNextRebuild = true
            context.delete(copy)
            dataController.save("undo log again")
        }
    }

    private static func makeCopy(of row: LogRowModel) -> Transaction? {
        guard let source = LogFeed.shared.transaction(for: row) else {
            return nil
        }

        do {
            LogFeed.shared.animateNextRebuild = true

            return try dataController.newTransactionOrThrow(
                note: row.rawNote,
                category: source.category,
                income: row.income,
                amount: row.amount,
                date: Date.now
            )
        } catch {
            // The "Couldn't save" toast is automatic.
            LogFeed.shared.animateNextRebuild = false
            return nil
        }
    }

    // MARK: clipboard

    static func copyAmount(_ amount: Double) {
        // Through SMSClipboard: our own copy must not light up the "paste bank SMS" chip.
        SMSClipboard.shared.copy(MoneyFormat.plainString(abs(amount)))
        ToastCenter.shared.info(String(localized: "Amount copied"), icon: "doc.on.doc.fill")
    }
}
