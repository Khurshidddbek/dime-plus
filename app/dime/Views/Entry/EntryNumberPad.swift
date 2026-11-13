//
//  EntryNumberPad.swift
//  dime
//

import SwiftUI
import UIKit

// MARK: Shake

// Horizontal shake that plays once each time animatableData moves to the next whole number.
struct EntryShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size _: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes), y: 0)
        )
    }
}

// MARK: Tap or hold

private final class HoldTracker {
    var fired = false
    var work: DispatchWorkItem?
}

// One gesture decides between tap and hold, so a hold can never also run the tap action.
// A Button with an added long press would run both.
struct TapOrHoldModifier: ViewModifier {
    let holdDuration: TimeInterval
    let onTap: () -> Void
    let onHold: (() -> Void)?

    @GestureState private var isPressing = false
    @State private var tracker = HoldTracker()

    init(holdDuration: TimeInterval, onTap: @escaping () -> Void, onHold: (() -> Void)?) {
        self.holdDuration = holdDuration
        self.onTap = onTap
        self.onHold = onHold
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressing ? 0.8 : 1)
            .opacity(isPressing ? 0.5 : 1)
            .animation(.easeOut(duration: 0.3), value: isPressing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressing) { _, state, _ in
                        state = true
                    }
                    .onEnded { value in
                        tracker.work?.cancel()
                        tracker.work = nil

                        let moved = max(abs(value.translation.width), abs(value.translation.height))

                        let held = tracker.fired
                        // Reset here too: a fast next tap can end before onChange runs.
                        tracker.fired = false

                        if !held, moved < 30 {
                            onTap()
                        }
                    }
            )
            .onChange(of: isPressing) { _, pressing in
                tracker.work?.cancel()
                tracker.work = nil

                guard pressing else { return }

                tracker.fired = false

                guard let onHold else { return }

                let current = tracker
                let work = DispatchWorkItem {
                    current.fired = true
                    onHold()
                }

                tracker.work = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: work)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onTap()
            }
    }
}

extension View {
    func tapOrHold(
        holdDuration: TimeInterval = 0.45,
        onTap: @escaping () -> Void,
        onHold: (() -> Void)? = nil
    ) -> some View {
        modifier(TapOrHoldModifier(holdDuration: holdDuration, onTap: onTap, onHold: onHold))
    }
}

// MARK: Amount display

struct EntryAmountDisplay: View {
    @Binding var amount: AmountInput
    let shake: Int
    let isError: Bool
    let onRejected: () -> Void

    @AppStorage("currency", store: UserDefaults.appGroup) private var currency: String = MoneyFormat.defaultCurrencyCode
    @AppStorage("currencySymbolOverride", store: UserDefaults.appGroup) private var symbolOverride: String = ""

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(amount: Binding<AmountInput>, shake: Int = 0, isError: Bool = false, onRejected: @escaping () -> Void = {}) {
        _amount = amount
        self.shake = shake
        self.isError = isError
        self.onRejected = onRejected
    }

    private var settings: MoneySettings {
        MoneySettings.resolve(currency: currency, showCents: true, symbolOverride: symbolOverride)
    }

    private var largerFontSize: CGFloat {
        switch dynamicTypeSize {
        case .xSmall:
            return 46
        case .small:
            return 47
        case .medium:
            return 48
        case .large:
            return 50
        case .xLarge:
            return 56
        case .xxLarge:
            return 58
        case .xxxLarge:
            return 62
        default:
            return 50
        }
    }

    // The pre-dotted mode has its delete key on the pad.
    private var showsBackspace: Bool {
        amount.mode != .centsFirst
    }

    private var amountText: Text {
        let number = Text(amount.text)
            .font(.system(size: largerFontSize, weight: .regular, design: .rounded))
            .foregroundColor(isError ? Color.AlertRed : Color.PrimaryText)

        let current = settings

        if current.symbolLeading {
            let symbol = Text(current.symbol + current.symbolSeparator)
                .font(.system(.largeTitle, design: .rounded))
                .foregroundColor(Color.SubtitleText)

            return symbol + number
        }

        // Multi-letter symbols ("so'm", "UZS") go after the number, small, so the digits keep the width.
        let symbol = Text(MoneyFormat.noBreakSpace + current.symbol)
            .font(.system(.title2, design: .rounded).weight(.medium))
            .foregroundColor(Color.SubtitleText)

        return number + symbol
    }

    var body: some View {
        amountText
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.18), value: amount)
            .modifier(EntryShakeEffect(animatableData: CGFloat(shake)))
            .animation(.linear(duration: 0.35), value: shake)
            .animation(.easeOut(duration: 0.2), value: isError)
            .padding(.horizontal, showsBackspace ? 44 : 0)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    pasteAmount()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }

                Button {
                    copyAmount()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .overlay(alignment: .trailing) {
                if showsBackspace {
                    backspaceButton
                }
            }
            .accessibilityElement(children: .contain)
    }

    private var backspaceButton: some View {
        Image(systemName: "delete.left.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(Color.SubtitleText)
            .padding(7)
            .background(Color.SecondaryBackground, in: Circle())
            .frame(width: 44, height: 44)
            .opacity(amount.hasInput ? 1 : 0.4)
            .tapOrHold(holdDuration: 0.6) {
                deleteLastDigit()
            } onHold: {
                clearAll()
            }
            .accessibilityLabel(Text("Delete last digit"))
            .accessibilityAction(named: Text("Clear amount")) {
                clearAll()
            }
    }

    private func deleteLastDigit() {
        var copy = amount

        if copy.backspace() {
            Haptics.key()
            amount = copy
        }
    }

    private func clearAll() {
        guard amount.hasInput else { return }

        var copy = amount
        copy.clear()
        amount = copy
        Haptics.impact(.rigid)
    }

    private func pasteAmount() {
        let pasted = UIPasteboard.general.string ?? ""

        guard let value = MoneyFormat.parseForEntry(pasted, fractionDigits: amount.mode.fractionDigits), value > 0 else {
            // Too long, or no number at all: leave the amount as it was.
            onRejected()
            ToastCenter.shared.show(.error, String(localized: "No amount to paste"), haptic: false)
            return
        }

        var copy = amount
        copy.set(value: value)
        amount = copy
        Haptics.tap()
    }

    private func copyAmount() {
        let plain = String(format: "%.\(amount.mode.fractionDigits)f", locale: Locale(identifier: "en_US_POSIX"), amount.value)
        UIPasteboard.general.string = plain
        Haptics.tap()
    }
}

