//
//  InsightsBuilder.swift
//  dime
//

import Foundation
import SwiftUI

// MARK: Derived values the views draw

struct InsightsComparison {
    let current: Double
    let previous: Double
    let label: String

    // nil when there is nothing to compare with.
    var fraction: Double? {
        guard abs(previous) > 0.000001 else { return nil }
        return (current - previous) / abs(previous)
    }
}

enum InsightsAverageKind {
    case perDay
    case perMonth
    case perTransaction
}

struct InsightsSlice: Identifiable {
    let id: InsightsCategoryKey
    let name: String
    let emoji: String
    let colour: Color
    let amount: Double
    let count: Int
    let share: Double // of the total, 0...1
    let relative: Double // to the largest slice, 0...1
}

struct InsightsShareSegment: Identifiable {
    let id: Int
    let key: InsightsCategoryKey? // nil for "Other"
    let firstMergedKey: InsightsCategoryKey? // where "Other" starts in the list
    let name: String
    let emoji: String
    let colour: Color
    let share: Double
}

struct InsightsNoteStat: Identifiable {
    let id: String // normalised note
    let title: String
    let amount: Double
    let count: Int
    let relative: Double // to the largest note, 0...1
}

struct InsightsChartBar: Identifiable {
    let id: Int
    let label: String
    let title: String
    let value: Double
    let isFuture: Bool
}

struct InsightsChartData {
    var bars: [InsightsChartBar] = []
    var top: Double = 1 // value at the top edge
    var bottom: Double = 0 // magnitude below zero, net only
    var ticks: [Double] = []
    var average: Double?
    var cappedAt: Double? // set while outlier bars are clipped
    var canCap = false
}

struct InsightsTrendBar: Identifiable {
    let id: Int
    let period: InsightsPeriod
    let label: String
    let amount: Double
    let isCurrent: Bool
}

struct InsightsPage {
    var flow: InsightsFlow = .expense
    var frame: ChartTimeFrame = .week
    var scopeTitle = ""
    var scopeDetail: String?
    var hasSelection = false
    var periodIsEmpty = true
    var total: Double = 0
    var income: Double = 0
    var expense: Double = 0
    var count = 0
    var largest: Double = 0
    var average: Double = 0
    var averageKind: InsightsAverageKind = .perDay
    var comparison: InsightsComparison?
    var chart = InsightsChartData()
    var tint: Color?
    var slices: [InsightsSlice] = []
    var segments: [InsightsShareSegment] = []
    var rows: [InsightsRow] = []
    var biggest: [InsightsRow] = []
    var notes: [InsightsNoteStat] = []
    var categories: [InsightsCategoryKey: InsightsCategoryInfo] = [:]

    func info(for key: InsightsCategoryKey) -> InsightsCategoryInfo {
        categories[key] ?? InsightsCategoryInfo.uncategorised
    }
}

struct InsightsCategoryDetail {
    let key: InsightsCategoryKey
    let income: Bool
    let name: String
    let emoji: String
    let colour: Color
    var frame: ChartTimeFrame = .week
    var total: Double = 0
    var share: Double = 0
    var count = 0
    var average: Double = 0
    var largest: Double = 0
    var perUnit: Double = 0
    var comparison: InsightsComparison?
    var chart = InsightsChartData()
    var trend: [InsightsTrendBar] = []
    var notes: [InsightsNoteStat] = []
    var rows: [InsightsRow] = []
}

// MARK: Pure derivations, run once per snapshot or selection change

enum InsightsBuilder {
    private struct Tally {
        var amount: Double = 0
        var count = 0
        var title = ""
    }

