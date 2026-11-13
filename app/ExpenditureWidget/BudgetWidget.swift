//
//  BudgetWidget.swift
//  dime
//
//  Created by Rafael Soh on 17/8/22.
//

import SwiftUI
import WidgetKit

struct BudgetWidget: Widget {
    let kind: String = "BudgetWidget"

    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind, intent: BudgetWidgetConfigurationIntent.self, provider: BudgetWidgetProvider()) { entry in
            BudgetWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Budget")
        .description("Monitor how you are sticking to your budgets.")
        .supportedFamilies([.systemSmall])
    }
}

struct BudgetWidgetProvider: IntentTimelineProvider {
    typealias Intent = BudgetWidgetConfigurationIntent

    public typealias Entry = BudgetWidgetEntry

    func placeholder(in _: Context) -> BudgetWidgetEntry {
        let loaded = loadData(budgetId: "")

        return BudgetWidgetEntry(date: Date(), totalSpent: loaded.total, percentageOfDays: loaded.percentage, budget: loaded.budget, configuration: BudgetWidgetConfigurationIntent())
    }

    func getSnapshot(for configuration: BudgetWidgetConfigurationIntent, in _: Context, completion: @escaping (BudgetWidgetEntry) -> Void) {
        let loaded = loadData(budgetId: configuration.budget?.identifier ?? "")

        let entry = BudgetWidgetEntry(date: Date(), totalSpent: loaded.total, percentageOfDays: loaded.percentage, budget: loaded.budget, configuration: configuration)
        completion(entry)
    }

    func getTimeline(for configuration: BudgetWidgetConfigurationIntent, in _: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let loaded = loadData(budgetId: configuration.budget?.identifier ?? "")

        let entry = BudgetWidgetEntry(date: Date(), totalSpent: loaded.total, percentageOfDays: loaded.percentage, budget: loaded.budget, configuration: configuration)

        let timeline = Timeline(entries: [entry], policy: .atEnd)

        completion(timeline)
    }

    func loadData(budgetId: String) -> (total: Double, percentage: Double, budget: HoldingBudget) {
        guard let loaded = WidgetBudgetLoader.load(budgetId: budgetId) else {
            return (0, 0, WidgetBudgetLoader.missingBudget)
        }

        return (loaded.total, loaded.elapsedShare(), loaded.budget)
    }
}

struct BudgetWidgetEntry: TimelineEntry {
    let date: Date
    let totalSpent: Double
    let percentageOfDays: Double
    let budget: HoldingBudget
    let configuration: BudgetWidgetConfigurationIntent
}

struct HoldingBudget {
    let type: Int
    let emoji: String
    let name: String
    let colour: String
    let budgetAmount: Double
}

// Shared by the budget widgets: this file is compiled into the app and the widget extension.
enum WidgetBudgetLoader {
    struct Loaded {
        let total: Double
        let periodStart: Date
        let periodEnd: Date
        let budget: HoldingBudget

        // Share of the current period that has passed, 0...1.
        func elapsedShare(now: Date = Date.now) -> Double {
            let length = periodEnd.timeIntervalSince(periodStart)

            guard length > 0 else {
                return 0
            }

            return min(1, max(0, now.timeIntervalSince(periodStart) / length))
        }
    }

    static var missingBudget: HoldingBudget {
        HoldingBudget(type: 1, emoji: "failed", name: "", colour: "", budgetAmount: 0)
    }

    // nil when no budget is picked or the picked one was deleted.
    static func load(budgetId: String, now: Date = Date.now) -> Loaded? {
        let dataController = DataController.shared
        let context = dataController.container.viewContext

        guard let objectIDURL = URL(string: budgetId), objectIDURL.scheme == "x-coredata",
              let objectID = dataController.container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: objectIDURL),
              let object = try? context.existingObject(with: objectID),
              let budget = object as? Budget
        else {
            return nil
        }

        let transactions = dataController.results(for: dataController.fetchRequestForBudgetTransactions(budget: budget))

        var total = 0.0

        transactions.forEach { transaction in
            total += transaction.wrappedAmount
        }

