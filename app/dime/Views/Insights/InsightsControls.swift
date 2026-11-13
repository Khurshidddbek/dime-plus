//
//  InsightsControls.swift
//  dime
//

import SwiftUI

struct InsightsSegmentItem: Identifiable {
    let id: Int
    let title: LocalizedStringKey
}

// Inline segmented pill: one tap, no popover. Every segment is a 44 pt target.
struct InsightsSegmentedControl: View {
    let items: [InsightsSegmentItem]
    let selection: Int
    let fillsWidth: Bool
    let onSelect: (Int) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    Text(item.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundColor(item.id == selection ? Color.PrimaryText : Color.SubtitleText)
                        .padding(.horizontal, 11)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: 30)
                        .background {
                            if item.id == selection {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.PrimaryBackground)
                                    .matchedGeometryEffect(id: "thumb", in: namespace)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.id == selection ? .isSelected : [])
            }
        }
        .padding(.horizontal, 3)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.SecondaryBackground)
                .frame(height: 36)
        }
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }
}

// "<  November 2026  >". Tapping the title returns to the current period.
struct InsightsPeriodNavigator: View {
    @ObservedObject var model: InsightsModel

    @AppStorage("animated", store: UserDefaults.appGroup) private var animated: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            stepButton(systemName: "chevron.left", enabled: model.canGoBack, label: "Previous period", direction: -1)

            Button {
                withAnimation(animated ? Animation.snappy : nil) {
                    model.goToCurrent()
                }
            } label: {
                VStack(spacing: 1) {
                    Text(model.periodTitle)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if !model.isCurrentPeriod {
                        Text("Back to today")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundColor(Color.SubtitleText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isCurrentPeriod)

            stepButton(systemName: "chevron.right", enabled: model.canGoForward, label: "Next period", direction: 1)
        }
    }

    // Not disabled at the ends on purpose: the model answers with a rigid haptic there.
    private func stepButton(systemName: String, enabled: Bool, label: LocalizedStringKey, direction: Int) -> some View {
        Button {
            withAnimation(animated ? Animation.snappy : nil) {
                model.step(direction)
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundColor(Color.PrimaryText)
                .frame(width: 32, height: 32)
                .background(Color.SecondaryBackground, in: Circle())
                .opacity(enabled ? 1 : 0.35)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

struct InsightsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct InsightsSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundColor(Color.PrimaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// Same look as the tile in the Log rows.
struct InsightsEmojiTile: View {
    let emoji: String
    let colour: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(blend(over: colour, withAlpha: 0.73))

            if emoji.isEmpty {
                Image(systemName: "questionmark")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.black.opacity(0.55))
            } else {
                Text(emoji)
                    .font(.system(size: size * 0.52))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
