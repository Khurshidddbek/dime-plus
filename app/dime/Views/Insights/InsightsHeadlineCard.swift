//
//  InsightsHeadlineCard.swift
//  dime
//

import SwiftUI

// One big number at a time: the period total, or the selected day / category.
struct InsightsHeadlineCard: View {
    let page: InsightsPage
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.scopeTitle)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)

                    if let detail = page.scopeDetail {
                        Text(detail)
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .foregroundColor(Color.SubtitleText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if page.hasSelection {
                    Button(action: onClear) {
                        Image(systemName: "xmark")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundColor(Color.SubtitleText)
                            .frame(width: 28, height: 28)
                            .background(Color.SecondaryBackground, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear selection"))
                }
            }
            .frame(minHeight: 44)

            AmountText(page.total, size: 40, relativeTo: .largeTitle, weight: .medium, style: .hero,
                       secondaryRatio: 0.55, sign: page.flow == .net ? .always : .never, animated: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .amountReveal(page.total, sign: page.flow == .net ? .always : .never)

            if let comparison = page.comparison {
                InsightsComparisonRow(comparison: comparison, lowerIsBetter: page.flow == .expense)
            }

            HStack(alignment: .top, spacing: 10) {
                InsightsStatCell(title: averageTitle) {
                    AmountText(page.average, role: .caption, sign: page.flow == .net ? .automatic : .never)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .amountReveal(page.average, sign: page.flow == .net ? .automatic : .never)
                }

                InsightsStatCell(title: "Transactions") {
                    Text(verbatim: String(page.count))
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)
                }

                InsightsStatCell(title: "Largest") {
                    AmountText(page.largest, role: .caption, sign: .never)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .amountReveal(page.largest, sign: .never)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color.TertiaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var averageTitle: LocalizedStringKey {
        switch page.averageKind {
        case .perDay: return "Per day"
        case .perMonth: return "Per month"
        case .perTransaction: return "Average"
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
    }
}

// Like-for-like change: the same number of days of the previous period.
struct InsightsComparisonRow: View {
    let comparison: InsightsComparison
    let lowerIsBetter: Bool

    @State private var showsDifference = false

    var body: some View {
        if let fraction = comparison.fraction {
            let isUp = comparison.current > comparison.previous
            let isFlat = abs(fraction) < 0.005
            let isGood = lowerIsBetter ? !isUp : isUp
            let tint = isFlat ? Color.SubtitleText : (isGood ? Color.IncomeGreen : Color.AlertRed)

            HStack(spacing: 8) {
                Button {
                    Haptics.tap()
                    showsDifference.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isFlat ? "equal" : (isUp ? "arrow.up.right" : "arrow.down.right"))
                            .font(.system(.caption, design: .rounded).weight(.bold))

                        Text(verbatim: chipText(fraction))
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .foregroundColor(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
        }
    }

    private func chipText(_ fraction: Double) -> String {
        if showsDifference {
            return MoneyFormat.compact(abs(comparison.current - comparison.previous), sign: .never)
        }
        return InsightsFormat.changePercent(fraction)
    }
}
