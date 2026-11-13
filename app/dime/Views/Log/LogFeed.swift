//
//  LogFeed.swift
//  dime
//
//  App target only, main thread only. One fetch of all transactions for the whole Log:
//  day sections, the UPCOMING block, filters, search and the totals above the list are
//  all cut from the same value rows in memory. The fetch has no date in its predicate,
//  so nothing is refetched when a view is rebuilt and a row dated today cannot drop out.
//

import Combine
import CoreData
import SwiftUI
import UIKit

/// Cheap facts about the store for views that must not redraw on every change
/// (tab bar, empty state, filter steppers). Published only when a value really changes.
final class LogStats: ObservableObject {
    @Published fileprivate(set) var count = 0
    /// Date of the oldest transaction.
    @Published fileprivate(set) var earliestDate: Date?
    /// Date of the newest transaction that is not in the future.
    @Published fileprivate(set) var latestCurrentDate: Date?

    fileprivate init() {}
}

final class LogFeed: NSObject, ObservableObject, NSFetchedResultsControllerDelegate {
    static let shared = LogFeed()

    let stats = LogStats()

    /// Every transaction, newest first.
    private(set) var rows = [LogRowModel]()
    /// Rows dated up to the end of today, newest first.
    private(set) var current = [LogRowModel]()
    /// `current` grouped by day.
    private(set) var sections = [LogDaySection]()
    /// Future rows and rows that still repeat, latest first.
    private(set) var upcoming = [LogRowModel]()
    /// Start of tomorrow at the last rebuild.
    private(set) var cutoff = LogCutoff.startOfTomorrow()
    /// Goes up with every rebuild.
    private(set) var revision = 0

    /// Set before a change that should slide rows in or out; consumed by the next rebuild.
    var animateNextRebuild = false

    private let dataController = DataController.shared
    private var controller: NSFetchedResultsController<Transaction>?
    private var observers = [NSObjectProtocol]()
    private var rebuildScheduled = false
    private var totalsCache = [String: LogTotals]()
    private var graphCache = [String: [LineGraphDataPoint]]()
    private var timeZoneID = TimeZone.current.identifier

    override private init() {
        super.init()
        observe()
        start()
    }

    // MARK: lookups

    /// The live object behind a row, nil when it is gone.
    func transaction(for row: LogRowModel) -> Transaction? {
        let context = dataController.container.viewContext

        if let found = try? context.existingObject(with: row.objectID) as? Transaction, !found.isDeleted {
            return found
        }

        if let found = dataController.findTransaction(withId: row.id), !found.isDeleted {
            return found
        }

        return nil
    }

    // MARK: filters

    func sections(where isIncluded: (LogRowModel) -> Bool) -> [LogDaySection] {
        LogSections.group(current.filter(isIncluded))
    }

    /// Rows with `start <= date < end`, never past the end of today.
    func sections(from start: Date, to end: Date) -> [LogDaySection] {
        var matches = [LogRowModel]()

        // `current` is sorted newest first.
        for row in current {
            if row.date < start {
                break
            }

            if row.date < end {
                matches.append(row)
            }
        }

        return LogSections.group(matches)
    }

    // MARK: totals

    /// timeframe: 1 today, 2 this week, 3 this month, 4 this year, 5 all time
    /// (the same periods as DataController.fetchRequestForLogView).
    func totals(timeframe: Int) -> LogTotals {
        // The week and month periods move with these two settings, no rebuild follows a change.
        let defaults = UserDefaults.appGroup
        let key = "\(timeframe)|\(defaults.integer(forKey: "firstWeekday"))|\(defaults.integer(forKey: "firstDayOfMonth"))"

        if let cached = totalsCache[key] {
            return cached
        }

        let start = LogFeed.periodStart(timeframe: timeframe)
        var result = LogTotals()

        for row in current {
            if let start = start, row.date < start {
                break
            }

            if row.income {
                result.income += row.amount
            } else {
                result.spent += row.amount
            }
        }

        totalsCache[key] = result
        return result
    }

    /// insightsType: 1 net, 2 income, 3 spent. Fetched once per rebuild, not once per body pass.
    func lineGraph(insightsType: Int, timeframe: Int) -> [LineGraphDataPoint] {
        let key = "\(insightsType)|\(timeframe)"

        if let cached = graphCache[key] {
            return cached
        }

        let points: [LineGraphDataPoint]

        if insightsType == 1 {
            points = dataController.getLineGraphDataNet(type: timeframe)
        } else {
            points = dataController.getLineGraphData(income: insightsType == 2, type: timeframe)
        }

        graphCache[key] = points
        return points
    }

    static func periodStart(timeframe: Int, now: Date = Date.now) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = UserDefaults.appGroup.integer(forKey: "firstWeekday")
        calendar.minimumDaysInFirstWeek = 4

