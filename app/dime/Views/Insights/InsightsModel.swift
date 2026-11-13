//
//  InsightsModel.swift
//  dime
//

import Combine
import CoreData
import SwiftUI

// Owns the period, the flow and the selection of the Insights tab, so a save anywhere in the app
// refreshes the numbers without resetting what the user is looking at.
// Main thread only. init does no fetch and installs no observers: everything starts in start(context:).
final class InsightsModel: ObservableObject {
    @Published private(set) var frame: ChartTimeFrame
    @Published private(set) var period: InsightsPeriod
    @Published private(set) var flow: InsightsFlow
    @Published private(set) var selectedCategory: InsightsCategoryKey?
    @Published private(set) var selectedBucket: Int?
    @Published private(set) var linearScale = false

    @Published private(set) var page = InsightsPage()
    @Published private(set) var detail: InsightsCategoryDetail?
    @Published private(set) var periodTitle = ""
    @Published private(set) var isCurrentPeriod = true
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var hasAnyData = false

    private struct TrendKey: Hashable {
        let key: InsightsCategoryKey
        let income: Bool
        let period: InsightsPeriod
    }

    private var rules: InsightsRules
    private var context: NSManagedObjectContext?
    private var snapshot: InsightsSnapshot?
    private var cache: [InsightsPeriod: InsightsSnapshot] = [:]
    private var trendCache: [TrendKey: [Double]] = [:]
    private var earliest: Date?
    private var loadedDay: Date?
    private var incomeTracking = true
    private var detailKey: InsightsCategoryKey?
    private var detailIncome = false

    private var observers: [NSObjectProtocol] = []
    private var pendingReload: DispatchWorkItem?
    private var isVisible = false
    private var isStale = false
    private var isFetching = false

    init() {
        let defaults = UserDefaults.appGroup
        let rules = InsightsRules.current()
        let frame = ChartTimeFrame(storedValue: defaults.integer(forKey: ChartTimeFrame.storageKey))
        self.rules = rules
        self.frame = frame
        period = InsightsPeriod.containing(Date.now, frame: frame, rules: rules)
        flow = InsightsFlow(rawValue: defaults.integer(forKey: InsightsFlow.storageKey)) ?? .expense
    }