        // The stored startDate is rolled only when the Budgets tab opens, so the period is derived here.
        let periodStart = budget.currentPeriodStart(now: now)
        let periodEnd = BudgetPeriod.end(of: periodStart, type: budget.type) ?? periodStart

        let holding = HoldingBudget(type: Int(budget.type), emoji: budget.wrappedEmoji, name: budget.wrappedName, colour: budget.wrappedColour, budgetAmount: budget.amount)

        return Loaded(total: total, periodStart: periodStart, periodEnd: periodEnd, budget: holding)
    }
}

enum WidgetMoney {
    // 0 when there is no budget amount: Int(...) traps on NaN and infinity.
    static func ratio(_ spent: Double, of budget: Double) -> Double {
        guard budget > 0, budget.isFinite, spent.isFinite else {
            return 0
        }

        return spent / budget
    }

    static func percent(_ spent: Double, of budget: Double) -> Int {
        let value = (ratio(spent, of: budget) * 100).rounded()

        return Int(min(max(value, -999_999), 999_999))
    }

    // Tiny slots (gauge ends, lock screen rows, small widget rows): compact number, no symbol.
    static func short(_ value: Double, sign: MoneySign = .automatic) -> String {
        MoneyFormat.compactParts(value, sign: sign).withoutSymbol().text
    }
}

struct BudgetWidgetEntryView: View {
    let entry: BudgetWidgetProvider.Entry

    var budgetType: String {
        switch entry.budget.type {
        case 1:
            return String(localized: "today")
        case 2:
            return String(localized: "this week")
        case 3:
            return String(localized: "this month")
        case 4:
            return String(localized: "this year")
        default:
            return "this week"
        }
    }

    var difference: Double {
        return abs(entry.budget.budgetAmount - entry.totalSpent)
    }

    var percentString1: String {
        return "\(WidgetMoney.percent(entry.totalSpent, of: entry.budget.budgetAmount))%"
    }

    var systemSmallWidgetText: String {
        if entry.budget.budgetAmount >= entry.totalSpent {
            return String(localized: "left \(budgetType)")
        } else {
            return String(localized: "over \(budgetType)")
        }
    }

    func showTimeFrame(size: CGFloat) -> Bool {
        return size > systemSmallWidgetText.widthOfRoundedString(size: 10, weight: .semibold)
    }

    var body: some View {
        if entry.configuration.budget == nil {
            Text("Select budget in widget options")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundColor(Color.SubtitleText)
                .padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(for: .widget) {
                    Color.PrimaryBackground
                }

        } else if entry.budget.emoji == "failed" {
            Text("Budget no longer exists - please select new budget from widget options.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundColor(Color.SubtitleText)
                .padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(for: .widget) {
                    Color.PrimaryBackground
                }

        } else {
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2.4) {
                        HStack(spacing: 5) {
                            Text(entry.budget.emoji)
                                .font(.system(size: 9))
                            Text(entry.budget.name.uppercased())
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundColor(Color.PrimaryText)

                        Text("SPENT: \(percentString1)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(Color.SubtitleText)
                    }

                    Spacer()

                    RingView(percent: entry.percentageOfDays, width: 2.4, topStroke: Color.DarkBackground, bottomStroke: Color.SecondaryBackground)
                        .frame(width: 13, height: 13)
                        .padding(3)
                }
                .frame(maxWidth: .infinity)

                GeometryReader { proxy in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            ZStack {
                                DonutSemicircle(percent: 1, cornerRadius: 4, width: 15)
                                    .fill(Color.SecondaryBackground)
                                    .frame(width: proxy.size.width, height: proxy.size.width / 2)

                                if WidgetMoney.ratio(entry.totalSpent, of: entry.budget.budgetAmount) < 0.97 {
                                    DonutSemicircle(percent: 1 - WidgetMoney.ratio(entry.totalSpent, of: entry.budget.budgetAmount), cornerRadius: 4, width: 15)
                                        .fill(Color(hex: entry.budget.colour))
                                        .frame(width: proxy.size.width, height: proxy.size.width / 2)
                                }
                            }
                            .frame(width: proxy.size.width)

                            VStack(spacing: -4) {
                                WidgetBudgetDollarView(amount: difference, red: entry.totalSpent >= entry.budget.budgetAmount)
                                    .frame(width: proxy.size.width - 50)

                                if showTimeFrame(size: proxy.size.width - 50) {
                                    Text(systemSmallWidgetText)
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundColor(Color.SubtitleText)
                                } else {
                                    if entry.budget.budgetAmount >= entry.totalSpent {
                                        Text("left")
                                            .font(.system(size: 10, weight: .medium, design: .rounded))
                                            .foregroundColor(Color.SubtitleText)
                                    } else {
                                        Text("over")
                                            .font(.system(size: 10, weight: .medium, design: .rounded))
                                            .foregroundColor(Color.SubtitleText)
                                    }
                                }
                            }
                        }
                        .frame(width: proxy.size.width)

                        HStack {
                            Text(WidgetMoney.short(entry.totalSpent))
                            Spacer(minLength: 6)
                            Text(WidgetMoney.short(entry.budget.budgetAmount))
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                Color.PrimaryBackground
            }
            .widgetURL(URL(string: "\(AppIdentifiers.urlScheme)://budget?budget=\(entry.budget.name)"))
        }
    }
}

struct WidgetBudgetDollarView: View {
    var amount: Double
    var red: Bool

