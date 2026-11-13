//
//  InsightsTrendChart.swift
//  dime
//

import SwiftUI

// Bars per day (week, month) or per month (year), in the original Dime look: grey tracks, dark bars,
// a dashed average labelled once on the axis. One huge day is clipped with a break mark and its real
// value on top, so the other bars stay readable. Tap a bar (the whole column is the target) to see
// its value in a callout above the plot. No drag scrubbing: a drag recognizer inside the page
// ScrollView stopped the page from scrolling on device.
struct InsightsTrendChart: View {
    let data: InsightsChartData
    let selected: Int?
    let tint: Color
    let signed: Bool
    let averageTitle: LocalizedStringKey
    let onSelect: (Int?) -> Void
    // Year view: the callout of a selected month becomes a button that opens that month.
    var onOpenSelected: (() -> Void)?

    private let plotHeight: CGFloat = 156
    private let bandHeight: CGFloat = 34
    private let labelHeight: CGFloat = 14
    private let labelGap: CGFloat = 6
    private let axisWidth: CGFloat = 44
    private let axisGap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let plotWidth = max(proxy.size.width - axisWidth - axisGap, 1)
            let slot = plotWidth / CGFloat(max(data.bars.count, 1))

            VStack(alignment: .leading, spacing: 0) {
                band(width: proxy.size.width, slot: slot)
                    .frame(width: proxy.size.width, height: bandHeight)

                HStack(alignment: .top, spacing: axisGap) {
                    plot(width: plotWidth, slot: slot)
                    axis
                }

                xLabels(slot: slot)
                    .frame(width: plotWidth, height: labelHeight)
                    .padding(.top, labelGap)
            }
        }
        .frame(height: bandHeight + plotHeight + labelGap + labelHeight)
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

    private func isClipped(_ bar: InsightsChartBar) -> Bool {
        data.cappedAt != nil && bar.value > data.top
    }

    private var selectedBar: InsightsChartBar? {
        guard let selected, selected >= 0, selected < data.bars.count else { return nil }
        return data.bars[selected]
    }

    // MARK: Plot

    private func plot(width: CGFloat, slot: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(data.ticks, id: \.self) { tick in
                Rectangle()
                    .fill(Color.Outline.opacity(tick == 0 ? 1 : 0.45))
                    .frame(width: width, height: 1)
                    .offset(y: y(tick) - 0.5)
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(data.bars) { bar in
                    barView(bar, slot: slot)
                }
            }

            if let average = visibleAverage {
                Line()
                    .stroke(Color.SubtitleText.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))
                    .frame(width: width, height: 1.5)
                    .offset(y: y(average) - 0.75)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: plotHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { value in
                tap(at: value.location.x, slot: slot)
            }
        )
    }

    private func barView(_ bar: InsightsChartBar, slot: CGFloat) -> some View {
        let limit = bar.value >= 0 ? data.top : data.bottom
        let magnitude = min(abs(bar.value), limit)
        let scaled = plotHeight * CGFloat(magnitude / range)
        // A day with any spending stays visible next to a huge one.
        let height: CGFloat = bar.value == 0 ? 0 : max(scaled, 4)
        let width = max(2, min(slot * 0.68, 34))
        let radius = min(7, width / 2)
        let isDimmed = selected != nil && selected != bar.id
        let zero = y(0)
        let colour = signed ? (bar.value >= 0 ? Color.IncomeGreen : Color.AlertRed) : tint
        let showsTrack = !signed && data.bars.count <= 12

        return ZStack(alignment: .top) {
            if showsTrack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.SecondaryBackground)
                    .frame(width: width, height: plotHeight)
            }

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(colour)
                .frame(width: width, height: height)
                .overlay(alignment: .top) {
                    if isClipped(bar) {
                        breakMark(width: width)
                    }
                }
                .opacity(bar.isFuture ? 0.3 : (isDimmed ? 0.3 : 1))
                .offset(y: bar.value >= 0 ? zero - height : zero)
        }
        .frame(width: slot, height: plotHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: bar.title))
        .accessibilityValue(Text(verbatim: MoneyFormat.spoken(bar.value)))
        .accessibilityAddTraits(selected == bar.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            guard !bar.isFuture else { return }
            onSelect(bar.id == selected ? nil : bar.id)
        }
    }

    // Two thin cuts near the top: this bar is taller than the scale.
    private func breakMark(width: CGFloat) -> some View {
        VStack(spacing: 2.5) {
            Rectangle()
                .fill(Color.PrimaryBackground)
                .frame(width: width + 4, height: 2)
            Rectangle()
                .fill(Color.PrimaryBackground)
                .frame(width: width + 4, height: 2)
        }
        .rotationEffect(.degrees(-14))
        .offset(y: 12)
        .allowsHitTesting(false)
    }

    // MARK: Band above the plot

    @ViewBuilder
    private func band(width: CGFloat, slot: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let bar = selectedBar {
                callout(bar, width: width, x: slot * (CGFloat(bar.id) + 0.5))
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            } else {
                ForEach(data.bars.filter { isClipped($0) }) { bar in
                    Text(verbatim: MoneyFormat.axis(bar.value))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: slot)
                        .offset(x: slot * CGFloat(bar.id), y: -4)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: width, height: bandHeight, alignment: .bottomLeading)
    }

    // The callout is kept inside the chart: left aligned near the left edge, right aligned near the right one.
    private func callout(_ bar: InsightsChartBar, width: CGFloat, x: CGFloat) -> some View {
        let alignment: Alignment
        let shift: CGFloat
        if x < width * 0.35 {
            alignment = .bottomLeading
            shift = max(0, x - 28)
        } else if x > width * 0.65 {
            alignment = .bottomTrailing
            shift = -max(0, width - x - 28)
        } else {
            alignment = .bottom
            shift = x - width / 2
        }

        return calloutBody(bar)
            .offset(x: shift, y: -4)
            .frame(width: width, height: bandHeight, alignment: alignment)
    }

    @ViewBuilder
    private func calloutBody(_ bar: InsightsChartBar) -> some View {
        let content = HStack(spacing: 6) {
            Text(verbatim: bar.title)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)

            Text(verbatim: MoneyFormat.string(bar.value, sign: signed ? .always : .never))
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundColor(Color.PrimaryText)

            if onOpenSelected != nil {
                Image(systemName: "chevron.right")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundColor(Color.SubtitleText)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.SecondaryBackground, in: Capsule())
        .overlay(Capsule().stroke(Color.Outline, lineWidth: 1))
        .fixedSize()

        if let onOpenSelected {
            Button(action: onOpenSelected) {
                content
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(InsightsPressStyle())
            .accessibilityLabel(Text("Open \(bar.title)"))
        } else {
            content
                .accessibilityHidden(true)
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
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(Color.SubtitleText, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .frame(width: axisWidth, alignment: .leading)
                    .offset(y: y(average) - 7.5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(averageTitle))
                    .accessibilityValue(Text(verbatim: MoneyFormat.spoken(average)))
            }
        }
        .frame(width: axisWidth, height: plotHeight, alignment: .topLeading)
    }

    private func hidesTick(_ tick: Double) -> Bool {
        guard let average = visibleAverage else { return false }
        return abs(y(tick) - y(average)) < 14
    }

    private func xLabels(slot: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(data.bars) { bar in
                // The clear box keeps every slot equal; a label may be wider than a thin month slot.
                Color.clear
                    .frame(width: slot, height: labelHeight)
                    .overlay {
                        Text(verbatim: bar.label)
                            .font(.system(size: 10, weight: selected == bar.id ? .bold : .semibold, design: .rounded))
                            .foregroundColor(selected == bar.id ? Color.PrimaryText : Color.SubtitleText)
                            .lineLimit(1)
                            .fixedSize()
                    }
            }
        }
        .accessibilityHidden(true)
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