    static func page(snapshot: InsightsSnapshot, flow: InsightsFlow, bucket: Int?, category: InsightsCategoryKey?,
                     linear: Bool, rules: InsightsRules) -> InsightsPage {
        var page = InsightsPage()
        page.flow = flow
        page.frame = snapshot.period.frame
        page.categories = snapshot.categories
        page.hasSelection = bucket != nil || category != nil

        let flowRows = rows(snapshot.rows, flow: flow)
        // Per flow: a month with only a salary has nothing to show under Expenses.
        page.periodIsEmpty = flowRows.isEmpty
        var bucketRows = flowRows
        if let bucket {
            bucketRows = flowRows.filter { $0.bucket == bucket }
        }
        var scopeRows = bucketRows
        if let category {
            scopeRows = bucketRows.filter { $0.category == category }
        }

        for row in scopeRows {
            if row.income {
                page.income += row.amount
            } else {
                page.expense += row.amount
            }
            page.largest = max(page.largest, row.amount)
        }
        page.total = total(income: page.income, expense: page.expense, flow: flow)
        page.count = scopeRows.count

        if bucket != nil {
            page.averageKind = .perTransaction
            page.average = scopeRows.isEmpty ? 0 : page.total / Double(scopeRows.count)
        } else if snapshot.period.frame == .year {
            page.averageKind = .perMonth
            page.average = page.total / Double(max(1, snapshot.elapsedBuckets))
        } else {
            page.averageKind = .perDay
            page.average = page.total / Double(max(1, snapshot.elapsedDays))
        }

        if let category {
            let info = page.info(for: category)
            page.scopeTitle = info.name
            page.tint = info.colour
        } else {
            page.scopeTitle = InsightsFormat.flowTitle(flow)
        }
        if let bucket, bucket < snapshot.bucketStarts.count {
            page.scopeDetail = InsightsFormat.bucketTitle(snapshot.bucketStarts[bucket], frame: snapshot.period.frame)
        }

        if bucket == nil {
            var previous = rows(snapshot.previousRows, flow: flow)
            if let category {
                previous = previous.filter { $0.category == category }
            }
            var previousIncome: Double = 0
            var previousExpense: Double = 0
            for row in previous {
                if row.income {
                    previousIncome += row.amount
                } else {
                    previousExpense += row.amount
                }
            }
            page.comparison = InsightsComparison(
                current: page.total,
                previous: total(income: previousIncome, expense: previousExpense, flow: flow),
                label: InsightsFormat.comparisonLabel(snapshot, rules: rules)
            )
        }

        // Chart: the whole period, narrowed to the selected category.
        var values = [Double](repeating: 0, count: snapshot.bucketStarts.count)
        if category == nil {
            for index in values.indices {
                values[index] = total(income: snapshot.incomeByBucket[index], expense: snapshot.expenseByBucket[index], flow: flow)
            }
        } else {
            for row in flowRows where row.category == category && row.bucket < values.count {
                values[row.bucket] += (flow == .net && !row.income) ? -row.amount : row.amount
            }
        }
        page.chart = chart(values: values, snapshot: snapshot, signed: flow == .net, linear: linear)

        if flow != .net {
            page.slices = slices(bucketRows, categories: snapshot.categories)
            page.segments = segments(page.slices)
        }

        if page.hasSelection {
            page.rows = scopeRows
        } else if flow != .net {
            page.biggest = Array(flowRows.sorted { $0.amount > $1.amount }.prefix(5))
            page.notes = notes(flowRows, limit: 5)
        }

        return page
    }

    static func detail(snapshot: InsightsSnapshot, key: InsightsCategoryKey, income: Bool, trend: [InsightsTrendBar],
                       linear: Bool, rules: InsightsRules) -> InsightsCategoryDetail {
        let info = snapshot.categories[key] ?? InsightsCategoryInfo.uncategorised
        var detail = InsightsCategoryDetail(key: key, income: income, name: info.name, emoji: info.emoji, colour: info.colour)
        detail.frame = snapshot.period.frame
        detail.trend = trend

        var flowTotal: Double = 0
        var rows: [InsightsRow] = []
        for row in snapshot.rows where row.income == income {
            flowTotal += row.amount
            if row.category == key {
                rows.append(row)
                detail.total += row.amount
                detail.largest = max(detail.largest, row.amount)
            }
        }
        detail.rows = rows
        detail.count = rows.count
        detail.share = flowTotal > 0 ? detail.total / flowTotal : 0
        detail.average = rows.isEmpty ? 0 : detail.total / Double(rows.count)
        let divisor = snapshot.period.frame == .year ? snapshot.elapsedBuckets : snapshot.elapsedDays
        detail.perUnit = detail.total / Double(max(1, divisor))

        var previous: Double = 0
        for row in snapshot.previousRows where row.income == income && row.category == key {
            previous += row.amount
        }
        detail.comparison = InsightsComparison(current: detail.total, previous: previous,
                                               label: InsightsFormat.comparisonLabel(snapshot, rules: rules))

        var values = [Double](repeating: 0, count: snapshot.bucketStarts.count)
        for row in rows where row.bucket < values.count {
            values[row.bucket] += row.amount
        }
        detail.chart = chart(values: values, snapshot: snapshot, signed: false, linear: linear)
        detail.notes = notes(rows, limit: 6)

        return detail
    }

    // MARK: Pieces

    private static func rows(_ rows: [InsightsRow], flow: InsightsFlow) -> [InsightsRow] {
        switch flow {
        case .net: return rows
        case .income: return rows.filter { $0.income }
        case .expense: return rows.filter { !$0.income }
        }
    }

    private static func total(income: Double, expense: Double, flow: InsightsFlow) -> Double {
        switch flow {
        case .net: return income - expense
        case .income: return income
        case .expense: return expense
        }
    }

    private static func slices(_ rows: [InsightsRow], categories: [InsightsCategoryKey: InsightsCategoryInfo]) -> [InsightsSlice] {
        var tallies: [InsightsCategoryKey: Tally] = [:]
        var total: Double = 0
        for row in rows {
            // A category that no longer exists is shown as "No category" instead of being dropped.
            let key = categories[row.category] == nil ? InsightsCategoryKey.uncategorised : row.category
            var tally = tallies[key] ?? Tally()
            tally.amount += row.amount
            tally.count += 1
            tallies[key] = tally
            total += row.amount
        }

        let largest = tallies.values.map { $0.amount }.max() ?? 0
        var result: [InsightsSlice] = []
        for (key, tally) in tallies {
            let info = categories[key] ?? InsightsCategoryInfo.uncategorised
            result.append(InsightsSlice(
                id: key,
                name: info.name,
                emoji: info.emoji,
                colour: info.colour,
                amount: tally.amount,
                count: tally.count,
                share: total > 0 ? tally.amount / total : 0,
                relative: largest > 0 ? tally.amount / largest : 0
            ))
        }

        result.sort { first, second in
            if first.amount != second.amount { return first.amount > second.amount }
            return first.name < second.name
        }
        return result
    }

