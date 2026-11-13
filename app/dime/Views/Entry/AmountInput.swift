//
//  AmountInput.swift
//  dime
//

import Foundation

// Typed amount kept as digits, so nothing is lost to Double shifting while typing.
struct AmountInput: Equatable {
    enum Mode: Equatable {
        case whole // no fraction, "000" key
        case decimal // separator key, up to 2 fraction digits
        case centsFirst // every digit shifts in from the right, always 2 fraction digits

        // Zero-decimal currencies always type whole numbers. numberEntryType 3 forces it for any currency.
        static func resolve(currency: String, numberEntryType: Int) -> Mode {
            if MoneyFormat.isZeroDecimal(currency) || numberEntryType == 3 {
                return .whole
            }
            return numberEntryType == 1 ? .centsFirst : .decimal
        }

        // For initialisers, where @AppStorage is not readable yet.
        static var current: Mode {
            let defaults = UserDefaults.appGroup
            let currency = defaults.string(forKey: MoneyFormat.currencyKey) ?? MoneyFormat.defaultCurrencyCode
            let entryType = defaults.object(forKey: "numberEntryType") as? Int ?? 1
            return resolve(currency: currency, numberEntryType: entryType)
        }

        var fractionDigits: Int {
            self == .whole ? 0 : AmountInput.maxFractionDigits
        }
    }

    static let maxWholeDigits = MoneyFormat.maxIntegerDigits
    static let maxFractionDigits = 2

    private(set) var mode: Mode
    // whole and decimal: integer digits without leading zeros. centsFirst: all digits, in minor units.
    private(set) var digits: String = ""
    // decimal mode only: nil until the separator key was pressed.
    private(set) var fraction: String?

    init(mode: Mode) {
        self.mode = mode
    }

    init(value: Double, mode: Mode) {
        self.mode = mode
        set(value: value)
    }

    // MARK: Reading

    var value: Double {
        switch mode {
        case .whole:
            return Double(digits) ?? 0
        case .decimal:
            let integerPart = digits.isEmpty ? "0" : digits
            let fractionPart = (fraction ?? "").isEmpty ? "0" : (fraction ?? "0")
            return Double(integerPart + "." + fractionPart) ?? 0
        case .centsFirst:
            return (Double(digits) ?? 0) / 100
        }
    }

    var isZero: Bool {
        value == 0
    }

    // True when backspace has something to remove.
    var hasInput: Bool {
        !digits.isEmpty || fraction != nil
    }

    // Grouped integer part, "0" when nothing was typed.
    var integerText: String {
        switch mode {
        case .whole, .decimal:
            return AmountInput.grouped(digits)
        case .centsFirst:
            return AmountInput.grouped(String(digits.dropLast(2)))
        }
    }

    // Decimal separator plus the typed fraction digits, empty in whole mode.
    var fractionText: String {
        switch mode {
        case .whole:
            return ""
        case .decimal:
            guard let fraction else { return "" }
            return MoneyFormat.decimalSeparator + fraction
        case .centsFirst:
            let tail = String(digits.suffix(2))
            let padded = String(repeating: "0", count: max(0, 2 - tail.count)) + tail
            return MoneyFormat.decimalSeparator + padded
        }
    }

    var text: String {
        integerText + fractionText
    }

    // MARK: Editing. A false result means the key was refused and nothing changed.

    @discardableResult
    mutating func append(_ digit: Int) -> Bool {
        guard digit >= 0, digit <= 9 else { return false }

        switch mode {
        case .whole:
            return appendInteger(digit, limit: AmountInput.maxWholeDigits)
        case .decimal:
            if let current = fraction {
                guard current.count < AmountInput.maxFractionDigits else { return false }
                fraction = current + String(digit)
                return true
            }
            return appendInteger(digit, limit: AmountInput.maxWholeDigits)
        case .centsFirst:
            return appendInteger(digit, limit: AmountInput.maxWholeDigits + AmountInput.maxFractionDigits)
        }
    }

    // The "000" key.
    @discardableResult
    mutating func appendZeros(_ count: Int) -> Bool {
        guard count > 0, !digits.isEmpty, fraction == nil else { return false }

        let limit = mode == .centsFirst
            ? AmountInput.maxWholeDigits + AmountInput.maxFractionDigits
            : AmountInput.maxWholeDigits

        guard digits.count + count <= limit else { return false }

        digits += String(repeating: "0", count: count)
        return true
    }

