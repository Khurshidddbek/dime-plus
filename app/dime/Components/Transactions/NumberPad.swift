//
//  NumberPad.swift
//  dime
//
//  Created by Yumi on 2023-10-29.
//

import SwiftUI

enum AssignedDecimal {
    case none, first, second
}

// Old Double + flags interface, kept for NewBudgetView and SettingsNumberEntryView.
// Both views are thin shells around EntryNumberPad / EntryAmountDisplay, so every host gets
// grouping, the 12 digit cap, the "000" key and the same haptics.
private func legacyAmountBinding(
    price: Binding<Double>,
    isEditingDecimal: Binding<Bool>,
    decimalValuesAssigned: Binding<AssignedDecimal>,
    mode: AmountInput.Mode
) -> Binding<AmountInput> {
    Binding<AmountInput>(
        get: {
            AmountInput(
                legacyPrice: price.wrappedValue,
                isEditingDecimal: isEditingDecimal.wrappedValue,
                assigned: decimalValuesAssigned.wrappedValue,
                mode: mode
            )
        },
        set: { newValue in
            price.wrappedValue = newValue.value
            isEditingDecimal.wrappedValue = newValue.legacyIsEditingDecimal
            decimalValuesAssigned.wrappedValue = newValue.legacyAssignedDecimal
        }
    )
}

struct NumberPad: View {
    @Binding var price: Double
    @Binding var category: Category?
    @Binding var isEditingDecimal: Bool
    @Binding var decimalValuesAssigned: AssignedDecimal
    var showingNotePicker: Bool
    var submit: () -> Void

    @AppStorage("numberEntryType", store: UserDefaults.appGroup) var numberEntryType: Int = 1
    @AppStorage("currency", store: UserDefaults.appGroup) var currency: String = MoneyFormat.defaultCurrencyCode

    init(
        price: Binding<Double>,
        category: Binding<Category?>,
        isEditingDecimal: Binding<Bool>,
        decimalValuesAssigned: Binding<AssignedDecimal>,
        showingNotePicker: Bool = false,
        submit: @escaping () -> Void
    ) {
        _price = price
        _category = category
        _isEditingDecimal = isEditingDecimal
        _decimalValuesAssigned = decimalValuesAssigned
        self.showingNotePicker = showingNotePicker
        self.submit = submit
    }

    var body: some View {
        EntryNumberPad(
            amount: legacyAmountBinding(
                price: $price,
                isEditingDecimal: $isEditingDecimal,
                decimalValuesAssigned: $decimalValuesAssigned,
                mode: AmountInput.Mode.resolve(currency: currency, numberEntryType: numberEntryType)
            ),
            isReady: price != 0 && category != nil,
            showingNotePicker: showingNotePicker,
            onRejected: {
                Haptics.warning()
            },
            submit: submit
        )
    }
}

struct NumberPadTextView: View {
    @Binding var price: Double
    @Binding var isEditingDecimal: Bool
    @Binding var decimalValuesAssigned: AssignedDecimal

    @AppStorage("numberEntryType", store: UserDefaults.appGroup) var numberEntryType: Int = 1
    @AppStorage("currency", store: UserDefaults.appGroup) var currency: String = MoneyFormat.defaultCurrencyCode

    init(price: Binding<Double>, isEditingDecimal: Binding<Bool>, decimalValuesAssigned: Binding<AssignedDecimal>) {
        _price = price
        _isEditingDecimal = isEditingDecimal
        _decimalValuesAssigned = decimalValuesAssigned
    }

    var body: some View {
        EntryAmountDisplay(
            amount: legacyAmountBinding(
                price: $price,
                isEditingDecimal: $isEditingDecimal,
                decimalValuesAssigned: $decimalValuesAssigned,
                mode: AmountInput.Mode.resolve(currency: currency, numberEntryType: numberEntryType)
            ),
            onRejected: {
                Haptics.warning()
            }
        )
    }
}