    // Top 6 on their own, the rest merged into "Other". Small ones stay tappable through the minimum width.
    private static func segments(_ slices: [InsightsSlice]) -> [InsightsShareSegment] {
        let visible = slices.filter { $0.share > 0 }
        guard !visible.isEmpty else { return [] }

        let limit = 6
        let headCount = visible.count == limit + 1 ? limit + 1 : min(limit, visible.count)
        var result: [InsightsShareSegment] = []
        for index in 0 ..< headCount {
            let slice = visible[index]
            result.append(InsightsShareSegment(id: index, key: slice.id, firstMergedKey: nil, name: slice.name,
                                               emoji: slice.emoji, colour: slice.colour, share: slice.share))
        }

        if visible.count > headCount {
            var share: Double = 0
            for index in headCount ..< visible.count {
                share += visible[index].share
            }
            result.append(InsightsShareSegment(id: headCount, key: nil, firstMergedKey: visible[headCount].id,
                                               name: String(localized: "Other"), emoji: "",
                                               colour: Color(hex: "#B4B4BC"), share: share))
        }
        return result
    }

    private static func notes(_ rows: [InsightsRow], limit: Int) -> [InsightsNoteStat] {
        var tallies: [String: Tally] = [:]
        for row in rows {
            let trimmed = row.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let key = trimmed.lowercased()
            var tally = tallies[key] ?? Tally()
            if tally.count == 0 { tally.title = trimmed }
            tally.amount += row.amount
            tally.count += 1
            tallies[key] = tally
        }

        let sorted = tallies.sorted { first, second in
            if first.value.amount != second.value.amount { return first.value.amount > second.value.amount }
            return first.key < second.key
        }
        let largest = sorted.first?.value.amount ?? 0
        var result: [InsightsNoteStat] = []
        for entry in sorted.prefix(limit) {
            result.append(InsightsNoteStat(id: entry.key, title: entry.value.title, amount: entry.value.amount,
                                           count: entry.value.count,
                                           relative: largest > 0 ? entry.value.amount / largest : 0))
        }
        return result
    }

    static func noteKey(_ note: String) -> String {
        note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Chart scale

    private static func chart(values: [Double], snapshot: InsightsSnapshot, signed: Bool, linear: Bool) -> InsightsChartData {
        var data = InsightsChartData()
        let frame = snapshot.period.frame

        var elapsedSum: Double = 0
        for (index, value) in values.enumerated() where index < snapshot.bucketStarts.count {
            let start = snapshot.bucketStarts[index]
            let isFuture = start >= snapshot.cutoff
            if !isFuture { elapsedSum += value }
            data.bars.append(InsightsChartBar(
                id: index,
                label: InsightsFormat.bucketLabel(start, frame: frame, index: index),
                title: InsightsFormat.bucketTitle(start, frame: frame),
                value: value,
                isFuture: isFuture
            ))
        }

        let highest = max(values.max() ?? 0, 0)
        let lowest = min(values.min() ?? 0, 0)

        if signed {
            data.top = highest > 0 ? niceCeil(highest) : 0
            data.bottom = lowest < 0 ? niceCeil(-lowest) : 0
            if data.top == 0, data.bottom == 0 { data.top = 1 }
            var ticks: [Double] = [0]
            if data.top > 0 { ticks.insert(data.top, at: 0) }
            if data.bottom > 0 { ticks.append(-data.bottom) }
            data.ticks = ticks
            return data
        }

        data.average = elapsedSum / Double(max(1, snapshot.elapsedBuckets))

        // One rent-sized day must not flatten every other bar: clip it and mark it instead.
        var top = highest
        let nonZero = values.filter { $0 > 0 }.sorted()
        if nonZero.count >= 4 {
            let p90 = nonZero[Int(Double(nonZero.count - 1) * 0.9)]
            let median = nonZero[nonZero.count / 2]
            let cap = max(p90 * 1.6, median * 4)
            if cap > 0, highest > cap * 1.5 {
                data.canCap = true
                if !linear {
                    top = cap
                }
            }
        }

        data.top = top > 0 ? niceCeil(top) : 1
        if data.canCap, !linear, highest > data.top {
            data.cappedAt = data.top
        }
        // Nothing to scale: only the baseline, not a made-up "1" at the top.
        data.ticks = highest > 0 ? [data.top, data.top / 2, 0] : [0]
        return data
    }

    // Rounds up to a value whose half is still a short axis label.
    static func niceCeil(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let base = pow(10, floor(log10(value)))
        let fraction = value / base
        let steps: [Double] = [1, 1.5, 2, 3, 4, 5, 6, 8, 10]
        for step in steps where fraction <= step + 0.000001 {
            return step * base
        }
        return 10 * base
    }
}
