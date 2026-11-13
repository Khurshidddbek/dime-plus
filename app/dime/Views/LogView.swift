//
//  LogView.swift
//  xpenz
//
//  Created by Rafael Soh on 19/5/22.
//

import CoreData
import Foundation
import Popovers
import SwiftUI

struct LogView: View {
    @EnvironmentObject var dataController: DataController

    // Count only. The rows live in LogFeed and are observed by the list itself,
    // so this screen is not rebuilt when a transaction changes.
    @ObservedObject var stats = LogFeed.shared.stats

    var topEdge: CGFloat

    // searching
    @State var searchMode = false

    // show filter menu
    @State var showFilter = false
    @State var filter = FilterType.all

    // filters
    @State var categoryFilter: Category?
    @State var dateFilter = Date.now
    @State var weekFilter = Date.now
    @State var monthFilter = Date.now
    @State var income = false

    // to show/hide tab bar
    var bottomEdge: CGFloat

    // Bank SMS waiting for review and the clipboard chip. Zero height when there is nothing
    // to show. It sits at the top of the Log, also while the Log is empty.
    @ViewBuilder
    var smsInboxEntry: some View {
        SMSInboxEntryCard()
    }

    var body: some View {
        Group {
            if stats.count == 0 {
                emptyLog
            } else {
                logContent
            }
        }
        .background(Color.PrimaryBackground)
        .fullScreenCover(isPresented: $searchMode) {
            SearchView()
        }
        // Recurring entries are generated on every launch and every return to the app,
        // whatever the iCloud state is. The call is cheap when nothing is due.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            dataController.updateRecurringTransactions()
        }
        .onAppear {
            dataController.updateRecurringTransactions()
        }
        .onOpenURL { url in
            guard url.host == "search" else {
                return
            }

            searchMode = true
        }
    }

    var emptyLog: some View {
        VStack(spacing: 0) {
            smsInboxEntry
                .padding(.top, topEdge + 10)

            VStack(spacing: 5) {
                Image("dropbox")
                    .resizable()
                    .frame(width: 75, height: 75)
                    .padding(.bottom, 20)
                    .accessibility(hidden: true)

                Text("Your Log is Empty")
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.PrimaryText.opacity(0.8))

                Text("Press the plus button\nto add your first entry")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.SubtitleText.opacity(0.7))
            }
            .padding(.horizontal, 30)
            .frame(height: 250, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var logContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                HStack {
                    Button {
                        Haptics.tap()
                        searchMode = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(.title2, design: .rounded).weight(.regular))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .foregroundColor(Color.DarkIcon)
                            .padding(5)
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Search")

                    Spacer()

                    switch filter {
                    case .all:
                        EmptyView()
                    case .category:
                        filterTagView(text: "filter-tag-category")
                    case .day:
                        filterTagView(text: "filter-tag-day")
                    case .week:
                        filterTagView(text: "filter-tag-week")
                    case .month:
                        filterTagView(text: "filter-tag-month")
                    case .recurring:
                        filterTagView(text: "filter-tag-recurring")
                    case .type:
                        filterTagView(text: "filter-tag-type")
                    case .upcoming:
                        filterTagView(text: "filter-tag-upcoming")
                    }

                    Spacer()

                    Button {
                        Haptics.tap()
                        showFilter = true
                    } label: {
                        Image(systemName: filter == .all ? "triangle" : "triangle.tophalf.filled")
                            .font(.system(.title2, design: .rounded).weight(.regular))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .foregroundColor(Color.DarkIcon)
                            .rotationEffect(Angle(degrees: 180))
                            .padding(5)
                            .background {
                                if showFilter {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.SecondaryBackground)
                                }
                            }
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Filter")
                    .popover(present: $showFilter, attributes: {
                        $0.position = .absolute(
                            originAnchor: .bottomRight,
                            popoverAnchor: .topRight
                        )
                        $0.rubberBandingMode = .none
                        $0.sourceFrameInset = UIEdgeInsets(top: 0, left: 0, bottom: -10, right: 0)
                        $0.presentation.animation = .easeInOut(duration: 0.2)
                        $0.dismissal.animation = .easeInOut(duration: 0.3)
                    }) {
                        FilterPickerView(filterType: $filter, showMenu: $showFilter)
                    }
                }

                switch filter {
                case .all:
                    EmptyView()
                case .category:
                    CategoryStepperView(categoryFilter: $categoryFilter)
                case .day:
                    DateStepperView(date: $dateFilter)
                case .week:
                    WeekStepperView(showingDate: $weekFilter)
                case .month:
                    MonthStepperView(showingDate: $monthFilter)
                case .recurring:
                    EmptyView()
                case .type:
                    IncomeFilterToggleView(income: $income)
                case .upcoming:
                    EmptyView()
                }
            }
            .padding(.horizontal, 25)
            .frame(height: (filter == .all || filter == .recurring || filter == .upcoming) ? 50 : 110, alignment: .top)
            .padding(.top, topEdge + 10)

            ScrollView(showsIndicators: false) {
                if filter == .all {
                    smsInboxEntry

                    LogInsightsView()
                }

                TransactionsList(filter: $filter, category: categoryFilter, date: dateFilter, week: weekFilter, month: monthFilter, income: income)
                    .zIndex(0)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 70 + bottomEdge)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func filterTagView(text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(.body, design: .rounded).weight(.medium))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

            Button {
                Haptics.tap()

                withAnimation(.easeIn(duration: 0.15)) {
                    filter = .all
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(.caption, design: .rounded).weight(.regular))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundColor(Color.PrimaryText.opacity(0.7))
                    .frame(minWidth: 30, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("remove filter")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .foregroundColor(Color.PrimaryText)
    }
}