    deinit {
        pendingReload?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Lifecycle

    // Called from onAppear of the tab, every time it becomes visible.
    func start(context: NSManagedObjectContext, incomeTracking: Bool) {
        isVisible = true
        self.incomeTracking = incomeTracking

        if self.context == nil {
            self.context = context
            installObservers(for: context)
            reload()
        } else {
            refreshIfNeeded()
        }
    }

    func stop() {
        isVisible = false
    }

    // The day rolled over, a setting that moves period borders changed, or data changed while the tab was hidden.
    func refreshIfNeeded() {
        guard context != nil else { return }
        let today = rules.calendar.startOfDay(for: Date.now)
        if isStale || loadedDay != today || InsightsRules.current() != rules {
            reload()
        }
    }

    func setIncomeTracking(_ enabled: Bool) {
        guard enabled != incomeTracking else { return }
        incomeTracking = enabled
        selectedCategory = nil
        // An income category screen must not stay open once income is hidden.
        detailKey = nil
        rebuild()
    }

    // MARK: Actions

    func setFrame(_ newFrame: ChartTimeFrame) {
        guard newFrame != frame else { return }
        Haptics.selection()

        // Stay on the same moment: a past month opens the year it belongs to.
        let anchor = isCurrentPeriod ? Date.now : period.start
        frame = newFrame
        UserDefaults.appGroup.set(newFrame.storedValue, forKey: ChartTimeFrame.storageKey)
        period = InsightsPeriod.containing(anchor, frame: newFrame, rules: rules)
        selectedBucket = nil
        load()
    }

    func step(_ direction: Int) {
        let allowed = direction < 0 ? canGoBack : canGoForward
        guard allowed else {
            Haptics.impact(.rigid)
            return
        }
        Haptics.tap()
        period = direction < 0 ? period.previous(rules) : period.next(rules)
        selectedBucket = nil
        load()
    }

    func goToCurrent() {
        guard !isCurrentPeriod else { return }
        Haptics.tap()
        period = InsightsPeriod.containing(Date.now, frame: frame, rules: rules)
        selectedBucket = nil
        load()
    }

    func go(to target: InsightsPeriod) {
        guard target != period, target.frame == frame, target.start <= Date.now else { return }
        Haptics.tap()
        period = target
        selectedBucket = nil
        load()
    }

    // Year view: open the selected month as its own period.
    func openSelectedBucketAsMonth() {
        guard frame == .year, let bucket = selectedBucket, let snapshot, bucket < snapshot.bucketStarts.count else { return }
        Haptics.tap()

        // Mid-month, so a custom month start lands on the period that covers most of that calendar month.
        let anchor = rules.calendar.date(byAdding: .day, value: 14, to: snapshot.bucketStarts[bucket]) ?? snapshot.bucketStarts[bucket]
        frame = .month
        UserDefaults.appGroup.set(ChartTimeFrame.month.storedValue, forKey: ChartTimeFrame.storageKey)
        period = InsightsPeriod.containing(min(anchor, Date.now), frame: .month, rules: rules)
        selectedBucket = nil
        load()
    }

    func setFlow(_ newFlow: InsightsFlow) {
        guard newFlow != flow else { return }
        Haptics.selection()
        flow = newFlow
        UserDefaults.appGroup.set(newFlow.rawValue, forKey: InsightsFlow.storageKey)
        selectedCategory = nil
        rebuild()
    }

    // Selecting the selected category again clears it.
    func selectCategory(_ key: InsightsCategoryKey) {
        Haptics.selection()
        selectedCategory = selectedCategory == key ? nil : key
        rebuild()
    }

    // No haptic here: the chart plays one per bar while scrubbing.
    func selectBucket(_ index: Int?) {
        guard index != selectedBucket else { return }
        selectedBucket = index
        rebuild()
    }

    func clearSelection() {
        guard selectedCategory != nil || selectedBucket != nil else { return }
        Haptics.tap()
        selectedCategory = nil
        selectedBucket = nil
        rebuild()
    }

    func toggleScale() {
        linearScale.toggle()
        rebuild()
    }

    func openDetail(_ key: InsightsCategoryKey) {
        Haptics.tap()
        detailKey = key
        detailIncome = page.flow == .income
        rebuild()
    }

    func closeDetail() {
        guard detailKey != nil else { return }
        Haptics.tap()
        detailKey = nil
        rebuild()
    }

    // MARK: Loading

    private func installObservers(for context: NSManagedObjectContext) {
        // ObjectsDidChange covers edits, pending deletes, undo and merged background or iCloud writes;
        // DidSave covers a save that changes nothing visible in memory.
        observe(.NSManagedObjectContextObjectsDidChange, object: context)
        observe(.NSManagedObjectContextDidSave, object: context)
        observe(.NSCalendarDayChanged, object: nil)
        observe(.dimeStoreLoadStateChanged, object: nil)
        observe(.dimeStoreErased, object: nil)
    }

    private func observe(_ name: Notification.Name, object: AnyObject?) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: OperationQueue.main) { [weak self] _ in
            self?.scheduleReload()
        }
        observers.append(token)
    }

    private func scheduleReload() {
        // A fetch must never schedule the next fetch.
        if isFetching { return }

        // A hidden tab only remembers that it is out of date.
        guard isVisible else {
            isStale = true
            return
        }

        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // Drops every memoised snapshot and reads the shown period again. Period and selection stay.
    private func reload() {
        pendingReload?.cancel()
        pendingReload = nil
        guard let context else { return }

        let now = Date.now
        let freshRules = InsightsRules.current()
        if freshRules != rules {
            rules = freshRules
            let middle = period.start.addingTimeInterval(period.end.timeIntervalSince(period.start) / 2)
            period = InsightsPeriod.containing(min(middle, now), frame: frame, rules: freshRules)
            selectedBucket = nil
        }

        // A period that was "current" yesterday must not stay marked as current forever.
        if isCurrentPeriod, loadedDay != nil {
            let current = InsightsPeriod.containing(now, frame: frame, rules: rules)
            if current != period {
                period = current
                selectedBucket = nil
            }
        }

        loadedDay = rules.calendar.startOfDay(for: now)
        isStale = false
        cache.removeAll()
        trendCache.removeAll()

        isFetching = true
        earliest = InsightsAggregator.earliestDate(context: context)
        isFetching = false

        hasAnyData = earliest != nil
        if earliest == nil {
            // Erased data: do not reopen the old category screen when rows appear again.
            detailKey = nil
            selectedCategory = nil
            selectedBucket = nil
        }
        hasLoaded = true
        load()
    }

    private func load() {
        guard let context else { return }

        if let cached = cache[period] {
            snapshot = cached
        } else {
            isFetching = true
            let fresh = InsightsAggregator.snapshot(for: period, rules: rules, now: Date.now, context: context)
            isFetching = false
            if cache.count >= 12 { cache.removeAll() }
            cache[period] = fresh
            snapshot = fresh
        }
        rebuild()
    }

    // Everything the views read is derived here, once per snapshot or selection change.
    private func rebuild() {
        let now = Date.now
        let current = InsightsPeriod.containing(now, frame: frame, rules: rules)
        isCurrentPeriod = period == current
        canGoForward = period.start < current.start
        if let earliest {
            canGoBack = earliest < period.start
        } else {
            canGoBack = false
        }
        periodTitle = InsightsFormat.title(for: period, rules: rules, now: now)

        guard let snapshot else {
            page = InsightsPage()
            detail = nil
            return
        }

        if let bucket = selectedBucket, bucket >= snapshot.bucketStarts.count {
            selectedBucket = nil
        }

        let activeFlow: InsightsFlow = incomeTracking ? flow : .expense
        page = InsightsBuilder.page(snapshot: snapshot, flow: activeFlow, bucket: selectedBucket,
                                    category: selectedCategory, linear: linearScale, rules: rules)

        if let key = detailKey {
            detail = InsightsBuilder.detail(snapshot: snapshot, key: key, income: detailIncome,
                                            trend: trend(for: key, income: detailIncome, snapshot: snapshot),
                                            linear: linearScale, rules: rules)
        } else {
            detail = nil
        }
    }

    // The shown period and the five before it.
    private func trend(for key: InsightsCategoryKey, income: Bool, snapshot: InsightsSnapshot) -> [InsightsTrendBar] {
        var periods: [InsightsPeriod] = [period]
        for _ in 0 ..< 5 {
            if let first = periods.first {
                periods.insert(first.previous(rules), at: 0)
            }
        }

        let cacheKey = TrendKey(key: key, income: income, period: period)
        var totals = trendCache[cacheKey] ?? []
        if totals.count != periods.count, let context {
            isFetching = true
            totals = InsightsAggregator.categoryTotals(key: key, income: income, periods: periods,
                                                       cutoff: rules.startOfTomorrow(Date.now), context: context)
            isFetching = false
            if trendCache.count >= 24 { trendCache.removeAll() }
            trendCache[cacheKey] = totals
        }

        var bars: [InsightsTrendBar] = []
        for (index, item) in periods.enumerated() {
            bars.append(InsightsTrendBar(
                id: index,
                period: item,
                label: InsightsFormat.trendLabel(item, rules: rules),
                amount: index < totals.count ? totals[index] : 0,
                isCurrent: item == period
            ))
        }
        return bars
    }
}