    @discardableResult
    mutating func startFraction() -> Bool {
        guard mode == .decimal, fraction == nil else { return false }
        fraction = ""
        return true
    }

    @discardableResult
    mutating func backspace() -> Bool {
        if let current = fraction {
            fraction = current.isEmpty ? nil : String(current.dropLast())
            return true
        }

        guard !digits.isEmpty else { return false }

        digits.removeLast()
        return true
    }

    mutating func clear() {
        digits = ""
        fraction = nil
    }

    // Loads a stored or pasted value. Values above the cap are clamped to the largest amount.
    mutating func set(value: Double) {
        clear()

        guard value.isFinite else { return }

        let magnitude = min(abs(value), MoneyFormat.maxAmount)

        switch mode {
        case .whole:
            digits = AmountInput.strippingLeadingZeros(String(format: "%.0f", magnitude.rounded()))
        case .decimal:
            let pieces = AmountInput.fixedPieces(magnitude)
            digits = AmountInput.strippingLeadingZeros(pieces.integer)

            if pieces.fraction != "00" {
                // "50" is shown as ".5", the same thing the user would have typed.
                fraction = pieces.fraction.hasSuffix("0") ? String(pieces.fraction.prefix(1)) : pieces.fraction
            }
        case .centsFirst:
            let pieces = AmountInput.fixedPieces(magnitude)
            digits = AmountInput.strippingLeadingZeros(pieces.integer + pieces.fraction)
        }
    }

    // MARK: Helpers

    private mutating func appendInteger(_ digit: Int, limit: Int) -> Bool {
        if digits.isEmpty, digit == 0 {
            // A leading zero changes nothing and is not an error.
            return true
        }

        guard digits.count < limit else { return false }

        digits += String(digit)
        return true
    }

    // Integer digits and exactly 2 fraction digits. String(format:) without a locale always prints ".".
    private static func fixedPieces(_ magnitude: Double) -> (integer: String, fraction: String) {
        let fixed = String(format: "%.2f", magnitude)
        let parts = fixed.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts.first.map(String.init) ?? "0"
        let fraction = parts.count > 1 ? String(parts[1]) : "00"
        return (integer, fraction.count == 2 ? fraction : "00")
    }

    private static func strippingLeadingZeros(_ text: String) -> String {
        let onlyDigits = text.filter { $0 >= "0" && $0 <= "9" }
        return String(onlyDigits.drop(while: { $0 == "0" }))
    }

    private static func grouped(_ raw: String) -> String {
        guard !raw.isEmpty else { return "0" }

        var result = ""
        let total = raw.count

        for (index, character) in raw.enumerated() {
            if index > 0, (total - index) % 3 == 0 {
                result += MoneyFormat.groupingSeparator
            }
            result.append(character)
        }

        return result
    }
}

// MARK: Bridge to the old Double + flags state (NewBudgetView, SettingsNumberEntryView)

extension AmountInput {
    init(legacyPrice price: Double, isEditingDecimal: Bool, assigned: AssignedDecimal, mode: Mode) {
        self.mode = mode

        guard price.isFinite else { return }

        let magnitude = min(abs(price), MoneyFormat.maxAmount)

        switch mode {
        case .whole, .centsFirst:
            set(value: magnitude)
        case .decimal:
            let pieces = AmountInput.fixedPieces(magnitude)
            digits = AmountInput.strippingLeadingZeros(pieces.integer)

            if isEditingDecimal {
                switch assigned {
                case .none:
                    fraction = ""
                case .first:
                    fraction = String(pieces.fraction.prefix(1))
                case .second:
                    fraction = pieces.fraction
                }
            }
        }
    }

    var legacyIsEditingDecimal: Bool {
        mode == .decimal && fraction != nil
    }

    var legacyAssignedDecimal: AssignedDecimal {
        guard mode == .decimal, let fraction else { return .none }

        switch fraction.count {
        case 0:
            return .none
        case 1:
            return .first
        default:
            return .second
        }
    }
}
