//
//  InsightsCategoryDetailView.swift
//  dime
//

import SwiftUI

// Drill-down for one category: total, comparison, bars inside the period, the last six periods,
// top notes and its transactions. Shown over the Insights page; the period navigator works here too.
struct InsightsCategoryDetailView: View {
    @ObservedObject var model: InsightsModel
    let detail: InsightsCategoryDetail
    let onOpen: (InsightsRow) -> Void

    @AppStorage("animated", store: UserDefaults.appGroup) private var animated: Bool = true

    @State private var noteFilter: String?
    @State private var bucketFilter: Int?
    @State private var showsAll = false

    private let pageSize = 40

    var body: some View {
        VStack(spacing: 0) {
            header

            InsightsPeriodNavigator(model: model)
                .padding(.leading, 30)
                .padding(.trailing, 20)
                .padding(.bottom, 6)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    totalCard
                        .padding(.horizontal, 30)

                    if detail.rows.isEmpty {
                        InsightsEmptyPeriodView(onBackToToday: backToToday)
                            .padding(.horizontal, 30)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            InsightsSectionHeader(title: detail.frame == .year ? "By month" : "By day")

                            InsightsTrendChart(
                                data: detail.chart,
                                selected: bucketFilter,
                                tint: detail.colour,
                                signed: false,
                                averageTitle: detail.frame == .year ? "Average per month" : "Average per day",
                                onSelect: { index in
                                    withAnimation(animated ? Animation.snappy(duration: 0.25) : nil) {
                                        bucketFilter = index
                                    }
                                    showsAll = false
                                }
                            )
                        }
                        .padding(.horizontal, 30)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        InsightsSectionHeader(title: "Last periods")

                        InsightsPeriodTrend(bars: detail.trend, tint: detail.colour) { bar in
                            withAnimation(animated ? Animation.snappy : nil) {
                                model.go(to: bar.period)
                            }
                        }
                    }
                    .padding(.horizontal, 30)

                    if !detail.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            InsightsSectionHeader(title: "Top notes")
                                .padding(.horizontal, 12)

                            ForEach(detail.notes) { note in
                                InsightsNoteRow(note: note, colour: detail.colour, isSelected: noteFilter == note.id) {
                                    Haptics.selection()
                                    noteFilter = noteFilter == note.id ? nil : note.id
                                    showsAll = false
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                    }

                    if !detail.rows.isEmpty {
                        transactions
                            .padding(.horizontal, 18)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.PrimaryBackground)
        .onChange(of: model.period) { _, _ in
            noteFilter = nil
            bucketFilter = nil
            showsAll = false
        }
    }

    // MARK: Pieces

    private var backToToday: (() -> Void)? {
        if model.isCurrentPeriod { return nil }
        let animation: Animation? = animated ? Animation.snappy(duration: 0.3) : nil
        let target = self.model
        return {
            withAnimation(animation) {
                target.goToCurrent()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(animated ? Animation.snappy(duration: 0.3) : nil) {
                    model.closeDetail()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .foregroundColor(Color.PrimaryText)
                    .frame(width: 34, height: 34)
                    .background(Color.SecondaryBackground, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back"))

            InsightsEmojiTile(emoji: detail.emoji, colour: detail.colour, size: 34)

            Text(verbatim: detail.name)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundColor(Color.PrimaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
        .padding(.trailing, 30)
        .padding(.top, 14)
    }

    // Same hero as the main page: on the background, no card.
    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shareText)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            AmountText(detail.total, size: 44, relativeTo: .largeTitle, weight: .regular, style: .hero,
                       secondaryRatio: 0.5, sign: .never, animated: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .amountReveal(detail.total, sign: .never)

            if let comparison = detail.comparison {
                InsightsComparisonRow(comparison: comparison, lowerIsBetter: !detail.income)
            }

            // Two per line: four amounts in one line would be cut off at 8+ digits.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    InsightsStatCell(title: detail.frame == .year ? "Per month" : "Per day") {
                        AmountText(detail.perUnit, role: .caption, sign: .never)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .amountReveal(detail.perUnit, sign: .never)
                    }

                    InsightsStatCell(title: "Transactions count") {
                        Text(verbatim: String(detail.count))
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundColor(Color.PrimaryText)
                            .lineLimit(1)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    InsightsStatCell(title: "Average transaction") {
                        AmountText(detail.average, role: .caption, sign: .never)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .amountReveal(detail.average, sign: .never)
                    }

                    InsightsStatCell(title: "Largest transaction") {
                        AmountText(detail.largest, role: .caption, sign: .never)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .amountReveal(detail.largest, sign: .never)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var shareText: LocalizedStringKey {
        let percent = InsightsFormat.percent(detail.share)
        return detail.income ? "\(percent) of income" : "\(percent) of expenses"
    }

    private var filteredRows: [InsightsRow] {
        var rows = detail.rows
        if let bucketFilter {
            rows = rows.filter { $0.bucket == bucketFilter }
        }
        if let noteFilter {
            rows = rows.filter { InsightsBuilder.noteKey($0.note) == noteFilter }
        }
        return rows
    }

    private var transactions: some View {
        let rows = filteredRows
        let shown = showsAll ? rows : Array(rows.prefix(pageSize))
        let info = model.page.info(for: detail.key)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                InsightsSectionHeader(title: "Transactions", trailing: String(rows.count))

                if noteFilter != nil || bucketFilter != nil {
                    Button {
                        Haptics.tap()
                        noteFilter = nil
                        bucketFilter = nil
                    } label: {
                        Text("Show all")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundColor(Color.SubtitleText)
                            .lineLimit(1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            if rows.isEmpty {
                InsightsEmptyPeriodView()
                    .padding(.horizontal, 12)
            }

            LazyVStack(spacing: 0) {
                ForEach(shown) { row in
                    InsightsTransactionRow(row: row, info: info, showsDay: true) {
                        onOpen(row)
                    }
                }
            }

            if rows.count > shown.count {
                InsightsWideButton(title: "Show all") {
                    Haptics.tap()
                    showsAll = true
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }
}

// The shown period and the five before it. Tap a bar to move there.
struct InsightsPeriodTrend: View {
    let bars: [InsightsTrendBar]
    let tint: Color
    let onSelect: (InsightsTrendBar) -> Void

    private let trackHeight: CGFloat = 84

    var body: some View {
        let largest = max(bars.map { $0.amount }.max() ?? 0, 0.000001)

        HStack(alignment: .bottom, spacing: 6) {
            ForEach(bars) { bar in
                Button {
                    onSelect(bar)
                } label: {
                    VStack(spacing: 5) {
                        Text(verbatim: MoneyFormat.axis(bar.amount))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(bar.isCurrent ? Color.PrimaryText : Color.SubtitleText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.SecondaryBackground)
                                .frame(height: trackHeight)

                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(tint.opacity(bar.isCurrent ? 1 : 0.4))
                                .frame(height: bar.amount > 0 ? max(4, trackHeight * CGFloat(bar.amount / largest)) : 0)
                        }

                        Text(verbatim: bar.label)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(bar.isCurrent ? Color.PrimaryText : Color.SubtitleText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(InsightsPressStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: bar.label))
                .accessibilityValue(Text(verbatim: MoneyFormat.spoken(bar.amount)))
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}

struct InsightsEmptyPeriodView: View {
    var onBackToToday: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)
                .frame(width: 52, height: 52)
                .background(Color.SecondaryBackground, in: Circle())
                .accessibilityHidden(true)

            Text("No transactions in this period")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .multilineTextAlignment(.center)

            if let onBackToToday {
                Button(action: onBackToToday) {
                    Text("Back to today")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Color.SecondaryBackground, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InsightsPressStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