    var body: some View {
        WidgetAmountText(
            amount: amount, size: 20,
            color: red ? Color("BudgetRed") : Color.PrimaryText,
            secondaryColor: red ? Color("BudgetRed") : Color.SubtitleText
        )
    }
}

// Big number of a small widget. AmountText stops at the compact form with the symbol, and
// "1,23 mlrd so'm" is still wider than the slot inside the gauge arc, so this ladder has
// two more steps and ends without the symbol.
struct WidgetAmountText: View {
    var amount: Double
    var size: CGFloat
    var secondaryRatio: CGFloat = 0.75
    var sign: MoneySign = .automatic
    var color: Color = Color.PrimaryText
    var secondaryColor: Color = Color.SubtitleText

    var body: some View {
        let settings = MoneySettings.current
        let full = MoneyFormat.parts(amount, sign: sign, settings: settings)
        let compact = MoneyFormat.compactParts(amount, sign: sign, settings: settings)

        // ViewThatFits compares ideal sizes: only the last step may scale.
        ViewThatFits(in: .horizontal) {
            line(full, scale: 1).lineLimit(1).fixedSize()
            line(full, scale: 0.8).lineLimit(1).fixedSize()
            line(compact, scale: 1).lineLimit(1).fixedSize()
            line(compact, scale: 0.8).lineLimit(1).fixedSize()
            line(compact.withoutSymbol(), scale: 1).lineLimit(1).minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(MoneyFormat.spoken(amount, sign: sign, settings: settings)))
    }

    private func line(_ parts: MoneyParts, scale: CGFloat) -> Text {
        let mainFont = Font.system(size: size * scale, weight: .medium, design: .rounded)
        let smallFont = Font.system(size: size * scale * secondaryRatio, weight: .medium, design: .rounded)

        var text: Text

        if parts.symbolLeading, !parts.symbol.isEmpty {
            text = Text(parts.sign + parts.symbol + parts.symbolSeparator).font(smallFont).foregroundColor(secondaryColor)
                + Text(parts.integer).font(mainFont).foregroundColor(color)
        } else {
            text = Text(parts.sign + parts.integer).font(mainFont).foregroundColor(color)
        }

        if !parts.fraction.isEmpty {
            // In the compact form the fraction carries the value ("35,9"), so it stays large.
            if parts.isCompact {
                text = text + Text(parts.fraction).font(mainFont).foregroundColor(color)
            } else {
                text = text + Text(parts.fraction).font(smallFont).foregroundColor(secondaryColor)
            }
        }

        if parts.isCompact {
            text = text + Text(parts.unitSeparator + parts.unit).font(smallFont).foregroundColor(secondaryColor)
        }

        if !parts.symbolLeading, !parts.symbol.isEmpty {
            text = text + Text(parts.symbolSeparator + parts.symbol).font(smallFont).foregroundColor(secondaryColor)
        }

        return text
    }
}
