//
//  LockBudgetWidget.swift
//  ExpenditureWidgetExtension
//
//  Created by Rafael Soh on 9/9/22.
//

import SwiftUI
import WidgetKit

struct LockBudgetWidget: Widget {
    let kind: String = "LockBudgetWidget"

    private var supportedFamilies: [WidgetFamily] {
        if #available(iOSApplicationExtension 16, *) {
            return [
                .accessoryCircular,
                .accessoryRectangular,
                .accessoryInline
            ]
        } else {
            return [WidgetFamily]()
        }
    }

    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind, intent: BudgetWidgetConfigurationIntent.self, provider: LockBudgetWidgetProvider()) { entry in
            LockBudgetWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Budget")
        .description("Monitor how you are sticking to your budgets.")
        .supportedFamilies(supportedFamilies)
    }
}

struct LockBudgetWidgetProvider: IntentTimelineProvider {
    typealias Intent = BudgetWidgetConfigurationIntent

    public typealias Entry = LockBudgetWidgetEntry

    func placeholder(in _: Context) -> LockBudgetWidgetEntry {
        let loaded = loadData(budgetId: "")

        return LockBudgetWidgetEntry(date: Date(), totalSpent: loaded.total, timeLeft: loaded.timeLeft, budget: loaded.budget, configuration: BudgetWidgetConfigurationIntent())
    }

    func getSnapshot(for configuration: BudgetWidgetConfigurationIntent, in _: Context, completion: @escaping (LockBudgetWidgetEntry) -> Void) {
        let loaded = loadData(budgetId: configuration.budget?.identifier ?? "")

        let entry = LockBudgetWidgetEntry(date: Date(), totalSpent: loaded.total, timeLeft: loaded.timeLeft, budget: loaded.budget, configuration: configuration)
        completion(entry)
    }

    func getTimeline(for configuration: BudgetWidgetConfigurationIntent, in _: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let loaded = loadData(budgetId: configuration.budget?.identifier ?? "")

        let entry = LockBudgetWidgetEntry(date: Date(), totalSpent: loaded.total, timeLeft: loaded.timeLeft, budget: loaded.budget, configuration: configuration)

        let timeline = Timeline(entries: [entry], policy: .atEnd)

        completion(timeline)
    }

    func loadData(budgetId: String) -> (total: Double, timeLeft: String, budget: HoldingBudget) {
        let now = Date.now

        guard let loaded = WidgetBudgetLoader.load(budgetId: budgetId, now: now) else {
            return (0, "", WidgetBudgetLoader.missingBudget)
        }

        let timeLeft: String
        let calendar = Calendar.current

        if loaded.budget.type == 1 {
            let hoursPast = calendar.dateComponents([.hour], from: loaded.periodStart, to: now).hour ?? 0

            timeLeft = String(localized: "\(max(0, 24 - hoursPast)) hours left")
        } else {
            let numberOfDays = calendar.dateComponents([.day], from: loaded.periodStart, to: loaded.periodEnd).day ?? 0
            let numberOfDaysPast = calendar.dateComponents([.day], from: loaded.periodStart, to: now).day ?? 0

            timeLeft = String(localized: "\(max(0, numberOfDays - numberOfDaysPast)) days left")
        }

        return (loaded.total, timeLeft, loaded.budget)
    }
}

struct LockBudgetWidgetEntry: TimelineEntry {
    let date: Date
    let totalSpent: Double
    let timeLeft: String
    let budget: HoldingBudget
    let configuration: BudgetWidgetConfigurationIntent
}

struct LockBudgetWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    let entry: LockBudgetWidgetProvider.Entry

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

    var subtitle: String {
        if entry.budget.budgetAmount >= entry.totalSpent {
            return String(localized: "left")
        } else {
            return String(localized: "over")
        }
    }

    var difference: Double {
        return abs(entry.budget.budgetAmount - entry.totalSpent)
    }

    var percent: Double {
        return WidgetMoney.ratio(entry.totalSpent, of: entry.budget.budgetAmount)
    }

    var percentString: String {
        return String(localized: "\(WidgetMoney.percent(entry.totalSpent, of: entry.budget.budgetAmount))% spent")
    }

    // The picked budget was deleted in the app.
    var missing: Bool {
        return entry.budget.emoji == "failed"
    }

    var body: some View {
        switch widgetFamily {
        case .accessoryInline:
            if entry.configuration.budget == nil || missing {
                Text("Select budget in widget options")
            } else {
                Text("\(entry.budget.emoji) \(MoneyFormat.compact(difference)) \(subtitle)")
                    .widgetURL(URL(string: "\(AppIdentifiers.urlScheme)://budget?budget=\(entry.budget.name)"))
            }

        case .accessoryCircular:
            if entry.configuration.budget == nil || missing {
                ZStack {
                    AccessoryWidgetBackground()

                    Text("SELECT BUDGET")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
            } else {
                Gauge(value: percent < 1 ? percent : 1) {
                    Text(entry.budget.emoji)
                } currentValueLabel: {
                    Text("\(WidgetMoney.percent(entry.totalSpent, of: entry.budget.budgetAmount))%")
                }
                .gaugeStyle(AccessoryCircularGaugeStyle())
                .widgetURL(URL(string: "\(AppIdentifiers.urlScheme)://budget?budget=\(entry.budget.name)"))
                .containerBackground(for: .widget) { Color.clear }
            }

        case .accessoryRectangular:
            if entry.configuration.budget == nil || missing {
                Text("SELECT BUDGET IN WIDGET OPTIONS")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .containerBackground(for: .widget) { Color.clear }
            } else {
                GeometryReader { proxy in
                    VStack(alignment: .leading) {
                        HStack(spacing: 3) {
                            Text(entry.budget.name)

                            if showPercent(size: proxy.size.width) {
                                Text("•")
                                Text(percentString)
                            }
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))

                        Text("\(MoneyFormat.compact(difference)) \(subtitle) \(budgetType)")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundColor(Color.SubtitleText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Gauge(value: percent < 1 ? percent : 1, in: 0 ... 1) {
                            Text("Percent Spent")
                        } currentValueLabel: {
                            EmptyView()
                        } minimumValueLabel: {
                            Text(WidgetMoney.short(entry.totalSpent))
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                        } maximumValueLabel: {
                            Text(WidgetMoney.short(entry.budget.budgetAmount))
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                        }
                        .frame(height: 5)
                        .gaugeStyle(.accessoryLinear)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .widgetURL(URL(string: "\(AppIdentifiers.urlScheme)://budget?budget=\(entry.budget.name)"))
                .containerBackground(for: .widget) { Color.clear }
            }

        default:
            EmptyView()
        }
    }

    func showPercent(size: CGFloat) -> Bool {
        return size > entry.budget.name.widthOfRoundedString(size: 15, weight: .semibold) + 15 + percentString.widthOfRoundedString(size: 15, weight: .semibold)
    }
}
