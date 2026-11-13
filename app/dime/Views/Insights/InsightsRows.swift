//
//  InsightsRows.swift
//  dime
//

import SwiftUI

// One ranked category: tile, name, amount, share and a bar scaled to the largest category.
// The whole row is the button.
struct InsightsCategoryRow: View {
    let slice: InsightsSlice
    let isSelected: Bool
    let isDimmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                InsightsEmojiTile(emoji: slice.emoji, colour: slice.colour, size: 38)

                // Name gets its own line: 7-8 digit UZS amounts used to squeeze it to a few letters.
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: slice.name)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        AmountText(slice.amount, role: .caption, sign: .never)
                            .layoutPriority(1)

                        Spacer(minLength: 4)

                        Text(verbatim: InsightsFormat.percent(slice.share))
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundColor(Color.SubtitleText)
                            .lineLimit(1)
                            .frame(minWidth: 38, alignment: .trailing)
                    }

                    InsightsProportionBar(fraction: slice.relative, colour: slice.colour)
                }

                Image(systemName: "chevron.right")
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .foregroundColor(Color.SubtitleText.opacity(isSelected ? 1 : 0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(isSelected ? Color.SecondaryBackground : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.Outline, lineWidth: 1.3)
                }
            }
            .opacity(isDimmed ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(InsightsPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: slice.name))
        .accessibilityValue(Text(verbatim: MoneyFormat.spoken(slice.amount) + ", " + InsightsFormat.percent(slice.share)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                    .fill(Color.Outline)

                Capsule()
                    .fill(colour)
                    .frame(width: max(5, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 5)
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