// MARK: Pad

struct EntryNumberPad: View {
    @Binding var amount: AmountInput
    let isReady: Bool
    let showingNotePicker: Bool
    let onRejected: () -> Void
    let submit: () -> Void
    let submitAndContinue: (() -> Void)?

    private let rows = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    init(
        amount: Binding<AmountInput>,
        isReady: Bool,
        showingNotePicker: Bool = false,
        onRejected: @escaping () -> Void,
        submit: @escaping () -> Void,
        submitAndContinue: (() -> Void)? = nil
    ) {
        _amount = amount
        self.isReady = isReady
        self.showingNotePicker = showingNotePicker
        self.onRejected = onRejected
        self.submit = submit
        self.submitAndContinue = submitAndContinue
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: proxy.size.height * 0.04) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: proxy.size.width * 0.05) {
                        ForEach(row, id: \.self) { number in
                            digitKey(number, size: proxy.size)
                        }
                    }
                }

                HStack(spacing: proxy.size.width * 0.05) {
                    leftKey(size: proxy.size)
                    digitKey(0, size: proxy.size)
                    confirmKey(size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.bottom, 15)
        .keyboardAwareHeight(showToolbar: showingNotePicker)
    }

    // MARK: Keys

    private func digitKey(_ number: Int, size: CGSize) -> some View {
        Button {
            press(number)
        } label: {
            Text("\(number)")
                .font(.system(size: 34, weight: .regular, design: .rounded))
                .frame(width: size.width * 0.3, height: size.height * 0.22)
                .background(Color.SecondaryBackground)
                .foregroundColor(Color.PrimaryText)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(NumPadButton())
    }

    @ViewBuilder
    private func leftKey(size: CGSize) -> some View {
        switch amount.mode {
        case .centsFirst:
            Image("tag-cross")
                .resizable()
                .frame(width: 32, height: 32)
                .frame(width: size.width * 0.3, height: size.height * 0.22)
                .background(Color.DarkBackground)
                .foregroundColor(Color.LightIcon)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .tapOrHold(holdDuration: 0.6) {
                    deleteLastDigit()
                } onHold: {
                    clearAll()
                }
                .accessibilityLabel(Text("Delete last digit"))
        case .decimal:
            Button {
                var copy = amount

                if copy.startFraction() {
                    Haptics.key()
                    amount = copy
                }
            } label: {
                Text(MoneyFormat.decimalSeparator)
                    .font(.system(size: 34, weight: .regular, design: .rounded))
                    .frame(width: size.width * 0.3, height: size.height * 0.22)
                    .background(Color.SecondaryBackground)
                    .foregroundColor(Color.PrimaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(NumPadButton())
        case .whole:
            Button {
                pressTripleZero()
            } label: {
                Text(verbatim: "000")
                    .font(.system(size: 26, weight: .regular, design: .rounded))
                    .frame(width: size.width * 0.3, height: size.height * 0.22)
                    .background(Color.SecondaryBackground)
                    .foregroundColor(Color.PrimaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(amount.isZero ? 0.6 : 1)
            }
            .buttonStyle(NumPadButton())
        }
    }

    private func confirmKey(size: CGSize) -> some View {
        Image(systemName: "checkmark.square.fill")
            .font(.system(size: 30, weight: .medium, design: .rounded))
            .symbolEffect(.bounce.up.byLayer, value: isReady)
            .frame(width: size.width * 0.3, height: size.height * 0.22)
            .foregroundColor(Color.LightIcon)
            .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .tapOrHold(holdDuration: 0.45, onTap: submit, onHold: submitAndContinue)
            .accessibilityLabel(Text("Save"))
    }

    // MARK: Actions

    private func press(_ digit: Int) {
        var copy = amount

        if copy.append(digit) {
            Haptics.key()
            amount = copy
        } else {
            onRejected()
        }
    }

    private func pressTripleZero() {
        if amount.isZero {
            // Nothing to multiply yet, not worth an error.
            return
        }

        var copy = amount

        if copy.appendZeros(3) {
            Haptics.key()
            amount = copy
        } else {
            onRejected()
        }
    }

    private func deleteLastDigit() {
        var copy = amount

        if copy.backspace() {
            Haptics.key()
            amount = copy
        }
    }

    private func clearAll() {
        guard amount.hasInput else { return }

        var copy = amount
        copy.clear()
        amount = copy
        Haptics.impact(.rigid)
    }
}

// MARK: Time sheet

struct EntryTimePickerSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss

    init(date: Binding<Date>) {
        _date = date
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Time")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.PrimaryText)

                Spacer()

                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.IncomeGreen)
                        .padding(7)
                        .background(Color.IncomeGreen.opacity(0.23), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Done"))
            }

            // The wheel follows the 12/24 h setting of the device by itself.
            DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 17)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.PrimaryBackground)
    }
}