/// The big number above the list. Totals come from the rows LogFeed already holds:
/// one pass in memory, cached until the next change, nothing fetched in body.
struct LogInsightsView: View {
    @ObservedObject var feed = LogFeed.shared

    @State var showMenu1 = false
    let subtitleText = ["today", "this week", "this month", "this year", "all time"]

    @AppStorage("logInsightsTimeFrame", store: UserDefaults.appGroup) var timeframe = 2
    @AppStorage("logInsightsType", store: UserDefaults.appGroup) var insightsType = 1

    @AppStorage("logViewLineGraph", store: UserDefaults.appGroup) var lineGraph: Bool = false

    var range: Int {
        var calendar = Calendar(identifier: .gregorian)

        calendar.firstWeekday = UserDefaults.appGroup.integer(forKey: "firstWeekday")
        calendar.minimumDaysInFirstWeek = 4

        if timeframe == 3 {
            let dateComponents = calendar.dateComponents([.month, .year], from: Date.now)

            let thisMonth = calendar.date(from: dateComponents) ?? Date.now
            let numberOfDays = calendar.dateComponents([.day], from: thisMonth, to: Date.now)

            return (numberOfDays.day ?? 0) + 1
        } else if timeframe == 4 {
            let dateComponents = calendar.dateComponents([.year], from: Date.now)

            let thisYear = calendar.date(from: dateComponents) ?? Date.now

            let numberOfMonths = calendar.dateComponents([.month], from: thisYear, to: Date.now)

            return (numberOfMonths.month ?? 0) + 1
        } else {
            let dateComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: Date.now)
            let thisWeek = calendar.date(from: dateComponents) ?? Date.now
            let numberOfDays = calendar.dateComponents([.day], from: thisWeek, to: Date.now)

            return (numberOfDays.day ?? 0) + 1
        }
    }

    var headingText: String {
        if insightsType == 1 {
            return "Net total"
        } else if insightsType == 2 {
            return "Earned"
        } else {
            return "Spent"
        }
    }

    var body: some View {
        let totals = feed.totals(timeframe: timeframe)
        let amount = insightsType == 1 ? totals.net : (insightsType == 2 ? totals.income : totals.spent)
        let timeframeTitle = subtitleText[min(max(timeframe, 1), subtitleText.count) - 1]

        VStack(spacing: -3) {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(headingText))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(Color.PrimaryText.opacity(0.9))
                    Button {
                        Haptics.tap()
                        showMenu1 = true
                    } label: {
                        Text(LocalizedStringKey(timeframeTitle))
                            .padding(2)
                            .padding(.horizontal, 6)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundColor(Color.PrimaryText.opacity(9))
                            .overlay(Capsule().stroke(Color.Outline, lineWidth: 1.3))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .popover(present: $showMenu1, attributes: {
                        $0.position = .absolute(
                            originAnchor: .bottom,
                            popoverAnchor: .top
                        )
                        $0.rubberBandingMode = .none
                        $0.sourceFrameInset = UIEdgeInsets(top: 0, left: 0, bottom: -10, right: 0)
                        $0.presentation.animation = .easeInOut(duration: 0.2)
                        $0.dismissal.animation = .easeInOut(duration: 0.3)
                    }) {
                        TimePickerView(showMenu: $showMenu1, timeframe: $timeframe)
                    }
                }

                // Grouped and never cut: the full value shrinks instead of going compact.
                AmountText(amount, role: .hero, sign: insightsType == 1 ? .always : .never, fit: .fullOnly, animated: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 7)
            .contentShape(Rectangle())
            .contextMenu {
                if insightsType != 3 {
                    Button {
                        insightsType = 3
                    } label: {
                        Label("Total Spent", systemImage: "minus")
                    }
                }

                if insightsType != 2 {
                    Button {
                        insightsType = 2
                    } label: {
                        Label("Total Income", systemImage: "plus")
                    }
                }

                if insightsType != 1 {
                    Button {
                        insightsType = 1
                    } label: {
                        Label("Net Total", systemImage: "alternatingcurrent")
                    }
                }

                Button {
                    LogActions.copyAmount(amount)
                } label: {
                    Label("Copy amount", systemImage: "doc.on.doc")
                }
            }

            if totals.spent != 0 && totals.income != 0 && insightsType == 1 {
                HStack {
                    AmountText(totals.income, size: 20, relativeTo: .title2, sign: .plus, fit: .fullOnly, color: Color.IncomeGreen)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    DottedLine()
                        .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                        .frame(width: 1.7, height: 15)
                        .foregroundColor(Color.Outline)

                    AmountText(totals.spent, size: 20, relativeTo: .title2, sign: .minus, fit: .fullOnly, color: Color.AlertRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 13)
            }

            if lineGraph {
                let lineGraphData = feed.lineGraph(insightsType: insightsType, timeframe: timeframe)

                LineGraph(data: lineGraphData, green: isGreen(lineGraphData), type: timeframe, range: range)
                    .frame(height: 25)
                    .padding(.horizontal, 60)
                    .padding(.top, 16)
            }
        }
        .padding([.bottom, .horizontal], 20)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(height: lineGraph ? 240 : 170)
    }

    func isGreen(_ data: [LineGraphDataPoint]) -> Bool {
        if insightsType == 1 {
            return (data.first?.amount ?? 0.0) < (data.last?.amount ?? 0.0)
        }

        return insightsType == 2
    }
}

