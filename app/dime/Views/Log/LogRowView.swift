//
//  LogRowView.swift
//  dime
//
//  App target only. The Log list drawn from value rows.
//

import SwiftUI
import UIKit

/// Day sections with their rows. Every header and every row is its own lazy item.
struct LogSectionsView: View {
    let sections: [LogDaySection]

    @AppStorage("swapTimeLabel", store: UserDefaults.appGroup) var swapTimeLabel: Bool = false
    @AppStorage("showExpenseOrIncomeSign", store: UserDefaults.appGroup) var showExpenseOrIncomeSign: Bool = true

    var body: some View {
        let style = LogRowStyle(swapTimeLabel: swapTimeLabel, showSign: showExpenseOrIncomeSign)
        let today = LogCutoff.startOfToday()

        LazyVStack(spacing: 0) {
            ForEach(sections) { day in
                LogDayHeader(day: day, swapTimeLabel: swapTimeLabel, today: today)
                    .equatable()

                ForEach(day.rows) { row in
                    LogRowView(row: row, future: false, style: style)
                        .equatable()
                }

                Color.clear
                    .frame(height: 18)
            }
        }
    }
}

struct LogDayHeader: View, Equatable {
    let day: LogDaySection
    let swapTimeLabel: Bool
    // Part of the comparison only: after midnight "TODAY" has to be drawn again
    // although the section itself did not change.
    let today: Date

    var body: some View {
        let title = Fmt.dayHeader(day.id).uppercased()

        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 8)

                AmountText(day.total, role: .caption, sign: .always, fit: .fullOnly, color: Color.SubtitleText)
                    .layoutPriority(1)
            }
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundColor(Color.SubtitleText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Fmt.dayHeaderSpoken(day.id) + ", " + MoneyFormat.spoken(day.total, sign: .always)))
            .accessibilityAddTraits(.isHeader)

            Line()
                .stroke(Color.Outline, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                let settings = MoneySettings.current
                let transactions = day.rows.compactMap { LogFeed.shared.transaction(for: $0) }
                let photo = SingleDayPhotoView(
                    amountText: MoneyFormat.string(day.total, sign: .always, settings: settings),
                    dateText: title,
                    transactions: transactions,
                    showCents: settings.fractionDigits > 0,
                    currencySymbol: settings.symbol,
                    currency: settings.code,
                    swapTimeLabel: swapTimeLabel,
                    future: false
                )

                guard let image = ImageRenderer(content: photo).uiImage else {
                    ToastCenter.shared.error(String(localized: "Couldn't create the image"))
                    return
                }

                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                ToastCenter.shared.success(String(localized: "Image Saved"))
            } label: {
                Label("Save as Photo", systemImage: "square.and.arrow.up")
            }

            Button {
                LogActions.copyAmount(day.total)
            } label: {
                Label("Copy amount", systemImage: "doc.on.doc")
            }
        }
    }
}

/// One transaction. Equatable on its values and wrapped in `.equatable()` by the lists,
/// so a parent redraw does not run row bodies again.
struct LogRowView: View, Equatable {
    let row: LogRowModel
    let future: Bool
    let style: LogRowStyle

    @State var offset: CGFloat = 0
    @State var deleted = false
    // A reference box: deciding the drag axis must not redraw the row during a scroll.
    @State var axis = LogRowAxisLock()

    // True only while a horizontal swipe is in progress. Its automatic reset is the
    // only signal for a cancelled gesture, onEnded is not called then.
    @GestureState var isSwiping = false

    static func == (lhs: LogRowView, rhs: LogRowView) -> Bool {
        lhs.row == rhs.row && lhs.future == rhs.future && lhs.style == rhs.style
    }

    private static let screenWidth = UIScreen.main.bounds.width

    var deletePopup: Bool {
        abs(offset) > LogRowView.screenWidth * 0.2
    }

    var deleteConfirm: Bool {
        abs(offset) > LogRowView.screenWidth * 0.42
    }

    var subtitle: String {
        if future {
            return Fmt.uppercased(.dayMonth, from: row.upcomingDate)
        }

        if style.swapTimeLabel {
            return row.categoryName
        }

        return Fmt.time(row.date)
    }

    var amountSign: MoneySign {
        if !style.showSign {
            return .never
        }

        return row.income ? .plus : .minus
    }

    var amountColor: Color {
        if future {
            return Color.SubtitleText
        }

        return row.income ? Color.IncomeGreen : Color.PrimaryText
    }

