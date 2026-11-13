//
//  LineGraph.swift
//  dime
//
//  Created by Rafael Soh on 25/11/22.
//

import Foundation
import SwiftUI

/// The small graph under the Log header. It shows how the header number built up over the
/// selected period: it starts at 0 on the first day and ends exactly on the big number.
enum LogGraphSeries {
    /// rows: LogFeed.current (newest first). insightsType: 1 net, 2 income, 3 spent.
    /// timeframe: 1 today (by hour), 2 week and 3 month (by day), 4 year and 5 all time (by month).
    static func build(rows: [LogRowModel], insightsType: Int, timeframe: Int, now: Date = Date.now) -> [LineGraphDataPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = UserDefaults.appGroup.storedFirstWeekday
        calendar.minimumDaysInFirstWeek = 4

        let start: Date

        if let periodStart = LogFeed.periodStart(timeframe: timeframe, now: now) {
            start = periodStart
        } else {
            guard let oldest = rows.last?.date else {
                return []
            }

            start = calendar.dateInterval(of: .month, for: oldest)?.start ?? oldest
        }

        let step: Calendar.Component
        switch timeframe {
        case 1:
            step = .hour
        case 2, 3:
            step = .day
        default:
            step = .month
        }

        var bucketStarts = [start]
        var cursor = start

        // The cap only guards against a broken calendar; 400 months is 33 years.
        while bucketStarts.count < 400,
              let next = calendar.date(byAdding: step, value: 1, to: cursor),
              next <= now,
              next > cursor {
            bucketStarts.append(next)
            cursor = next
        }

        var sums = Array(repeating: 0.0, count: bucketStarts.count)
        var bucket = 0

        // Same rows and the same cut as LogFeed.totals, so the line ends on the header number.
        for row in rows.prefix(while: { $0.date >= start }).reversed() {
            let value: Double

            switch insightsType {
            case 2:
                guard row.income else { continue }
                value = row.amount
            case 3:
                guard !row.income else { continue }
                value = row.amount
            default:
                value = row.signedAmount
            }

            while bucket + 1 < bucketStarts.count, row.date >= bucketStarts[bucket + 1] {
                bucket += 1
            }

            sums[bucket] += value
        }

        var points = [LineGraphDataPoint(date: start, amount: 0)]
        var running = 0.0

        for index in bucketStarts.indices {
            running += sums[index]
            points.append(LineGraphDataPoint(date: bucketStarts[index], amount: running))
        }

        return points
    }

    /// The label under a point: hour for today, day for week and month, month for longer periods.
    static func label(for date: Date, timeframe: Int) -> String {
        switch timeframe {
        case 1:
            return date.formatted(.dateTime.hour().minute())
        case 2, 3:
            return date.formatted(.dateTime.day().month(.abbreviated))
        case 4:
            return date.formatted(.dateTime.month(.abbreviated))
        default:
            return date.formatted(.dateTime.month(.abbreviated).year())
        }
    }
}

struct LineGraph: View {
    /// The first point is the 0 the period starts from, then one point per hour, day or month.
    var data: [LineGraphDataPoint]
    var color: Color
    var timeframe: Int
    var sign: MoneySign
    var showsZeroLine: Bool

    @State var currentPlot: LineGraphDataPoint?

    @State var offset: CGSize = .zero

    @State var showPlot = false

    @GestureState var isDrag: Bool = false

    @State var graphProgress: CGFloat = 0

    private let tooltipWidth: CGFloat = 104
    // Keeps the stroke and the end dot inside the frame.
    private let verticalInset: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let fullHeight = proxy.size.height
            let height = max(fullHeight - verticalInset * 2, 1)
            let step = data.count > 1 ? proxy.size.width / CGFloat(data.count - 1) : 0
            let values = data.map { $0.amount }

            // 0 is always in range: the line starts there.
            let maxPoint = max(values.max() ?? 0, 0)
            let minPoint = min(values.min() ?? 0, 0)
            let spread = maxPoint - minPoint

            let yFor: (Double) -> CGFloat = { value in
                let progress = spread > 0 ? (value - minPoint) / spread : 0.5
                return verticalInset + height - CGFloat(progress) * height
            }

            let points = data.enumerated().map { item in
                CGPoint(x: step * CGFloat(item.offset), y: yFor(item.element.amount))
            }

            ZStack(alignment: .topLeading) {
                if showsZeroLine && spread > 0 {
                    let zeroY = yFor(0)

                    Path { path in
                        path.move(to: CGPoint(x: 0, y: zeroY))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: zeroY))
                    }
                    .stroke(Color.Outline, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 4]))
                }

                AnimatedGraphPath(progress: graphProgress, points: points)
                    .fill(color)

                if let last = points.last, points.count > 1 {
                    Circle()
                        .fill(color)
                        .overlay(Circle().stroke(Color.PrimaryBackground, lineWidth: 2))
                        .frame(width: 9, height: 9)
                        .position(last)
                        .opacity(graphProgress >= 1 ? 1 : 0)
                }
            }
            .overlay(
                VStack(spacing: 0) {
                    VStack(spacing: 1) {
                        Text(currentPlot.map { LogGraphSeries.label(for: $0.date, timeframe: timeframe) } ?? "")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(Color.SubtitleText)

                        Text(currentPlot.map { MoneyFormat.compact($0.amount, sign: sign) } ?? "")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.PrimaryText)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 33)
                    .padding(.horizontal, 7)
                    .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 4)

                    DottedLine()
                        .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 2.5, height: 25)
                        .foregroundColor(color)

                    Circle()
                        .stroke(Color.PrimaryBackground, lineWidth: 2.5)
                        .background(Circle().fill(color))
                        .frame(width: 14, height: 11)
                }
                .frame(width: tooltipWidth)
                .offset(y: 5.5)
                .offset(offset)
                .opacity(showPlot ? 1 : 0)
                .allowsHitTesting(false),

                alignment: .bottomLeading
            )
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                let location = value.location.x

                // Point 0 is the starting 0, the tooltip begins at the first real hour, day or month.
                guard step > 0, data.count > 1, location.isFinite else { return }
                let index = max(min(Int((location / step).rounded()), data.count - 1), 1)
                guard index < points.count else { return }

                if currentPlot != data[index] {
                    Haptics.selection()
                }

                withAnimation { showPlot = true }
                currentPlot = data[index]
                offset = CGSize(width: points[index].x - tooltipWidth / 2, height: points[index].y - fullHeight)

            }.onEnded { _ in
                withAnimation { showPlot = false }
            }.updating($isDrag) { _, out, _ in
                out = true
            })
        }
        .onChange(of: isDrag) { _ in
            if !isDrag {
                showPlot = false
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 1.2)) {
                    graphProgress = 1
                }
            }
        }
        .onChange(of: data) { _ in
            graphProgress = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 1.2)) {
                    graphProgress = 1
                }
            }
        }
    }
}

// MARK: Animated Path

struct AnimatedGraphPath: Shape {
    var progress: CGFloat
    var points: [CGPoint]
    var animatableData: CGFloat {
        get { return progress }
        set { progress = newValue }
    }

    func path(in _: CGRect) -> Path {
        Path { path in
            guard let first = points.first else { return }

            path.move(to: first)
            path.addLines(points)
        }
        .trimmedPath(from: 0, to: progress)
        .strokedPath(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}

struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width / 2, y: 0))
        path.addLine(to: CGPoint(x: rect.width / 2, y: rect.height))
        return path
    }
}
