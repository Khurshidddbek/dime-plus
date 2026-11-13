//
//  InsightsRows.swift
//  dime
//

import SwiftUI

// One ranked category: tile, full name (two lines), percent, amount and a thin bar scaled to the
// largest category. The first tap selects it (chart and share bar follow), the second tap or the
// round arrow that appears on the selected row opens the category screen.
struct InsightsCategoryRow: View {
    let slice: InsightsSlice
    let isSelected: Bool
    let isDimmed: Bool
    let action: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                content
            }
            .buttonStyle(InsightsPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: slice.name))
            .accessibilityValue(Text(verbatim: MoneyFormat.spoken(slice.amount) + ", " + InsightsFormat.percent(slice.share)))
            .accessibilityHint(isSelected ? Text("Tap again to open") : Text(verbatim: ""))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            if isSelected {
                Button(action: onOpen) {
                    Image(systemName: "chevron.right")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundColor(Color.PrimaryText)
                        .frame(width: 32, height: 32)
                        .background(Color.PrimaryBackground, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InsightsPressStyle())
                .accessibilityLabel(Text("Open category"))
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isSelected ? 4 : 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(isSelected ? Color.SecondaryBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(isDimmed ? 0.5 : 1)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            InsightsEmojiTile(emoji: slice.emoji, colour: slice.colour, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: slice.name)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(verbatim: InsightsFormat.percent(slice.share))
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                        .fixedSize()
                }

                AmountText(slice.amount, role: .caption, sign: .never, color: Color.PrimaryText.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)

                InsightsProportionBar(fraction: slice.relative, colour: slice.colour)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct InsightsProportionBar: View {
    let fraction: Double
    let colour: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // Outline, not SecondaryBackground: a selected row already sits on SecondaryBackground.
                Capsule()
                    .fill(Color.Outline.opacity(0.7))

                Capsule()
                    .fill(colour)
                    .frame(width: max(4, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 4)
    }
}

// Compact transaction row built from the value snapshot. Tapping opens the editor.
struct InsightsTransactionRow: View {
    let row: InsightsRow
    let info: InsightsCategoryInfo
    let showsDay: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                InsightsEmojiTile(emoji: info.emoji, colour: info.colour, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)

                    Text(verbatim: subtitle)
                        .font(.system(.footnote, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                AmountText(row.amount, role: .caption, sign: row.income ? .plus : .never, fit: .fullOnly,
                           color: row.income ? Color.IncomeGreen : Color.PrimaryText)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(InsightsPressStyle())
    }

    private var title: String {
        let note = row.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? info.name : note
    }

    private var subtitle: String {
        let moment = showsDay ? InsightsFormat.day(row.date) : InsightsFormat.time(row.date)
        let note = row.note.trimmingCharacters(in: .whitespacesAndNewlines)
        // The category name is already the title when there is no note.
        return note.isEmpty ? moment : info.name + ", " + moment
    }
}

struct InsightsNoteRow: View {
    let note: InsightsNoteStat
    let colour: Color
    let isSelected: Bool
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(InsightsPressStyle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: note.title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)

                Text(verbatim: "x" + String(note.count))
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                AmountText(note.amount, role: .caption, sign: .never)
                    .layoutPriority(1)
            }

            InsightsProportionBar(fraction: note.relative, colour: colour)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(isSelected ? Color.SecondaryBackground : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.Outline, lineWidth: 1.3)
            }
        }
        .contentShape(Rectangle())
    }
}

// Full-width secondary action, 44 pt tall.
struct InsightsWideButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: "chevron.right")
                    .font(.system(.caption, design: .rounded).weight(.bold))
            }
            .foregroundColor(Color.PrimaryText)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(InsightsPressStyle())
    }
}