    var spokenLabel: String {
        let amount = MoneyFormat.string(row.amount, sign: row.income ? .plus : .minus)
        let when = future ? Fmt.string(.dayMonthYear, from: row.upcomingDate) : Fmt.time(row.date)

        return [row.note, amount, row.categoryName, when].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Image(systemName: "xmark")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .foregroundColor(deleteConfirm ? Color.AlertRed : Color.SubtitleText)
                .padding(5)
                .background(deleteConfirm ? Color.AlertRed.opacity(0.23) : Color.SecondaryBackground, in: Circle())
                .scaleEffect(deleteConfirm ? 1.1 : 1)
                .opacity(deleted ? 0 : 1)
                .padding(.horizontal, 10)
                .offset(x: 80)
                .offset(x: max(-80, offset))
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                EmojiLogView(emoji: row.emoji, colour: row.colour, future: future)
                    .fixedSize(horizontal: true, vertical: true)
                    .overlay(alignment: .bottomTrailing) {
                        if row.recurringType > 0 {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color.DarkIcon)
                                .padding(3)
                                .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 6))
                                .offset(x: 5, y: 5)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.note)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundColor(future ? Color.SubtitleText : Color.PrimaryText)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .foregroundColor(future ? Color.EvenLighterText : Color.SubtitleText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The amount takes the width it needs first, the note gives way.
                AmountText(row.amount, role: .row, sign: amountSign, fit: .fullOnly, color: amountColor)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .layoutPriority(1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                LogActions.edit(row)
            }
            .contextMenu {
                menuItems
            }
            .offset(x: offset)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spokenLabel))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Delete")) {
                LogActions.delete(row, future: future)
            }
        }
        .onChange(of: deletePopup) { _, reached in
            if reached {
                Haptics.tap()
            }
        }
        .onChange(of: deleteConfirm) { _, reached in
            if reached {
                Haptics.impact(.medium)
            }
        }
        .animation(.easeInOut, value: deletePopup)
        .simultaneousGesture(swipe)
        .onChange(of: isSwiping) { _, swiping in
            if !swiping {
                axis.reset()

                if !deleted {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        offset = 0
                    }
                }
            }
        }
    }

    @ViewBuilder
    var menuItems: some View {
        if row.recurringType > 0 {
            Button {
                LogActions.stopRecurring(row)
            } label: {
                Label("Stop Recurring", systemImage: "xmark")
            }
        }

        Button {
            LogActions.edit(row)
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Button {
            LogActions.duplicate(row)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Button {
            LogActions.logAgainToday(row)
        } label: {
            Label("Log again today", systemImage: "arrow.counterclockwise")
        }

        Button {
            LogActions.copyAmount(row.amount)
        } label: {
            Label("Copy amount", systemImage: "doc.on.doc")
        }

        if !row.stopsRecurring(future: future) {
            Button(role: .destructive) {
                LogActions.delete(row, future: future)
            } label: {
                Label("Delete", systemImage: "xmark.bin")
            }
        }
    }

    // Swipe left: past 20 % of the screen asks to delete, past 42 % deletes with Undo.
    // The gesture only reacts to a mostly horizontal drag, a vertical scroll that starts
    // on a row leaves it alone.
    var swipe: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .updating($isSwiping) { value, state, _ in
                if axis.isHorizontal(value) {
                    state = true
                }
            }
            .onChanged { value in
                guard axis.isHorizontal(value), !deleted else {
                    return
                }

                offset = min(0, value.translation.width)
            }
            .onEnded { value in
                let horizontal = axis.isHorizontal(value)
                axis.reset()

                guard horizontal, !deleted else {
                    return
                }

                if deleteConfirm {
                    commitSwipe()
                } else if deletePopup {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        offset = 0
                    }

                    LogActions.askToDelete(row, future: future)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        offset = 0
                    }
                }
            }
    }

    func commitSwipe() {
        deleted = true

        withAnimation(.easeInOut(duration: 0.3)) {
            offset = -LogRowView.screenWidth * 1.2
        }

        // After the row has left the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let done = LogActions.delete(row, future: future)

            // The row normally leaves the list. If it stays (failed save), bring it back.
            DispatchQueue.main.asyncAfter(deadline: .now() + (done ? 0.8 : 0)) {
                deleted = false

                withAnimation(.easeInOut(duration: 0.3)) {
                    offset = 0
                }
            }
        }
    }
}

/// Decides once per drag whether it is a horizontal swipe.
final class LogRowAxisLock {
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

        let width = value.translation.width
        let height = value.translation.height
        let decided = width < 0 && abs(width) > abs(height) * 1.6

        horizontal = decided
        return decided
    }

    func reset() {
        start = nil
        horizontal = nil
    }
}
