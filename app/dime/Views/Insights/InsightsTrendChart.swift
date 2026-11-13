//
//  InsightsTrendChart.swift
//  dime
//

import SwiftUI

// Bars per day (week, month) or per month (year). Tap to inspect a bar: the whole column is
// the target, so thin month bars need no aiming. No drag scrubbing: a drag recognizer inside
// the page ScrollView stopped the page from scrolling on device.
struct InsightsTrendChart: View {
    let data: InsightsChartData
    let selected: Int?
    let tint: Color
    let signed: Bool
    let averageTitle: LocalizedStringKey
    let onSelect: (Int?) -> Void
    let onToggleScale: () -> Void

    private let plotHeight: CGFloat = 150
    private let axisWidth: CGFloat = 42
    private let axisGap: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: axisGap) {
                plot
                axis
            }
            // Room for the value label of a clipped bar.
            .padding(.top, 18)

            xLabels

            footer
        }
    }

    // MARK: Geometry

    private var range: Double {
        max(data.top + data.bottom, 0.000001)
    }

    private func y(_ value: Double) -> CGFloat {
        plotHeight * CGFloat((data.top - value) / range)
    }

    // Hidden when it would sit above a clipped scale.
    private var visibleAverage: Double? {
        guard !signed, let average = data.average, average > 0, average <= data.top else { return nil }
        return average
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let slot = proxy.size.width / CGFloat(max(data.bars.count, 1))

            ZStack(alignment: .topLeading) {
                ForEach(data.ticks, id: \.self) { tick in
                    Rectangle()
                        .fill(Color.Outline.opacity(tick == 0 ? 1 : 0.5))
                        .frame(height: 1)
                        .offset(y: y(tick) - 0.5)
                }

                HStack(alignment: .top, spacing: 0) {
                    ForEach(data.bars) { bar in
                        barView(bar, slot: slot)
                    }
                }

                if let average = visibleAverage {
                    Line()
                        .stroke(Color.SubtitleText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
                        .frame(height: 1.5)
                        .offset(y: y(average))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: plotHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    tap(at: value.location.x, slot: slot)
                }
            )
        }
        .frame(height: plotHeight)
    }

    private func barView(_ bar: InsightsChartBar, slot: CGFloat) -> some View {
        let limit = bar.value >= 0 ? data.top : data.bottom
        let magnitude = min(abs(bar.value), limit)
        let scaled = plotHeight * CGFloat(magnitude / range)
        // A day with any spending stays visible next to a huge one.
        let height: CGFloat = bar.value == 0 ? 0 : max(scaled, 3)
        let width = max(2, min(slot * 0.7, 36))
        let isClipped = data.cappedAt != nil && bar.value > data.top
        let isDimmed = selected != nil && selected != bar.id
        let zero = y(0)
        let colour = signed ? (bar.value >= 0 ? Color.IncomeGreen : Color.AlertRed) : tint
        let showsTrack = !signed && data.bars.count <= 12

        return ZStack(alignment: .top) {
            if showsTrack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.SecondaryBackground)
                    .frame(width: width, height: plotHeight)
            }

            RoundedRectangle(cornerRadius: min(6, width / 2), style: .continuous)
                .fill(colour)
                .frame(width: width, height: height)
                .overlay(alignment: .top) {
                    if isClipped {
                        clipMark(bar, width: width)
                    }
                }
                .opacity(bar.isFuture ? 0.3 : (isDimmed ? 0.35 : 1))
                .offset(y: bar.value >= 0 ? zero - height : zero)
        }
        .frame(width: slot, height: plotHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: bar.title))
        .accessibilityValue(Text(verbatim: MoneyFormat.spoken(bar.value)))
    }

    // A cut through the bar plus its real value: this bar is taller than the scale.
    private func clipMark(_ bar: InsightsChartBar, width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.PrimaryBackground)
                .frame(width: width + 6, height: 3)
                .rotationEffect(.degrees(-18))
                .offset(y: 9)

            Text(verbatim: MoneyFormat.axis(bar.value))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(Color.PrimaryText)
                .lineLimit(1)
                .fixedSize()
                .offset(y: -15)
        }
    }

    // MARK: Axes

    private var axis: some View {
        ZStack(alignment: .topLeading) {
            ForEach(data.ticks, id: \.self) { tick in
                if !hidesTick(tick) {
                    Text(verbatim: MoneyFormat.axis(tick))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: axisWidth, height: 12, alignment: .leading)
                        .offset(y: y(tick) - 6)
                }
            }

            if let average = visibleAverage {
                Text(verbatim: MoneyFormat.axis(average))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(Color.PrimaryBackground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 3)
                    .frame(height: 14)
                    .background(Color.SubtitleText, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .frame(width: axisWidth, alignment: .leading)
                    .offset(y: y(average) - 7)
            }
        }
        .frame(width: axisWidth, height: plotHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func hidesTick(_ tick: Double) -> Bool {
        guard let average = visibleAverage else { return false }
        return abs(y(tick) - y(average)) < 13
    }

    private var xLabels: some View {
        HStack(spacing: 0) {
            ForEach(data.bars) { bar in
                // The clear box keeps every slot equal; a label may be wider than a thin month slot.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 13)
                    .overlay {
                        Text(verbatim: bar.label)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(selected == bar.id ? Color.PrimaryText : Color.SubtitleText)
                            .lineLimit(1)
                            .fixedSize()
                    }
            }
        }
        .padding(.trailing, axisWidth + axisGap)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if visibleAverage != nil {
                HStack(spacing: 5) {
                    Line()
                        .stroke(Color.SubtitleText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
                        .frame(width: 18, height: 1.5)

                    Text(averageTitle)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if data.canCap {
                Button {
                    Haptics.tap()
                    onToggleScale()
                } label: {
                    Text(data.cappedAt == nil ? "Fit typical days" : "Show full scale")
                        .underline()
                        .lineLimit(1)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(.caption, design: .rounded).weight(.medium))
        .foregroundColor(Color.SubtitleText)
        .frame(minHeight: 20)
    }

    // MARK: Selection

    private func barIndex(at x: CGFloat, slot: CGFloat) -> Int? {
        guard slot > 0, !data.bars.isEmpty, x.isFinite else { return nil }
        let index = min(max(Int(x / slot), 0), data.bars.count - 1)
        return data.bars[index].isFuture ? nil : index
    }

    private func tap(at x: CGFloat, slot: CGFloat) {
        guard let index = barIndex(at: x, slot: slot) else { return }
        Haptics.selection()
        onSelect(index == selected ? nil : index)
    }
}
