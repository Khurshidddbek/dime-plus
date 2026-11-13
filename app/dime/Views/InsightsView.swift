//
//  InsightsView.swift
//  xpenz
//
//  Created by Rafael Soh on 20/5/22.
//

import CoreData
import Foundation
import SwiftUI

// The Insights tab. State lives in InsightsModel, the pieces live in Views/Insights.
struct InsightsView: View {
    @Environment(\.managedObjectContext) private var moc
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = InsightsModel()

    @AppStorage("incomeTracking", store: UserDefaults.appGroup) private var incomeTracking: Bool = true
    @AppStorage("animated", store: UserDefaults.appGroup) private var animated: Bool = true
    @AppStorage("firstWeekday", store: UserDefaults.appGroup) private var firstWeekday: Int = 1
    @AppStorage("firstDayOfMonth", store: UserDefaults.appGroup) private var firstDayOfMonth: Int = 1

    @State private var showsAllRows = false

    private let previewCount = 5

    var body: some View {
        ZStack {
            Color.PrimaryBackground
                .ignoresSafeArea()

            if model.hasLoaded {
                if model.hasAnyData {
                    mainPage
                        .accessibilityHidden(model.detail != nil)

                    if let detail = model.detail {
                        InsightsCategoryDetailView(model: model, detail: detail, onOpen: open)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                } else {
                    emptyState
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            model.start(context: moc, incomeTracking: incomeTracking)
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshIfNeeded()
            }
        }
        .onChange(of: incomeTracking) { _, enabled in
            model.setIncomeTracking(enabled)
        }
        .onChange(of: firstWeekday) { _, _ in
            model.refreshIfNeeded()
        }
        .onChange(of: firstDayOfMonth) { _, _ in
            model.refreshIfNeeded()
        }
        .onChange(of: model.selectedCategory) { _, _ in
            showsAllRows = false
        }
        .onChange(of: model.selectedBucket) { _, _ in
            showsAllRows = false
        }
    }

    private var spring: Animation? {
        animated ? Animation.snappy : nil
    }

    // MARK: Page

    private var mainPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Insights")
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibility(addTraits: .isHeader)

                Spacer(minLength: 8)

                InsightsSegmentedControl(items: frameItems, selection: model.frame.storedValue, fillsWidth: false) { value in
                    withAnimation(spring) {
                        model.setFrame(ChartTimeFrame(storedValue: value))
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 14)
            .padding(.bottom, 2)

            InsightsPeriodNavigator(model: model)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        if incomeTracking {
                            InsightsSegmentedControl(items: flowItems, selection: model.page.flow.rawValue, fillsWidth: true) { value in
                                withAnimation(spring) {
                                    model.setFlow(InsightsFlow(rawValue: value) ?? .expense)
                                }
                            }
                            .padding(.horizontal, 30)
                        }

                        InsightsHeadlineCard(page: model.page) {
                            withAnimation(spring) {
                                model.clearSelection()
                            }
                        }
                        .padding(.horizontal, 30)
                        // No swipe-to-change-period here: any drag recognizer in this ScrollView
                        // blocked page scrolling on device. The arrows above change the period.

                        if model.page.periodIsEmpty {
                            InsightsEmptyPeriodView()
                                .padding(.horizontal, 30)
                        } else {
                            chartSection
                                .padding(.horizontal, 30)

                            if model.page.flow == .net {
                                netSection
                                    .padding(.horizontal, 30)
                            } else if !model.page.slices.isEmpty {
                                categorySection(proxy)
                                    .padding(.horizontal, 18)
                            }

                            if model.page.hasSelection {
                                selectionSection
                                    .padding(.horizontal, 18)
                            } else {
                                highlightsSection
                                    .padding(.horizontal, 18)
                            }
                        }
                    }
                    .padding(.top, 6)
                    // Clears the floating tab bar.
                    .padding(.bottom, 110)
                }
            }
        }
    }

    private var frameItems: [InsightsSegmentItem] {
        [
            InsightsSegmentItem(id: ChartTimeFrame.week.storedValue, title: "Week"),
            InsightsSegmentItem(id: ChartTimeFrame.month.storedValue, title: "Month"),
            InsightsSegmentItem(id: ChartTimeFrame.year.storedValue, title: "Year")
        ]
    }

    private var flowItems: [InsightsSegmentItem] {
        [
            InsightsSegmentItem(id: InsightsFlow.expense.rawValue, title: "Expenses"),
            InsightsSegmentItem(id: InsightsFlow.income.rawValue, title: "Income"),
            InsightsSegmentItem(id: InsightsFlow.net.rawValue, title: "Net")
        ]
    }

    // MARK: Sections

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InsightsTrendChart(
                data: model.page.chart,
                selected: model.selectedBucket,
                tint: model.page.tint ?? Color.DarkBackground,
                signed: model.page.flow == .net,
                averageTitle: model.page.frame == .year ? "Average per month" : "Average per day",
                onSelect: { index in
                    model.selectBucket(index)
                },
                onToggleScale: {
                    withAnimation(spring) {
                        model.toggleScale()
                    }
                }
            )

            if model.page.frame == .year, model.selectedBucket != nil, let title = model.page.scopeDetail {
                InsightsWideButton(title: "Open \(title)") {
                    withAnimation(spring) {
                        model.openSelectedBucketAsMonth()
                    }
                }
            }
        }
    }

    private var netSection: some View {
        VStack(spacing: 8) {
            InsightsSummaryBlockView(income: true, amount: model.page.income, showOverlay: false) {
                withAnimation(spring) {
                    model.setFlow(.income)
                }
            }

            InsightsSummaryBlockView(income: false, amount: model.page.expense, showOverlay: false) {
                withAnimation(spring) {
                    model.setFlow(.expense)
                }
            }
        }
    }

    private func categorySection(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InsightsSectionHeader(title: "Categories")
                .padding(.horizontal, 12)

            InsightsShareBar(segments: model.page.segments, selected: model.selectedCategory) { segment in
                if let key = segment.key {
                    withAnimation(spring) {
                        model.selectCategory(key)
                    }
                } else if let first = segment.firstMergedKey {
                    // "Other": show where the merged categories start.
                    Haptics.tap()
                    withAnimation {
                        proxy.scrollTo(first, anchor: .center)
                    }
                }
            }
            .padding(.horizontal, 12)

            VStack(spacing: 2) {
                ForEach(model.page.slices) { slice in
                    InsightsCategoryRow(
                        slice: slice,
                        isSelected: model.selectedCategory == slice.id,
                        isDimmed: model.selectedCategory != nil && model.selectedCategory != slice.id
                    ) {
                        withAnimation(spring) {
                            // First tap focuses the page on the category, the second opens its screen.
                            if model.selectedCategory == slice.id {
                                model.openDetail(slice.id)
                            } else {
                                model.selectCategory(slice.id)
                            }
                        }
                    }
                    .id(slice.id)

                    if model.selectedCategory == slice.id {
                        InsightsWideButton(title: "Details and transactions") {
                            withAnimation(spring) {
                                model.openDetail(slice.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }

    // Transactions behind the selected day and / or category.
    private var selectionSection: some View {
        let rows = model.page.rows
        let shown = showsAllRows ? rows : Array(rows.prefix(previewCount))

        return VStack(alignment: .leading, spacing: 2) {
            InsightsSectionHeader(title: "Transactions")
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            if rows.isEmpty {
                InsightsEmptyPeriodView()
            }

            LazyVStack(spacing: 0) {
                ForEach(shown) { row in
                    InsightsTransactionRow(row: row, info: model.page.info(for: row.category),
                                           showsDay: model.selectedBucket == nil || model.page.frame == .year) {
                        open(row)
                    }
                }
            }

            if rows.count > shown.count {
                InsightsWideButton(title: "Show all") {
                    Haptics.tap()
                    showsAllRows = true
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.page.biggest.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    InsightsSectionHeader(title: "Largest transactions")
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)

                    ForEach(model.page.biggest) { row in
                        InsightsTransactionRow(row: row, info: model.page.info(for: row.category), showsDay: true) {
                            open(row)
                        }
                    }
                }
            }

            if !model.page.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    InsightsSectionHeader(title: "Top notes")
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)

                    ForEach(model.page.notes) { note in
                        InsightsNoteRow(note: note, colour: Color.DarkBackground, isSelected: false, action: nil)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image("chart")
                .resizable()
                .frame(width: 75, height: 75)
                .padding(.bottom, 20)

            Text("Analyse Your Expenditure")
                .font(.system(.title2, design: .rounded).weight(.medium))
                .foregroundColor(Color.PrimaryText.opacity(0.8))
                .multilineTextAlignment(.center)

            Text("As transactions start piling up")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 30)
        .frame(height: 250, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    // The editor is the full screen cover HomeView already owns.
    private func open(_ row: InsightsRow) {
        guard let transaction = (try? moc.existingObject(with: row.id)) as? Transaction else {
            Haptics.warning()
            return
        }
        Haptics.tap()
        // Set on the shared manager directly: observing it here would redraw the tab on every row tap in the Log.
        OverallTransactionManager.shared.toEdit = transaction
    }
}