struct TimePickerView: View {
    @Namespace var animation

    let timeframes = ["today", "this week", "this month", "this year", "all time"]

    @Binding var showMenu: Bool
    @Binding var timeframe: Int
    @State var holdingTimeframe = 0

    @AppStorage("colourScheme", store: UserDefaults.appGroup) var colourScheme: Int = 0

    @Environment(\.colorScheme) var systemColorScheme

    var darkMode: Bool {
        (colourScheme == 0 && systemColorScheme == .dark) || colourScheme == 2
    }

    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(timeframes.indices, id: \.self) { index in
                HStack {
                    Text(LocalizedStringKey(timeframes[index]))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)

                    Spacer()

                    if holdingTimeframe == index + 1 {
                        Image(systemName: "checkmark")
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
//                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
//                .font(.system(size: 18, weight: .medium, design: .rounded))
                .padding(5)
                .background {
                    if holdingTimeframe == index + 1 {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(darkMode ? Color("AlwaysDarkSecondaryBackground") : Color("AlwaysLightSecondaryBackground"))
                            .matchedGeometryEffect(id: "TAB", in: animation)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if holdingTimeframe == index + 1 {
                        showMenu = false
                    } else {
                        Haptics.selection()

                        withAnimation(.easeIn(duration: 0.15)) {
                            holdingTimeframe = index + 1
                        }

                        timeframe = index + 1

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            showMenu = false
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
            }
        }
        .foregroundColor(darkMode ? Color("AlwaysLightBackground") : Color("AlwaysDarkBackground"))
        .padding(4)
        .frame(width: dynamicTypeSize > .xxLarge ? 185 : 160)
        .background(RoundedRectangle(cornerRadius: 9).fill(darkMode ? Color("AlwaysDarkBackground") : Color("AlwaysLightBackground")).shadow(color: darkMode ? Color.clear : Color.gray.opacity(0.25), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(darkMode ? Color.gray.opacity(0.1) : Color.clear, lineWidth: 1.3))
        .onAppear {
            holdingTimeframe = timeframe
        }
    }
}

struct FilterPickerView: View {
    @Namespace var animation
    @Namespace var animation1
    @Binding var filterType: FilterType
    @Binding var showMenu: Bool

    @AppStorage("colourScheme", store: UserDefaults.appGroup) var colourScheme: Int = 0

    @Environment(\.colorScheme) var systemColorScheme
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    var darkMode: Bool {
        (colourScheme == 0 && systemColorScheme == .dark) || colourScheme == 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(FilterType.allCases, id: \.self) { filter in
                HStack {
                    Image(systemName: FilterType.imageDictionary[filter] ?? "")
//                        .font(.system(size: 16))
                        .font(.system(.callout, design: .rounded).weight(.regular))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .frame(width: 20)
                    Text(LocalizedStringKey(filter.rawValue))
//                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .lineLimit(1)
                    Spacer()

                    if filterType == filter {
                        Image(systemName: "checkmark")
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
//                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(5)
                .background {
                    if filterType == filter {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(darkMode ? Color("AlwaysDarkSecondaryBackground") : Color("AlwaysLightSecondaryBackground"))
                            .matchedGeometryEffect(id: "TAB", in: animation)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if filterType == filter {
                        showMenu = false
                    } else {
                        Haptics.selection()

                        withAnimation(.easeIn(duration: 0.15)) {
                            filterType = filter
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showMenu = false
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
            }
        }
        .foregroundColor(darkMode ? Color("AlwaysLightBackground") : Color("AlwaysDarkBackground"))
        .padding(4)
        .frame(width: dynamicTypeSize > .xLarge ? 220 : 190)
        .background(RoundedRectangle(cornerRadius: 9).fill(darkMode ? Color("AlwaysDarkBackground") : Color("AlwaysLightBackground")).shadow(color: darkMode ? Color.clear : Color.gray.opacity(0.25), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(darkMode ? Color.gray.opacity(0.1) : Color.clear, lineWidth: 1.3))
    }
}


/// The list under the header: the UPCOMING block plus the rows for the active filter.
/// Every filter is a cut of the rows LogFeed holds, switching filters fetches nothing.
struct TransactionsList: View {
    @Binding var filter: FilterType
    var category: Category?
    var date: Date
    var week: Date
    var month: Date
    var income: Bool

    @AppStorage("showUpcomingTransactions", store: UserDefaults.appGroup) var showUpcoming: Bool = true
    @AppStorage("showUpcomingTransactionsWhenUpcoming", store: UserDefaults.appGroup) var showSoon: Bool = false

    @EnvironmentObject var dataController: DataController
    @ObservedObject var feed = LogFeed.shared

    var body: some View {
        VStack {
            if (filter == .all && showUpcoming) || filter == .upcoming {
                FutureListView(dataController: dataController, filterMode: filter == .upcoming, limitedMode: filter == .all && showSoon)
                    .padding(.top, 10)
            } else if filter == .all && !feed.upcoming.isEmpty {
                // The block is switched off in Settings: say that something is there.
                Button {
                    Haptics.tap()

                    withAnimation(.easeIn(duration: 0.15)) {
                        filter = .upcoming
                    }
                } label: {
                    Text("\(feed.upcoming.count) upcoming hidden")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundColor(Color.SubtitleText)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
            }

            switch filter {
            case .all:
                LogSectionsView(sections: feed.sections)
            case .category:
                if let categoryID = category?.objectID {
                    filtered(feed.sections(where: { $0.categoryID == categoryID }))
                } else {
                    NoResultsView(fullscreen: true)
                }
            case .day:
                filtered(feed.sections(from: date, to: Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date))
            case .week:
                filtered(feed.sections(from: week, to: Calendar.current.date(byAdding: .day, value: 7, to: week) ?? week))
            case .month:
                filtered(feed.sections(from: month, to: Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month))
            case .recurring:
                filtered(feed.sections(where: { $0.onceRecurring }))
            case .type:
                filtered(feed.sections(where: { $0.income == income }))
            case .upcoming:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    func filtered(_ sections: [LogDaySection]) -> some View {
        if sections.isEmpty {
            NoResultsView(fullscreen: true)
        } else {
            LogSectionsView(sections: sections)
        }
    }
}

/// Day list for screens that own a sectioned fetch (Insights and Budget details).
/// The Log itself draws LogSectionsView straight from LogFeed.
struct ListView: View {
    @SectionedFetchRequest<Date?, Transaction> var transactions: SectionedFetchResults<Date?, Transaction>

    var body: some View {
        LogSectionsView(sections: LogSections.make(from: transactions))
    }
}

struct FutureListView: View {
    @ObservedObject var feed = LogFeed.shared

    var filterMode: Bool
    var limitedMode: Bool

    @AppStorage("showExpenseOrIncomeSign", store: UserDefaults.appGroup)
    var showExpenseOrIncomeSign: Bool = true

    @AppStorage("swapTimeLabel", store: UserDefaults.appGroup) var swapTimeLabel: Bool = false

    var visibleRows: [LogRowModel] {
        guard limitedMode else {
            return feed.upcoming
        }

        let startOfToday = Calendar.current.startOfDay(for: Date.now)
        let limit = Calendar.current.date(byAdding: .weekOfYear, value: 2, to: startOfToday) ?? startOfToday

        return feed.upcoming.filter { $0.upcomingDate < limit }
    }

    var body: some View {
        let rows = visibleRows

        if !rows.isEmpty {
            let total = rows.reduce(0.0) { $0 + $1.signedAmount }
            let style = LogRowStyle(swapTimeLabel: swapTimeLabel, showSign: showExpenseOrIncomeSign)

            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    HStack {
                        Text("UPCOMING")
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        AmountText(total, role: .caption, sign: .always, fit: .fullOnly, color: Color.SubtitleText)
                            .layoutPriority(1)
                    }
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundColor(Color.SubtitleText)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: String(localized: "UPCOMING") + ", " + MoneyFormat.spoken(total, sign: .always)))
                    .accessibilityAddTraits(.isHeader)

                    Line()
                        .stroke(Color.Outline, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                }
                .padding(.horizontal, 10)

                ForEach(rows) { row in
                    LogRowView(row: row, future: true, style: style)
                        .equatable()
                }
            }
            .padding(.bottom, 18)
        } else if filterMode {
            NoResultsView(fullscreen: true)
        }
    }

    init(dataController _: DataController, filterMode: Bool, limitedMode: Bool) {
        self.filterMode = filterMode
        self.limitedMode = limitedMode
    }
}

/// Row for screens that still hold managed objects (Budget, Insights and Category lists).
/// The values are copied once per body pass and drawn by the same row as the Log.
struct SingleTransactionView: View {
    let transaction: Transaction
    let showCents: Bool
    let currencySymbol: String
    let currency: String
    let swapTimeLabel: Bool
    let future: Bool
    let showExpenseOrIncomeSign: Bool

    var body: some View {
        LogRowView(
            row: LogRowModel(transaction, cutoff: LogCutoff.startOfTomorrow()),
            future: future,
            style: LogRowStyle(swapTimeLabel: swapTimeLabel, showSign: showExpenseOrIncomeSign)
        )
        .equatable()
    }
}

func dateFormatter(date: Date) -> String {
    Fmt.uppercased(.dayMonth, from: date)
}

struct EmojiLogView: View {
    let emoji: String
    let colour: String
    let future: Bool
    let huge: Bool

    var body: some View {
        ZStack {
            if future {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(hex: colour).opacity(0.73), lineWidth: 2)
                    .foregroundColor(.clear)
            } else {
                RoundedRectangle(cornerRadius: huge ? 20 : 9, style: .continuous)
                    .fill(LogTint.fill(colour))
            }

            Text(emoji)
                .font(.system(huge ? .title : .title3))
                // future ? .caption :
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .padding(8)
//                .font(.system(size: huge ? 45 : future ? 16: 20))
        }
        .opacity(future ? 0.6 : 1)
    }

    init(emoji: String, colour: String, future: Bool, huge: Bool = false) {
        self.emoji = emoji
        self.colour = colour
        self.future = future
        self.huge = huge
    }
}


struct DeleteTransactionAlert: View {
    @ObservedObject var manager = OverallTransactionManager.shared

    @Environment(\.colorScheme) var systemColorScheme

    @AppStorage("bottomEdge", store: UserDefaults.appGroup) var bottomEdge: Double = 15

    var body: some View {
        if let pending = manager.pendingDelete {
            let stopRecurring = pending.stopsRecurring
            let title: LocalizedStringKey = stopRecurring ? "Stop Recurring?" : "Delete '\(pending.row.note)'?"
            let subtitle: LocalizedStringKey = stopRecurring ? "The transaction will no longer be automatically logged." : "It stays in Recently Deleted for 30 days."

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundColor(.PrimaryText)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundColor(.SubtitleText)
                    .padding(.bottom, 25)

                Button {
                    LogActions.confirmPendingDelete()
                } label: {
                    DeleteButton(text: stopRecurring ? String(localized: "Confirm") : String(localized: "Delete"), red: true)
                }
                .padding(.bottom, 8)

                Button {
                    LogActions.cancelPendingDelete()
                } label: {
                    DeleteButton(text: String(localized: "Cancel"), red: false)
                }
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.PrimaryBackground).shadow(color: systemColorScheme == .dark ? Color.clear : Color.gray.opacity(0.25), radius: 6))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(systemColorScheme == .dark ? Color.gray.opacity(0.1) : Color.clear, lineWidth: 1.3))
            .padding(.horizontal, 17)
            .padding(.bottom, bottomEdge == 0 ? 13 : bottomEdge)
        }
    }
}

struct BackgroundBlurView: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_: UIView, context _: Context) {}
}

struct NoResultsView: View {
    let fullscreen: Bool

    var body: some View {
        if fullscreen {
            VStack(spacing: 12) {
                Spacer()

                Image(systemName: "tray.full.fill")
                    .font(.system(.largeTitle, design: .rounded))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
//                    .font(.system(size: 38, weight: .regular, design: .rounded))
                    .foregroundColor(Color.SubtitleText)

                Text("No entries found.")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
//                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundColor(Color.SubtitleText)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: UIScreen.main.bounds.height * 0.7)
            .opacity(0.7)
        } else {
            VStack(spacing: 12) {
                Spacer()

                Image(systemName: "tray.full.fill")
                    .font(.system(size: 38, weight: .regular, design: .rounded))
                    .foregroundColor(Color.SubtitleText)

                Text("No entries found.")
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundColor(Color.SubtitleText)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .opacity(0.7)
            .padding(.top, 50)
        }
    }
}

struct CategoryStepperView: View {
    @Binding var categoryFilter: Category?
    @EnvironmentObject var dataController: DataController
    @State var income = false
    @State var categories = [Category]()

    var body: some View {
        HStack(spacing: 8) {
            if income {
                Image(systemName: "plus")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
//                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.IncomeGreen)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(1.0, contentMode: .fit)
//                    .frame(width: 36, height: 36)
                    .background(Color.IncomeGreen.opacity(0.23), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let fetchRequest = dataController.fetchRequestForCategories(income: false)
                        let holding = dataController.results(for: fetchRequest)

                        if holding.isEmpty {
                            return
                        } else {
                            income = false
                            categories = holding
                            categoryFilter = categories[0]
                        }
                    }
            } else {
                Image(systemName: "minus")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
//                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.AlertRed)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(1.0, contentMode: .fit)
//                    .frame(width: 36, height: 36)
                    .background(Color.AlertRed.opacity(0.23), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let fetchRequest = dataController.fetchRequestForCategories(income: true)
                        let holding = dataController.results(for: fetchRequest)

                        if holding.isEmpty {
                            return
                        } else {
                            income = true
                            categories = holding
                            categoryFilter = categories[0]
                        }
                    }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { value in
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.self) { item in
                            HStack(spacing: 5) {
                                Text(item.wrappedEmoji)
                                    .font(.system(.footnote, design: .rounded).weight(.medium))
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
//                                    .font(.system(size: 13))
                                Text(item.wrappedName)
//                                    .font(.system(size: 17.5, weight: .medium, design: .rounded))
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            }
                            .id(item.id)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .fixedSize(horizontal: false, vertical: true)
//                            .frame(height: 36)
                            .foregroundColor(categoryFilter == item ? Color(hex: item.wrappedColour) : Color.PrimaryText)
                            .background(getBackground(category: item), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if categoryFilter != item {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.Outline,
                                                      style: StrokeStyle(lineWidth: 1.5))
                                }
                            }
                            .onTapGesture {
                                categoryFilter = item
                                withAnimation {
                                    value.scrollTo(item.id, anchor: .leading)
                                }
                            }
//                            .accessibilityElement(children: .ignore)
//                            .accessibilityLabel("filter \(item.wrappedName) transactions button")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .onAppear {
            let fetchRequest = dataController.fetchRequestForCategories(income: income)
            categories = dataController.results(for: fetchRequest)

            if categories.isEmpty {
                categoryFilter = nil
            } else {
                categoryFilter = categories[0]
            }
        }
        .onChange(of: income) { _ in
            if categories.isEmpty {
                categoryFilter = nil
            } else {
                categoryFilter = categories[0]
            }
        }
    }

    func getBackground(category: Category) -> Color {
        if category == categoryFilter {
            return Color(hex: category.wrappedColour).opacity(0.3)
        } else {
            return Color.PrimaryBackground
        }
    }

    init(categoryFilter: Binding<Category?>?) {
        _categoryFilter = categoryFilter ?? Binding.constant(nil)
    }
}

struct IncomeFilterToggleView: View {
    @Binding var income: Bool

    @Namespace var animation

    var body: some View {
        HStack(spacing: 0) {
            Text("Expense")
//                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundColor(income == false ? Color.PrimaryText : Color.SubtitleText)
                .padding(5.5)
                .padding(.horizontal, 8)
                .background {
                    if income == false {
                        Capsule()
                            .fill(Color.SecondaryBackground)
                            .matchedGeometryEffect(id: "TAB1", in: animation)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    DispatchQueue.main.async {
                        withAnimation(.easeIn(duration: 0.15)) {
                            income = false
                        }
                    }
                }

            Text("filter-picker-income")
//                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundColor(income == true ? Color.PrimaryText : Color.SubtitleText)
                .padding(5.5)
                .padding(.horizontal, 8)
                .background {
                    if income == true {
                        Capsule()
                            .fill(Color.SecondaryBackground)
                            .matchedGeometryEffect(id: "TAB1", in: animation)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    DispatchQueue.main.async {
                        withAnimation(.easeIn(duration: 0.15)) {
                            income = true
                        }
                    }
                }
        }
        .padding(3)
        .overlay(Capsule().stroke(Color.Outline.opacity(0.4), lineWidth: 1.3))
    }
}


// The steppers below used to keep fetches of every transaction alive only to read the
// first and the last day. Both dates now come from LogFeed.stats.

struct DateStepperView: View {
    @ObservedObject var stats = LogFeed.shared.stats

    @Binding var date: Date

    var endDate: Date {
        Calendar.current.startOfDay(for: stats.earliestDate ?? Date.now)
    }

    var currentDate: Date {
        Calendar.current.startOfDay(for: Date.now)
    }

    var dateString: String {
        Fmt.string(.dayMonthYear, from: date)
    }

    var body: some View {
        HStack {
            StepperButtonView(left: true, disabled: date <= endDate) {
                if date > endDate {
                    Haptics.selection()
                    date = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? Date.now
                }
            }
            .accessibilityLabel("previous day")

            Spacer()

            Text(dateString)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityLabel("showing transactions on \(dateString)")

            Spacer()

            StepperButtonView(left: false, disabled: date >= currentDate) {
                if date < currentDate {
                    Haptics.selection()
                    date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? Date.now
                }
            }
            .accessibilityLabel("next day")
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            date = currentDate
        }
    }
}

struct WeekStepperView: View {
    @ObservedObject var stats = LogFeed.shared.stats

    @Binding var showingDate: Date

    @State var startDate = Date.now

    func weekStart(of date: Date) -> Date {
        var weekCalendar = Calendar(identifier: .gregorian)
        weekCalendar.firstWeekday = UserDefaults.appGroup.integer(forKey: "firstWeekday")
        weekCalendar.minimumDaysInFirstWeek = 4

        return weekCalendar.date(from: weekCalendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)) ?? date
    }

    var endDate: Date {
        weekStart(of: stats.earliestDate ?? Date.now)
    }

    var lastDayOfWeek: Date {
        Calendar.current.date(byAdding: DateComponents(day: 7, second: -1), to: showingDate) ?? Date.now
    }

    var dateString: String {
        Fmt.range(.dayMonth, from: showingDate, to: lastDayOfWeek)
    }

    var body: some View {
        HStack {
            StepperButtonView(left: true, disabled: showingDate <= endDate) {
                if showingDate > endDate {
                    Haptics.selection()
                    showingDate = Calendar.current.date(byAdding: .day, value: -7, to: showingDate) ?? Date.now
                }
            }
            .accessibilityLabel("previous week")

            Spacer()

            Text(dateString)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityLabel("showing transactions from \(Fmt.string(.dayMonth, from: showingDate)) to \(Fmt.string(.dayMonth, from: lastDayOfWeek))")

            Spacer()

            StepperButtonView(left: false, disabled: showingDate >= startDate) {
                if showingDate < startDate {
                    Haptics.selection()
                    showingDate = Calendar.current.date(byAdding: .day, value: 7, to: showingDate) ?? Date.now
                }
            }
            .accessibilityLabel("next week")
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // The newest week that has entries, or this week when everything is in the future.
            startDate = weekStart(of: stats.latestCurrentDate ?? Date.now)
            showingDate = startDate
        }
    }
}

struct MonthStepperView: View {
    @ObservedObject var stats = LogFeed.shared.stats

    @Binding var showingDate: Date

    @State var startDate = Date.now

    func monthStart(of date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: calendar.dateComponents([.month, .year], from: date)) ?? date
    }

    var endDate: Date {
        monthStart(of: stats.earliestDate ?? Date.now)
    }

    var dateString: String {
        Fmt.string(.monthYear, from: showingDate)
    }

    var body: some View {
        HStack {
            StepperButtonView(left: true, disabled: showingDate <= endDate) {
                if showingDate > endDate {
                    Haptics.selection()
                    showingDate = Calendar.current.date(byAdding: .month, value: -1, to: showingDate) ?? Date.now
                }
            }
            .accessibilityLabel("previous month")

            Spacer()

            Text(dateString)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityLabel("showing transactions in \(dateString)")

            Spacer()

            StepperButtonView(left: false, disabled: showingDate >= startDate) {
                if showingDate < startDate {
                    Haptics.selection()
                    showingDate = Calendar.current.date(byAdding: .month, value: 1, to: showingDate) ?? Date.now
                }
            }
            .accessibilityLabel("next month")
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            startDate = monthStart(of: stats.latestCurrentDate ?? Date.now)
            showingDate = startDate
        }
    }
}

func dateConverter(date: Date) -> String {
    Fmt.dayHeader(date)
}

func dayTotal(dayTransaction: [Transaction]) -> Double {
    var total = 0.0

    dayTransaction.forEach { transaction in
        if transaction.income {
            total += transaction.amount
        } else {
            total -= transaction.amount
        }
    }

    return total
}
