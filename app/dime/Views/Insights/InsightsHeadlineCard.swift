//
//  InsightsHeadlineCard.swift
//  dime
//

import SwiftUI

// The hero of the page, drawn on the background like the Log total: the flow switch as its label,
// one big number (the period, or the selected day / category), the change and two quiet stats.
struct InsightsHeadlineCard: View {
    let page: InsightsPage
    let showsFlowSwitch: Bool
    let onFlow: (InsightsFlow) -> Void
    let onClear: () -> Void

    private var sign: MoneySign {
        page.flow == .net ? .always : .never
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsFlowSwitch {
                InsightsSegmentedControl(items: flowItems, selection: page.flow.rawValue, fillsWidth: true) { value in
                    onFlow(InsightsFlow(rawValue: value) ?? .expense)
                }
            } else {
                Text(verbatim: InsightsFormat.flowTitle(page.flow))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.SubtitleText)
                    .frame(minHeight: 34, alignment: .leading)
            }

            if page.hasSelection {
                scopeChip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            AmountText(page.total, size: 44, relativeTo: .largeTitle, weight: .regular, style: .hero,
                       secondaryRatio: 0.5, sign: sign, animated: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .amountReveal(page.total, sign: sign)

            if let comparison = page.comparison {
                InsightsComparisonRow(comparison: comparison, lowerIsBetter: page.flow == .expense)
            }

            HStack(alignment: .top, spacing: 16) {
                InsightsStatCell(title: averageTitle) {
                    AmountText(page.average, role: .caption, sign: page.flow == .net ? .automatic : .never)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .amountReveal(page.average, sign: page.flow == .net ? .automatic : .never)
                }

                InsightsStatCell(title: "Transactions count") {
                    Text(verbatim: String(page.count))
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .padding(.top, 4)
        }
    }

    private var flowItems: [InsightsSegmentItem] {
        [
            InsightsSegmentItem(id: InsightsFlow.expense.rawValue, title: "Expenses"),
            InsightsSegmentItem(id: InsightsFlow.income.rawValue, title: "Income"),
            InsightsSegmentItem(id: InsightsFlow.net.rawValue, title: "Net")
        ]
    }

    // What the number is narrowed to: the category and / or the day. The cross clears both.
    private var scopeChip: some View {
        Button(action: onClear) {
            HStack(spacing: 6) {
                if let tint = page.tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }

                Text(verbatim: scopeText)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "xmark")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundColor(Color.SubtitleText)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.SecondaryBackground, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(InsightsPressStyle())
        .accessibilityLabel(Text(verbatim: scopeText))
        .accessibilityHint(Text("Clear selection"))
    }

    // Without a category the flow title is already on the switch above, so only the day is shown.
    private var scopeText: String {
        let detail = page.scopeDetail ?? ""
        guard page.tint != nil else { return detail.isEmpty ? page.scopeTitle : detail }
        return detail.isEmpty ? page.scopeTitle : page.scopeTitle + ", " + detail
    }

    private var averageTitle: LocalizedStringKey {
        switch page.averageKind {
        case .perDay: return "Daily average"
        case .perMonth: return "Monthly average"
        case .perTransaction: return "Average transaction"
        }
    }
}

struct InsightsStatCell<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// Like-for-like change: the same number of days of the previous period.
// Past 500% a percent says nothing (a 32 mln week after a 0.3 mln one), so the chip shows the
// difference in money instead and is not a toggle.
struct InsightsComparisonRow: View {
    let comparison: InsightsComparison
    let lowerIsBetter: Bool

    @State private var showsDifference = false

    private static let percentLimit = 5.0

    var body: some View {
        if let fraction = comparison.fraction {
            let isUp = comparison.current > comparison.previous
            let isFlat = abs(fraction) < 0.005
            let isGood = lowerIsBetter ? !isUp : isUp
            let tint = isFlat ? Color.SubtitleText : (isGood ? Color.IncomeGreen : Color.AlertRed)
            let isHuge = abs(fraction) > InsightsComparisonRow.percentLimit

            HStack(spacing: 8) {
                if isHuge {
                    chip(text: differenceText, isFlat: isFlat, isUp: isUp, tint: tint)
                } else {
                    Button {
                        Haptics.tap()
                        showsDifference.toggle()
                    } label: {
                        chip(text: showsDifference ? differenceText : InsightsFormat.changePercent(fraction),
                             isFlat: isFlat, isUp: isUp, tint: tint)
                    }
                    .buttonStyle(.plain)
                }

                Text("vs \(comparison.label)")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else if abs(comparison.current) > 0.000001 {
            Text("No data for \(comparison.label)")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 32, alignment: .leading)
        }
    }

    private var differenceText: String {
        MoneyFormat.compact(comparison.current - comparison.previous, sign: .always)
    }

    private func chip(text: String, isFlat: Bool, isUp: Bool, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isFlat ? "equal" : (isUp ? "arrow.up.right" : "arrow.down.right"))
                .font(.system(.caption2, design: .rounded).weight(.bold))

            Text(verbatim: text)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(tint.opacity(0.14), in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
