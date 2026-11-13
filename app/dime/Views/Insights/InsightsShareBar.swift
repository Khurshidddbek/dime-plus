//
//  InsightsShareBar.swift
//  dime
//

import SwiftUI

// Category shares as one bar. Small categories keep a minimum width and the whole 48 pt band
// is one hit area mapped to the nearest segment, so nothing is too thin to tap.
// Tap only: a drag recognizer inside the page ScrollView stopped the page from scrolling on device.
struct InsightsShareBar: View {
    let segments: [InsightsShareSegment]
    let selected: InsightsCategoryKey?
    let onSelect: (InsightsShareSegment) -> Void

    private let segmentHeight: CGFloat = 18
    private let selectedHeight: CGFloat = 26
    private let hitHeight: CGFloat = 48
    private let gap: CGFloat = 3
    private let minimumWidth: CGFloat = 14

    // Proportional widths, but never thinner than minWidth. The surplus comes from segments that have slack.
    static func widths(shares: [Double], available: CGFloat, gap: CGFloat, minWidth: CGFloat) -> [CGFloat] {
        guard !shares.isEmpty, available > 0 else { return shares.map { _ in 0 } }

        let cleaned = shares.map { $0.isFinite ? max($0, 0) : 0 }
        let sum = cleaned.reduce(0, +)
        let usable = max(0, available - gap * CGFloat(shares.count - 1))
        guard sum > 0 else { return shares.map { _ in usable / CGFloat(shares.count) } }

        let floorWidth = min(minWidth, usable / CGFloat(shares.count))
        var widths = cleaned.map { max(floorWidth, usable * CGFloat($0 / sum)) }
        let excess = widths.reduce(0, +) - usable
        let slack = widths.map { max(0, $0 - floorWidth) }
        let totalSlack = slack.reduce(0, +)

        if excess > 0, totalSlack > 0 {
            for index in widths.indices {
                widths[index] -= excess * slack[index] / totalSlack
            }
        }
        return widths
    }

    var body: some View {
        GeometryReader { proxy in
            let widths = InsightsShareBar.widths(shares: segments.map { $0.share }, available: proxy.size.width,
                                                 gap: gap, minWidth: minimumWidth)

            HStack(alignment: .center, spacing: gap) {
                ForEach(segments) { segment in
                    // The selected segment grows a little instead of getting a heavy outline.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(segment.colour)
                        .frame(width: segment.id < widths.count ? widths[segment.id] : 0,
                               height: isSelected(segment) ? selectedHeight : segmentHeight)
                        .opacity(isDimmed(segment) ? 0.3 : 1)
                }
            }
            .frame(width: proxy.size.width, height: hitHeight, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard let index = segmentIndex(at: value.location.x, widths: widths) else { return }
                    onSelect(segments[index])
                }
            )
        }
        .frame(height: hitHeight)
        // The ranked list right below carries the same information for VoiceOver.
        .accessibilityHidden(true)
    }

    private func isSelected(_ segment: InsightsShareSegment) -> Bool {
        guard let selected, let key = segment.key else { return false }
        return key == selected
    }

    private func isDimmed(_ segment: InsightsShareSegment) -> Bool {
        return selected != nil && !isSelected(segment)
    }

    // Gaps and the area above and below the bar all count: the nearest segment wins.
    private func segmentIndex(at x: CGFloat, widths: [CGFloat]) -> Int? {
        guard !widths.isEmpty, widths.count == segments.count else { return nil }
        var edge: CGFloat = 0
        for (index, width) in widths.enumerated() {
            edge += width + gap
            if x < edge - gap / 2 {
                return index
            }
        }
        return widths.count - 1
    }
}