        switch timeframe {
        case 1:
            return calendar.startOfDay(for: now)
        case 2:
            return calendar.date(from: calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: now))
        case 3:
            return getStartOfMonth(startDay: UserDefaults.appGroup.integer(forKey: "firstDayOfMonth"))
        case 4:
            return calendar.date(from: calendar.dateComponents([.year], from: now))
        default:
            return nil
        }
    }

    // MARK: fetch

    private func start() {
        guard controller == nil, dataController.isStoreLoaded else {
            return
        }

        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Transaction.date, ascending: false),
            NSSortDescriptor(keyPath: \Transaction.note, ascending: true)
        ]
        request.relationshipKeyPathsForPrefetching = ["category"]

        let created = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: dataController.container.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        created.delegate = self
        controller = created

        refetch()
    }

    private func refetch() {
        guard let controller = controller else {
            start()
            return
        }

        do {
            try controller.performFetch()
        } catch {
            DiagnosticsLog.shared.log("log", "feed fetch FAILED \(error.localizedDescription)")
        }

        rebuild()
    }

    func controllerDidChangeContent(_: NSFetchedResultsController<NSFetchRequestResult>) {
        scheduleRebuild()
    }

    // Several changes in one run loop turn (a save, a CloudKit merge) end in one rebuild.
    private func scheduleRebuild() {
        guard !rebuildScheduled else {
            return
        }

        rebuildScheduled = true

        DispatchQueue.main.async { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        let objects = controller?.fetchedObjects ?? []
        let newCutoff = LogCutoff.startOfTomorrow()

        var all = [LogRowModel]()
        all.reserveCapacity(objects.count)

        for transaction in objects where !transaction.isDeleted {
            all.append(LogRowModel(transaction, cutoff: newCutoff))
        }

        // The fetch is sorted already, but a row without a date counts as "now".
        all.sort(by: LogRowModel.newestFirst)

        var newCurrent = [LogRowModel]()
        var newUpcoming = [LogRowModel]()
        // The UPCOMING block is one ForEach: ids must be unique there (a double import leaves twins).
        var upcomingIDs = Set<UUID>()
        newCurrent.reserveCapacity(all.count)

        for row in all {
            if row.isCurrent {
                newCurrent.append(row)
            }

            if !row.isCurrent || row.recurringType > 0 {
                if upcomingIDs.insert(row.id).inserted {
                    newUpcoming.append(row)
                }
            }
        }

        newUpcoming.sort { $0.upcomingDate > $1.upcomingDate }

        let newSections = LogSections.group(newCurrent)
        let animated = animateNextRebuild
        animateNextRebuild = false

        let apply = {
            self.objectWillChange.send()
            self.rows = all
            self.current = newCurrent
            self.sections = newSections
            self.upcoming = newUpcoming
            self.cutoff = newCutoff
            self.revision += 1
            self.totalsCache.removeAll()
            self.graphCache.removeAll()
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.3)) {
                apply()
            }
        } else {
            apply()
        }

        timeZoneID = TimeZone.current.identifier

        if stats.count != all.count {
            stats.count = all.count
        }

        if stats.earliestDate != all.last?.date {
            stats.earliestDate = all.last?.date
        }

        if stats.latestCurrentDate != newCurrent.first?.date {
            stats.latestCurrentDate = newCurrent.first?.date
        }
    }

    // MARK: observers

    private func observe() {
        let center = NotificationCenter.default
        let viewContext = dataController.container.viewContext

        // The results controller watches transactions only: a renamed or recoloured
        // category has to rebuild the rows too.
        observers.append(center.addObserver(forName: .NSManagedObjectContextObjectsDidChange, object: viewContext, queue: nil) { [weak self] notification in
            guard let self = self, LogFeed.touchesCategory(notification) else {
                return
            }

            if Thread.isMainThread {
                self.scheduleRebuild()
            } else {
                DispatchQueue.main.async {
                    self.scheduleRebuild()
                }
            }
        })

        observers.append(center.addObserver(forName: .dimeStoreLoadStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.storeChanged()
        })

        // Batch deletes post no context notifications.
        observers.append(center.addObserver(forName: .dimeStoreErased, object: nil, queue: .main) { [weak self] _ in
            self?.refetch()
        })

        // "Today" moves: at midnight, after a time zone change and after a long time in the background.
        let dayNames: [Notification.Name] = [
            Notification.Name.NSCalendarDayChanged,
            Notification.Name.NSSystemTimeZoneDidChange,
            UIApplication.significantTimeChangeNotification,
            UIApplication.willEnterForegroundNotification
        ]

        for name in dayNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.dayMayHaveChanged()
            })
        }
    }

    private func storeChanged() {
        if dataController.isStoreLoaded {
            // The store may have been reopened: fetch again against the new one.
            refetch()
        }
    }

    private func dayMayHaveChanged() {
        let zone = TimeZone.current.identifier

        if LogCutoff.startOfTomorrow() != cutoff || zone != timeZoneID {
            rebuild()
        }
    }

    private static func touchesCategory(_ notification: Notification) -> Bool {
        guard let userInfo = notification.userInfo else {
            return false
        }

        if userInfo[NSInvalidatedAllObjectsKey] != nil {
            return true
        }

        for key in [NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSInsertedObjectsKey, NSDeletedObjectsKey] {
            if let objects = userInfo[key] as? Set<NSManagedObject>, objects.contains(where: { $0 is Category }) {
                return true
            }
        }

        return false
    }
}
