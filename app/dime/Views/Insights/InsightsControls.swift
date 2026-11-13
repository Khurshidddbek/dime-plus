//
//  InsightsControls.swift
//  dime
//

import SwiftUI

struct InsightsSegmentItem: Identifiable {
    let id: Int
    let title: LocalizedStringKey
}

// Small inline pill. The visible pill is 34 pt, every segment still has a 44 pt hit area.
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
                        .padding(.horizontal, 12)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: 28)
                        .background {
                            if item.id == selection {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.PrimaryBackground)
                                    .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
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
                .frame(height: 34)
        }
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }
}

// "week" pill with a menu, the same control the original Insights header had.
struct InsightsScopeMenu: View {
    @ObservedObject var model: InsightsModel

    @AppStorage("animated", store: UserDefaults.appGroup) private var animated: Bool = true

    private var selection: Binding<ChartTimeFrame> {
        Binding(
            get: { model.frame },
            set: { newFrame in
                withAnimation(animated ? Animation.snappy(duration: 0.3) : nil) {
                    model.setFrame(newFrame)
                }
            }
        )
    }

    var body: some View {
        Menu {
            Picker(selection: selection) {
                Text("Week").tag(ChartTimeFrame.week)
                Text("Month").tag(ChartTimeFrame.month)
                Text("Year").tag(ChartTimeFrame.year)
            } label: {
                EmptyView()
            }
        } label: {
            HStack(spacing: 5) {
                Text(LocalizedStringKey(model.frame.rawValue))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
            }
            .foregroundColor(Color.PrimaryText.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(LocalizedStringKey(model.frame.rawValue)))
    }
}

// "9 Nov - 15 Nov" on the left, the two arrows on the right. Tapping the title returns to the current period.
struct InsightsPeriodNavigator: View {
    @ObservedObject var model: InsightsModel

    @AppStorage("animated", store: UserDefaults.appGroup) private var animated: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(animated ? Animation.snappy(duration: 0.3) : nil) {
                    model.goToCurrent()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(model.periodTitle)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.opacity)

                    if !model.isCurrentPeriod {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(.caption2, design: .rounded).weight(.bold))
                            Text("Back to today")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(Color.SubtitleText)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.SecondaryBackground, in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Not .disabled: a disabled plain button greys the title in the default state.
            // goToCurrent() is a no-op on the current period.
            .accessibilityLabel(Text(model.periodTitle))
            .accessibilityHint(model.isCurrentPeriod ? Text(verbatim: "") : Text("Back to today"))

            stepButton(systemName: "chevron.left", enabled: model.canGoBack, label: "Previous period", direction: -1)
            stepButton(systemName: "chevron.right", enabled: model.canGoForward, label: "Next period", direction: 1)
        }
    }

    // Not disabled at the ends on purpose: the model answers with a rigid haptic there.
    private func stepButton(systemName: String, enabled: Bool, label: LocalizedStringKey, direction: Int) -> some View {
        Button {
            withAnimation(animated ? Animation.snappy(duration: 0.3) : nil) {
                model.step(direction)
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .foregroundColor(Color.PrimaryText)
                .frame(width: 34, height: 34)
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
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(Color.PrimaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            if let trailing {
                Text(verbatim: trailing)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
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
