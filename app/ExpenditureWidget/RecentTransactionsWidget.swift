//
//  RecentTransactionsWidget.swift
//  ExpenditureWidgetExtension
//
//  Created by Rafael Soh on 12/8/22.
//

import SwiftUI
import WidgetKit

struct RecentExpenditureWidget: Widget {
    let kind: String = "ExpenditureWidget"

    private var supportedFamilies: [WidgetFamily] {
        if #available(iOSApplicationExtension 17, *) {
            return [
                .accessoryRectangular,
                .accessoryInline,
                .systemSmall,
                .systemLarge
            ]
        } else if #available(iOSApplicationExtension 16, *) {
            return [
                .accessoryRectangular,
                .accessoryInline,
                .systemSmall
            ]
        } else {
            return [.systemSmall]
        }
    }

    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind, intent: RecentWidgetConfigurationIntent.self, provider: Provider()) { entry in
            ExpenditureWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Recent Transactions")
        .description("View your latest expenses.")
        .supportedFamilies(supportedFamilies)
    }
}

struct Provider: IntentTimelineProvider {
    typealias Intent = RecentWidgetConfigurationIntent

    public typealias Entry = RecentWidgetEntry

    func placeholder(in _: Context) -> RecentWidgetEntry {
        RecentWidgetEntry(date: Date(), amount: loadAmount(type: .week, insightsType: .net), transactions: loadTransactions(type: .week, count: 9), duration: .week, type: .net)
    }

    func getSnapshot(for configuration: RecentWidgetConfigurationIntent, in _: Context, completion: @escaping (RecentWidgetEntry) -> Void) {
        let entry = RecentWidgetEntry(date: Date(), amount: loadAmount(type: configuration.duration, insightsType: configuration.insightsType), transactions: loadTransactions(type: configuration.duration, count: 9), duration: configuration.duration, type: configuration.insightsType)
        completion(entry)
    }

    func getTimeline(for configuration: RecentWidgetConfigurationIntent, in _: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = RecentWidgetEntry(date: Date(), amount: loadAmount(type: configuration.duration, insightsType: configuration.insightsType), transactions: loadTransactions(type: configuration.duration, count: 9), duration: configuration.duration, type: configuration.insightsType)

        let timeline = Timeline(entries: [entry], policy: .atEnd)

        completion(timeline)
    }

    func loadAmount(type: TimePeriod, insightsType: InsightsType) -> Double {
//        let dataController = DataController()
        let dataController = DataController.shared

        let timeframe: Int

        switch type {
        case .day:
            timeframe = 1
        case .week:
            timeframe = 2
        case .month:
            timeframe = 3
        case .year:
            timeframe = 4
        default:
            timeframe = 0
        }

        switch insightsType {
        case .net:
            let (amount, positive) = dataController.getLogViewTotalNet(type: timeframe)

            if positive {
                return amount
            } else {
                return -amount
            }

        case .income:
            return dataController.getLogViewTotalIncome(type: timeframe)
        case .expense:
            return dataController.getLogViewTotalSpent(type: timeframe)
        default:
            return 0
        }
    }

    func loadTransactions(type: TimePeriod, count: Int) -> [HoldingTransaction] {
//        let dataController = DataController()
        let dataController = DataController.shared
        let itemRequest = dataController.fetchRequestForRecentTransactionsWithCount(type: type, count: count)
        let holding = dataController.results(for: itemRequest)

        var sending = [HoldingTransaction]()

        holding.forEach { transaction in
            let t = HoldingTransaction(colour: transaction.category?.wrappedColour ?? "", note: transaction.wrappedNote, amount: transaction.wrappedAmount, income: transaction.income)

            sending.append(t)
        }

        return sending
    }
}

struct RecentWidgetEntry: TimelineEntry {
    let date: Date
    let amount: Double
    let transactions: [HoldingTransaction]
    let duration: TimePeriod
    let type: InsightsType
}

struct HoldingTransaction: Hashable {
    let colour: String
    let note: String
    let amount: Double
    let income: Bool
}

