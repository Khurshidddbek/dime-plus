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
        animated ? Animation.snappy(duration: 0.3) : nil
    }

    // MARK: Page
    //
    // Fixed header: title with the week / month / year menu, then the period with its arrows.
    // Scrolling content: hero (flow switch, total, change, two stats), chart, categories, and the
    // transactions of the current selection.

    private var mainPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Insights")
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibility(addTraits: .isHeader)

                Spacer(minLength: 8)

                InsightsScopeMenu(model: model)
            }
            .padding(.horizontal, 30)
            .padding(.top, 14)

            InsightsPeriodNavigator(model: model)
                .padding(.leading, 30)
                .padding(.trailing, 20)
                .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        InsightsHeadlineCard(
                            page: model.page,
                            showsFlowSwitch: incomeTracking,
                            onFlow: { flow in
                                withAnimation(spring) {
                                    model.setFlow(flow)
                                }
                            },
                            onClear: {
                                withAnimation(spring) {
                                    model.clearSelection()
                                }
                            }
                        )
                        .padding(.horizontal, 30)
                        // No swipe-to-change-period here: any drag recognizer in this ScrollView
                        // blocked page scrolling on device. The arrows above change the period.

                        if model.page.periodIsEmpty {
                            InsightsEmptyPeriodView(onBackToToday: backToToday)
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
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(.top, 8)
                    // Clears the floating tab bar.
                    .padding(.bottom, 110)
                }
            }
        }
    }

    private var backToToday: (() -> Void)? {
        if model.isCurrentPeriod { return nil }
        let animation = spring
        let target = model
        return {
            withAnimation(animation) {
                target.goToCurrent()
            }
        }
    }

    // MARK: Sections

    private var chartSection: some View {
        InsightsTrendChart(
            data: model.page.chart,
            selected: model.selectedBucket,
            tint: model.page.tint ?? Color.DarkBackground,
            signed: model.page.flow == .net,
            averageTitle: model.page.frame == .year ? "Average per month" : "Average per day",
            onSelect: { index in
                withAnimation(spring) {
                    model.selectBucket(index)
                }
            },
            onOpenSelected: openSelectedMonth
        )
    }

    // Year view only: the callout of a selected month opens that month.
    private var openSelectedMonth: (() -> Void)? {
        guard model.page.frame == .year else { return nil }
        let animation = spring
        let target = model
        return {
            withAnimation(animation) {
                target.openSelectedBucketAsMonth()
            }
        }
    }

    private var netSection: some View {
        HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 4) {
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
                    withAnimation(spring) {
                        proxy.scrollTo(first, anchor: .center)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            VStack(spacing: 2) {
                ForEach(model.page.slices) { slice in
                    InsightsCategoryRow(
                        slice: slice,
                        isSelected: model.selectedCategory == slice.id,
                        isDimmed: model.selectedCategory != nil && model.selectedCategory != slice.id,
                        action: {
                            withAnimation(spring) {
                                // First tap focuses the page on the category, the second opens its screen.
                                if model.selectedCategory == slice.id {
                                    model.openDetail(slice.id)
                                } else {
                                    model.selectCategory(slice.id)
                                }
                            }
                        },
                        onOpen: {
                            withAnimation(spring) {
                                model.openDetail(slice.id)
                            }
                        }
                    )
                    .id(slice.id)
                }
            }
        }
    }

    // Transactions behind the selected day and / or category.
    private var selectionSection: some View {
        let rows = model.page.rows
        let shown = showsAllRows ? rows : Array(rows.prefix(previewCount))

        return VStack(alignment: .leading, spacing: 2) {
            InsightsSectionHeader(title: "Transactions", trailing: String(rows.count))
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
                    withAnimation(spring) {
                        showsAllRows = true
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
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
