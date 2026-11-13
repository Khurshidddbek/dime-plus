//
//  SMSComponents.swift
//  dime
//
//  Small pieces shared by the SMS screens, in the look the rest of the app has.
//

import SwiftUI

enum SMSFormat {
    /// "-42 000 so'm" in the app currency, "45.99 USD" for another one (the app formatter
    /// would print the wrong symbol next to a foreign amount).
    static func amountText(_ parsed: ParsedSMS) -> String {
        guard let minor = parsed.amountMinor else {
            return ""
        }

        let value = Double(abs(minor)) / 100
        var sign = MoneySign.never

        if let direction = parsed.direction {
            sign = direction == .income ? .plus : .minus
        }

        if isForeign(parsed), let currency = parsed.currency {
            return MoneyFormat.number(value, fractionDigits: 2, sign: sign) + " " + currency
        }

        return MoneyFormat.string(SMSIngestor.amount(for: parsed), sign: sign)
    }

    static func isForeign(_ parsed: ParsedSMS) -> Bool {
        guard let currency = parsed.currency else {
            return false
        }

        return currency != SMSIngestor.appCurrency
    }

    /// "12 Mar, 16:06"
    static func dateText(_ date: Date) -> String {
        Fmt.string(.dayMonth, from: date) + ", " + Fmt.time(date)
    }

    static func title(_ parsed: ParsedSMS) -> String {
        if !parsed.merchantDisplay.isEmpty {
            return parsed.merchantDisplay
        }

        switch parsed.kind {
        case .atmWithdrawal: return String(localized: "Cash withdrawal")
        case .topUp: return String(localized: "Top-up")
        case .transfer: return String(localized: "Transfer")
        case .refund: return String(localized: "Refund")
        default: return String(localized: "Bank message")
        }
    }

    /// "Humo *4417, 12 Mar, 16:06"
    static func subtitle(_ parsed: ParsedSMS, cards: SMSCardStore) -> String {
        let card = cards.displayName(for: parsed.cardLast4)
        let date = dateText(parsed.date)

        return card.isEmpty ? date : card + ", " + date
    }
}

/// Centred title, round button on the left, optional control on the right.
struct SMSScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let closeIcon: String
    let onClose: () -> Void
    let trailing: Trailing

    init(
        _ title: LocalizedStringKey, closeIcon: String = "chevron.left", onClose: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.closeIcon = closeIcon
        self.onClose = onClose
        self.trailing = trailing()
    }

    var body: some View {
        Text(title)
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundColor(Color.PrimaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .leading) {
                Button {
                    onClose()
                } label: {
                    SMSRoundIcon(systemName: closeIcon)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back"))
            }
            .overlay(alignment: .trailing) {
                trailing
            }
            .accessibilityAddTraits(.isHeader)
    }
}

extension SMSScreenHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, closeIcon: String = "chevron.left", onClose: @escaping () -> Void) {
        self.init(title, closeIcon: closeIcon, onClose: onClose) {
            EmptyView()
        }
    }
}

struct SMSRoundIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundColor(Color.SubtitleText)
            .frame(width: 32, height: 32)
            .background(Color.SecondaryBackground, in: Circle())
    }
}

/// Day-header style title of a group: "SUGGESTIONS 3".
struct SMSGroupTitle: View {
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .textCase(.uppercase)

            if count > 0 {
                Text("\(count)")
            }
        }
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .foregroundColor(Color.SubtitleText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Emoji + name on the category colour. Without a category: an outlined "Category" pill.
struct SMSCategoryChip: View {
    let category: SMSCategoryInfo?
    var selected: Bool = false
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let category = category {
                Text(category.emoji)
                    .font(.system(.footnote))

                Text(category.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color(hex: category.colour))
                    .lineLimit(1)
            } else {
                Text("No category")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)
            }

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundColor(category.map { Color(hex: $0.colour) } ?? Color.SubtitleText)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background {
            if let category = category {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(hex: category.colour).opacity(0.23))
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.Outline, lineWidth: 1.5)
            }
        }
        .overlay {
            if selected, let category = category {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(hex: category.colour), lineWidth: 1.5)
            }
        }
    }
}

/// One scrolling row of category chips: a category is picked with a single tap.
struct SMSCategoryQuickPicker: View {
    let categories: [SMSCategoryInfo]
    let selectedID: UUID?
    let onPick: (SMSCategoryInfo) -> Void

    var body: some View {
        if categories.isEmpty {
            Text("No categories of this type yet. Add one in the Categories screen.")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories) { category in
                        Button {
                            Haptics.selection()
                            onPick(category)
                        } label: {
                            SMSCategoryChip(category: category, selected: category.id == selectedID)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category.id == selectedID ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}

/// Dark filled button (the main action of a card) or a card-coloured one.
struct SMSPillButton: View {
    let title: String
    var systemImage: String?
    var prominent: Bool = true
    var destructive: Bool = false
    let action: () -> Void

    private var foreground: Color {
        if prominent {
            return Color.LightIcon
        }

        return destructive ? Color.AlertRed : Color.PrimaryText
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                }

                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(
                prominent ? Color.DarkBackground : Color.PrimaryBackground,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Square icon button of a card (edit, skip).
struct SMSIconButton: View {
    let systemName: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundColor(Color.SubtitleText)
                .frame(width: 44, height: 44)
                .background(Color.PrimaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Small grey tag on a card: "Possible duplicate", "Transfer?".
struct SMSTag: View {
    let text: LocalizedStringKey
    var systemImage: String?
    var color: Color = Color.SubtitleText

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage = systemImage {
                Image(systemName: systemImage)
            }

            Text(text)
                .lineLimit(1)
        }
        .font(.system(.caption, design: .rounded).weight(.semibold))
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Row with a title, an optional caption and the capsule switch.
struct SMSToggleRow: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            Haptics.tap()
            onChange(!isOn)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundColor(Color.PrimaryText)
                        .multilineTextAlignment(.leading)

                    if let caption = caption {
                        Text(caption)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundColor(Color.SubtitleText)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .frame(width: 42, height: 28)
                        .foregroundColor(isOn ? .green : .gray.opacity(0.8))

                    Circle()
                        .foregroundColor(Color.white)
                        .padding(2)
                        .frame(width: 28, height: 28)
                }
                .animation(.easeInOut(duration: 0.18), value: isOn)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(isOn ? LocalizedStringKey("On") : LocalizedStringKey("Off")))
        .accessibilityAddTraits(.isButton)
    }
}

/// Decides once per drag whether it is a horizontal swipe, so a vertical scroll that starts
/// on a card is left alone.
final class SMSSwipeAxis {
    private var start: CGPoint?
    private var horizontal: Bool?

    func isHorizontal(_ value: DragGesture.Value) -> Bool {
        // A cancelled drag never reaches onEnded: a new start point means a new drag.
        if start != value.startLocation {
            start = value.startLocation
            horizontal = nil
        }

        if let decided = horizontal {
            return decided
        }

        let decided = abs(value.translation.width) > abs(value.translation.height) * 1.6

        horizontal = decided
        return decided
    }

    func reset() {
        start = nil
        horizontal = nil
    }
}

extension View {
    /// The rounded card every SMS block sits on.
    func smsCard(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