struct ExpenditureWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    let entry: Provider.Entry

    var inlineSubtitleText: String {
        switch entry.duration {
        case .unknown:
            return "NIL"
        case .day:
            return String(localized: "today")
        case .week:
            return String(localized: "this week")
        case .month:
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM"
            return String(localized: "in \(formatter.string(from: Date.now))")
        case .year:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy"
            return String(localized: "in \(formatter.string(from: Date.now))")
        }
    }

    var typeText: String {
        switch entry.type {
        case .unknown:
            return ""
        case .net:
            return String(localized: "net")
        case .income:
            return String(localized: "earned")
        case .expense:
            return String(localized: "spent")
        }
    }

    // Net is stored signed, income and expense totals are stored positive.
    var amountSign: MoneySign {
        switch entry.type {
        case .unknown:
            return .automatic
        case .net:
            return .always
        case .income:
            return .plus
        case .expense:
            return .minus
        }
    }

    var body: some View {
        switch widgetFamily {
        case .accessoryInline:
            if entry.amount == 0 {
                Text("\(MoneyFormat.compact(0)) \(typeText) \(inlineSubtitleText)")
            } else {
                Text("\(MoneyFormat.compact(entry.amount, sign: amountSign)) \(inlineSubtitleText)")
            }
        case .accessoryRectangular:
            if entry.transactions.count == 0 {
                Text("NO RECENT EXPENSES")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .containerBackground(for: .widget) { Color.clear }
            } else {
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entry.transactions.prefix(3).enumerated()), id: \.offset) { _, transaction in
                            HStack(spacing: 3) {
                                Text(transaction.note)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(WidgetMoney.short(transaction.amount, sign: transaction.income ? .plus : .minus))
                                    .fontWeight(.regular)
                                    .layoutPriority(1)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 13, design: .rounded))
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(for: .widget) { Color.clear }
            }
        case .systemSmall:
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Text((typeText + " " + inlineSubtitleText).uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.SubtitleText)

                        RecentTransactionsDollarView(amount: entry.amount, net: entry.type == .net, bigger: true)
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height * 0.27)
                    }
                    .frame(maxWidth: .infinity)

                    if entry.transactions.isEmpty {
                        VStack(spacing: 5) {
                            Text("NO RECENT EXPENSES")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(Color.SubtitleText)
                                .frame(maxHeight: .infinity)

                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))

                                Text("New Expense")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(Color.PrimaryText)
                            }
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.SecondaryBackground))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        .padding(.top, 12)

                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("RECENT EXPENSES")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(Color.SubtitleText)

                            ForEach(Array(entry.transactions.prefix(3).enumerated()), id: \.offset) { _, transaction in
                                HStack(spacing: 5) {
                                    Capsule()
                                        .fill(Color(hex: transaction.colour))
                                        .frame(width: 4, height: 12)

                                    Text(transaction.note)
                                        .lineLimit(1)
                                        .font(.system(size: 13, weight: .regular, design: .rounded))
                                        .foregroundColor(Color.PrimaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    // No symbol here: the total above carries it and the note needs the width.
                                    Text(WidgetMoney.short(transaction.amount, sign: transaction.income ? .plus : .minus))
                                        .font(.system(size: 13, weight: .regular, design: .rounded))
                                        .foregroundColor(transaction.income ? Color.IncomeGreen : Color.SubtitleText)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                }
                            }

                            if entry.transactions.count < 2 {
                                HStack(spacing: 5) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))

                                    Text("New Expense")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundColor(Color.PrimaryText)
                                }
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.SecondaryBackground))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        .padding(.top, entry.transactions.count >= 3 ? 5 : 10)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                Color.PrimaryBackground
            }
            .widgetURL(entry.transactions.count < 2 ? URL(string: "\(AppIdentifiers.urlScheme)://newExpense") : nil)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

        case .systemLarge:
            GeometryReader { _ in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Text((typeText + " " + inlineSubtitleText).uppercased())
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.SubtitleText)

                        RecentTransactionsDollarView(amount: entry.amount, net: entry.type == .net)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)

                    Spacer()
                        .frame(minHeight: 5, idealHeight: 15, maxHeight: 20)
                        .fixedSize()

                    if entry.transactions.isEmpty {
                        VStack(spacing: 20) {
                            Text("NO RECENT EXPENSES")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundColor(Color.SubtitleText)

                            Link(destination: URL(string: "\(AppIdentifiers.urlScheme)://newExpense")!) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))

                                    Text("New Expense")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundColor(Color.PrimaryText)
                                }
                                .padding(.vertical, 6)
                                .frame(width: 200)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.SecondaryBackground))
                            }
                        }
                        .frame(maxHeight: .infinity)

                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RECENT EXPENSES")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(Color.SubtitleText)

                            ForEach(Array(entry.transactions.enumerated()), id: \.offset) { _, transaction in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color(hex: transaction.colour))
                                        .frame(width: 15, height: 15)

                                    Text(transaction.note)
                                        .lineLimit(1)
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                        .foregroundColor(Color.PrimaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(MoneyFormat.string(transaction.amount, sign: transaction.income ? .plus : .minus))
                                        .font(.system(size: 16, weight: .regular, design: .rounded))
                                        .foregroundColor(transaction.income ? Color.IncomeGreen : Color.SubtitleText)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .layoutPriority(1)
                                }
                            }

                            if entry.transactions.count < 5 {
                                Link(destination: URL(string: "\(AppIdentifiers.urlScheme)://newExpense")!) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))

                                        Text("New Expense")
                                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                                            .foregroundColor(Color.PrimaryText)
                                    }
                                    .padding(.vertical, 6)
                                    .frame(width: 200)
                                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.SecondaryBackground))
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                Color.PrimaryBackground
            }

        default:
            EmptyView()
        }
    }
}

struct RecentTransactionsDollarView: View {
    var amount: Double
    var net: Bool
    var bigger: Bool = false

    var body: some View {
        // Net shows its sign, a zero never does.
        WidgetAmountText(amount: amount, size: bigger ? 28 : 20, secondaryRatio: bigger ? 0.72 : 0.75, sign: net ? .always : .automatic)
    }
}
