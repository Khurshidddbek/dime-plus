//
//  MoneyFormat.swift
//  dime
//

import Foundation

// Compiled into all 4 targets: Foundation only, no SwiftUI, no app-only symbols.

enum MoneySign {
    case automatic // minus for negative values, nothing otherwise
    case always // plus for positive, minus for negative
    case never // magnitude only
    case plus // magnitude with a forced plus (income rows store positive amounts)
    case minus // magnitude with a forced minus (expense rows store positive amounts)
}

struct MoneySettings: Equatable {
    let code: String
    let symbol: String
    let symbolLeading: Bool
    // Goes between number and symbol, empty when they are glued ("$5").
    let symbolSeparator: String
    let fractionDigits: Int

    var isZeroDecimal: Bool { MoneyFormat.isZeroDecimal(code) }

    static func resolve(currency: String, showCents: Bool, symbolOverride: String = "") -> MoneySettings {
        MoneyFormat.settings(currency: currency, showCents: showCents, symbolOverride: symbolOverride)
    }

    // For code without @AppStorage (intents, timelines, models). Views should hold the
    // three @AppStorage values and call resolve, otherwise they miss setting changes.
    static var current: MoneySettings {
        let defaults = UserDefaults.appGroup
        return resolve(
            currency: defaults.string(forKey: MoneyFormat.currencyKey) ?? MoneyFormat.defaultCurrencyCode,
            showCents: defaults.object(forKey: MoneyFormat.showCentsKey) as? Bool ?? true,
            symbolOverride: defaults.string(forKey: MoneyFormat.symbolOverrideKey) ?? ""
        )
    }
}

struct MoneyParts: Equatable {
    let sign: String
    let integer: String // grouped digits
    let fraction: String // includes the decimal separator, empty when there are no decimals
    let unit: String // compact unit, empty in the full form
    let unitSeparator: String
    let symbol: String
    let symbolLeading: Bool
    let symbolSeparator: String

    var number: String { integer + fraction }
    var isCompact: Bool { !unit.isEmpty }

    var text: String {
        var result = sign
        if symbolLeading, !symbol.isEmpty {
            result += symbol + symbolSeparator
        }
        result += integer + fraction
        if !unit.isEmpty {
            result += unitSeparator + unit
        }
        if !symbolLeading, !symbol.isEmpty {
            result += symbolSeparator + symbol
        }
        return result
    }

    func withoutSymbol() -> MoneyParts {
        MoneyParts(sign: sign, integer: integer, fraction: fraction, unit: unit, unitSeparator: unitSeparator,
                   symbol: "", symbolLeading: false, symbolSeparator: "")
    }
}

enum MoneyFormat {
    // MARK: Constants

    static let currencyKey = "currency"
    static let showCentsKey = "showCents"
    static let symbolOverrideKey = "currencySymbolOverride"

    static let maxIntegerDigits = 12
    static let maxAmount: Double = 999_999_999_999

    static let groupingSeparator = "\u{202F}"
    static let noBreakSpace = "\u{00A0}"
    static let minusSign = "\u{2212}"
    static let plusSign = "+"
    static let placeholder = "\u{2014}"

    // Below this a compact form is not shorter than the full one.
    static let compactThreshold: Double = 100_000

    // ISO 4217 says 2 minor units for UZS and some others here, but nobody uses them.
    static let zeroDecimalCurrencies: Set<String> = [
        "UZS", "JPY", "KRW", "VND", "IDR", "CLP", "PYG", "ISK", "UGX", "RWF", "GNF", "XAF", "XOF", "XPF",
        "KMF", "DJF", "BIF", "VUV", "IRR", "LAK", "KHR", "MMK", "MNT", "LBP", "SYP", "IQD", "COP"
    ]

    static var defaultCurrencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    static var decimalSeparator: String {
        Locale.current.decimalSeparator ?? "."
    }

    // MARK: Currency rules

    static func isZeroDecimal(_ code: String) -> Bool {
        zeroDecimalCurrencies.contains(normalized(code))
    }

    static func fractionDigits(currency: String, showCents: Bool) -> Int {
        if isZeroDecimal(currency) { return 0 }
        return showCents ? 2 : 0
    }

    // Symbol as the device region writes it, never nil: falls back to the code itself.
    static func symbol(for code: String) -> String {
        let code = normalized(code)
        let key = code + "|" + Locale.current.identifier

        lock.lock()
        installObserverIfNeeded()
        let cached = symbolCache[key]
        lock.unlock()
        if let cached { return cached }

        let current = Locale.current
        var components: [String: String] = [
            NSLocale.Key.languageCode.rawValue: current.language.languageCode?.identifier ?? "en",
            NSLocale.Key.currencyCode.rawValue: code
        ]
        if let region = current.region?.identifier {
            components[NSLocale.Key.countryCode.rawValue] = region
        }
        let locale = Locale(identifier: Locale.identifier(fromComponents: components))
        var symbol = locale.currencySymbol ?? ""
        if symbol.isEmpty || symbol == "\u{00A4}" {
            symbol = code
        }

        lock.lock()
        symbolCache[key] = symbol
        lock.unlock()
        return symbol
    }

    static func settings(currency: String, showCents: Bool, symbolOverride: String = "") -> MoneySettings {
        let code = normalized(currency)
        let key = code + "|" + Locale.current.identifier + "|" + (showCents ? "1" : "0") + "|" + symbolOverride

        lock.lock()
        installObserverIfNeeded()
        let cached = settingsCache[key]
        lock.unlock()
        if let cached { return cached }

        let custom = symbolOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = custom.isEmpty ? self.symbol(for: code) : custom
        let placement = symbolPlacement(symbol: symbol, code: code)
        let result = MoneySettings(
            code: code,
            symbol: symbol,
            symbolLeading: placement.leading,
            symbolSeparator: placement.separator,
            fractionDigits: fractionDigits(currency: code, showCents: showCents)
        )

        lock.lock()
        settingsCache[key] = result
        lock.unlock()
        return result
    }

    // MARK: Strings

    // "35 880 000 so'm", "$1 234.50"
    static func string(_ value: Double, sign: MoneySign = .automatic, settings: MoneySettings = .current) -> String {
        parts(value, sign: sign, settings: settings).text
    }

    // "35,9 mln so'm": 3 significant digits and a localised unit, full form below compactThreshold.
    static func compact(_ value: Double, sign: MoneySign = .automatic, settings: MoneySettings = .current) -> String {
        compactParts(value, sign: sign, settings: settings).text
    }

    // Chart axis label: 2 significant digits, unit from 1 000 up, no symbol.
    static func axis(_ value: Double) -> String {
        guard value.isFinite else { return placeholder }
        let magnitude = abs(value)
        if let scaled = scale(magnitude, significantDigits: 2) {
            let split = digitStrings(scaled.number, fractionDigits: scaled.fractionDigits)
            let sign = signString(value, sign: .automatic, isZero: false)
            return sign + grouped(split.integer) + split.fraction + scaled.unitSeparator + scaled.unit
        }
        let split = digitStrings(magnitude, fractionDigits: 0)
        return signString(value, sign: .automatic, isZero: isZero(magnitude, fractionDigits: 0)) + grouped(split.integer)
    }

    // Grouped number without a symbol.
    static func number(_ value: Double, fractionDigits: Int = 0, sign: MoneySign = .automatic) -> String {
        guard value.isFinite else { return placeholder }
        let magnitude = abs(value)
        let split = digitStrings(magnitude, fractionDigits: fractionDigits)
        let signText = signString(value, sign: sign, isZero: isZero(magnitude, fractionDigits: fractionDigits))
        return signText + grouped(split.integer) + split.fraction
    }

    // Split form for hero numbers. fractionDigits overrides the setting (entry screen while typing).
    static func parts(_ value: Double, sign: MoneySign = .automatic, settings: MoneySettings = .current,
                      fractionDigits: Int? = nil) -> MoneyParts {
        guard value.isFinite else { return placeholderParts }
        let digits = fractionDigits ?? settings.fractionDigits
        let magnitude = abs(value)
        let split = digitStrings(magnitude, fractionDigits: digits)
        return MoneyParts(
            sign: signString(value, sign: sign, isZero: isZero(magnitude, fractionDigits: digits)),
            integer: grouped(split.integer),
            fraction: split.fraction,
            unit: "",
            unitSeparator: "",
            symbol: settings.symbol,
            symbolLeading: settings.symbolLeading,
            symbolSeparator: settings.symbolSeparator
        )
    }

    static func compactParts(_ value: Double, sign: MoneySign = .automatic, settings: MoneySettings = .current,
                             significantDigits: Int = 3) -> MoneyParts {
        guard value.isFinite else { return placeholderParts }
        let magnitude = abs(value)
        guard magnitude >= compactThreshold, let scaled = scale(magnitude, significantDigits: significantDigits) else {
            return parts(value, sign: sign, settings: settings)
        }
        let split = digitStrings(scaled.number, fractionDigits: scaled.fractionDigits)
        return MoneyParts(
            sign: signString(value, sign: sign, isZero: false),
            integer: grouped(split.integer),
            fraction: split.fraction,
            unit: scaled.unit,
            unitSeparator: scaled.unitSeparator,
            symbol: settings.symbol,
            symbolLeading: settings.symbolLeading,
            symbolSeparator: settings.symbolSeparator
        )
    }

    // Full value with the currency name, for VoiceOver.
    static func spoken(_ value: Double, sign: MoneySign = .automatic, settings: MoneySettings = .current) -> String {
        guard value.isFinite else { return "" }
        let signed = signedValue(value, sign: sign)
        let key = "spoken|" + Locale.current.identifier + "|" + settings.code + "|" + String(settings.fractionDigits)

        lock.lock()
        installObserverIfNeeded()
        let formatter: NumberFormatter
        if let cached = formatterCache[key] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.locale = Locale.current
            formatter.numberStyle = .currencyPlural
            formatter.currencyCode = settings.code
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = settings.fractionDigits
            formatter.roundingMode = .halfUp
            formatterCache[key] = formatter
        }
        let result = formatter.string(from: NSNumber(value: signed))
        lock.unlock()

        return result ?? string(signed, settings: settings)
    }

    // Plain digits with a dot, for the pasteboard and files.
    static func plainString(_ value: Double, settings: MoneySettings = .current) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.\(settings.fractionDigits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func signedValue(_ value: Double, sign: MoneySign) -> Double {
        switch sign {
        case .automatic, .always: return value
        case .never, .plus: return abs(value)
        case .minus: return -abs(value)
        }
    }

    // MARK: Parsing

    // Typed or pasted amount: "35 880 000", "35,880,000.50", "1.250.000,00 so'm", "-1 200".
    // A lone separator followed by exactly 3 digits is read as grouping ("35,880" is 35880).
    static func parse(_ text: String) -> Double? {
        var cleaned: [Character] = []
        var negative = false

        for character in text {
            if let digit = asciiDigit(character) {
                cleaned.append(digit)
            } else if character == "." || character == "," {
                // "rub. 500": a separator before any digit belongs to the text
                if !cleaned.isEmpty { cleaned.append(character) }
            } else if character == "-" || character == "\u{2212}" {
                if cleaned.isEmpty { negative = true }
            }
        }

        while let last = cleaned.last, last == "." || last == "," {
            cleaned.removeLast()
        }
        guard !cleaned.isEmpty else { return nil }

        let dots = cleaned.filter { $0 == "." }.count
        let commas = cleaned.filter { $0 == "," }.count
        var decimalMark: Character?

        if dots > 0, commas > 0 {
            let lastDot = cleaned.lastIndex(of: ".") ?? 0
            let lastComma = cleaned.lastIndex(of: ",") ?? 0
            let mark: Character = lastDot > lastComma ? "." : ","
            if (mark == "." ? dots : commas) > 1 { return nil }
            decimalMark = mark
        } else if dots + commas == 1 {
            let mark: Character = dots == 1 ? "." : ","
            let index = cleaned.firstIndex(of: mark) ?? 0
            let after = cleaned.count - index - 1
            let integerIsZero = cleaned[..<index].allSatisfy { $0 == "0" }
            if !(after == 3 && index <= 3 && !integerIsZero) {
                decimalMark = mark
            }
        }

        var integerPart = ""
        var fractionPart = ""
        var inFraction = false
        for character in cleaned {
            if character == "." || character == "," {
                if character == decimalMark { inFraction = true }
                continue
            }
            if inFraction {
                fractionPart.append(character)
            } else {
                integerPart.append(character)
            }
        }

        let literal = (integerPart.isEmpty ? "0" : integerPart) + "." + (fractionPart.isEmpty ? "0" : fractionPart)
        guard let value = Double(literal), value.isFinite else { return nil }
        return negative ? -value : value
    }

    // Pasted text for the entry screen: positive, rounded to the currency, nil when above the cap.
    static func parseForEntry(_ text: String, fractionDigits: Int) -> Double? {
        guard let parsed = parse(text) else { return nil }
        let rounded = round(abs(parsed), fractionDigits: fractionDigits)
        return isWithinLimit(rounded) ? rounded : nil
    }

    // MARK: Input cap

    static func integerDigitCount(_ value: Double) -> Int {
        guard value.isFinite else { return Int.max }
        var remaining = abs(value).rounded(.down)
        var count = 0
        while remaining >= 1, count < 400 {
            remaining = (remaining / 10).rounded(.down)
            count += 1
        }
        return count
    }

    static func isWithinLimit(_ value: Double) -> Bool {
        integerDigitCount(value) <= maxIntegerDigits
    }

    // Whole-number entry: may `count` more digits ("000" key passes 3) be typed after `value`.
    static func canAppendDigits(_ count: Int = 1, to value: Double) -> Bool {
        let current = integerDigitCount(value)
        if current == 0 { return count <= maxIntegerDigits }
        return current <= maxIntegerDigits - count
    }

    static func round(_ value: Double, fractionDigits: Int) -> Double {
        let factor = pow10(max(0, fractionDigits))
        return (value * factor).rounded() / factor
    }

    // MARK: Caches

    static func invalidateCaches() {
        lock.lock()
        settingsCache.removeAll()
        symbolCache.removeAll()
        formatterCache.removeAll()
        lock.unlock()
    }

    private static let lock = NSLock()
    private static var settingsCache: [String: MoneySettings] = [:]
    private static var symbolCache: [String: String] = [:]
    private static var formatterCache: [String: NumberFormatter] = [:]
    private static var localeObserver: NSObjectProtocol?

    // Caller holds the lock.
    private static func installObserverIfNeeded() {
        guard localeObserver == nil else { return }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
        ) { _ in
            MoneyFormat.invalidateCaches()
        }
    }

    // MARK: Internals

    private static var placeholderParts: MoneyParts {
        MoneyParts(sign: "", integer: placeholder, fraction: "", unit: "", unitSeparator: "",
                   symbol: "", symbolLeading: false, symbolSeparator: "")
    }

    private static func normalized(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? defaultCurrencyCode : trimmed
    }

    private static func pow10(_ exponent: Int) -> Double {
        pow(10.0, Double(exponent))
    }

    private static func isZero(_ magnitude: Double, fractionDigits: Int) -> Bool {
        (magnitude * pow10(max(0, fractionDigits))).rounded() == 0
    }

    private static func signString(_ value: Double, sign: MoneySign, isZero: Bool) -> String {
        if isZero { return "" }
        switch sign {
        case .automatic: return value < 0 ? minusSign : ""
        case .always: return value < 0 ? minusSign : plusSign
        case .never: return ""
        case .plus: return plusSign
        case .minus: return minusSign
        }
    }

    private static func asciiDigit(_ character: Character) -> Character? {
        if let ascii = character.asciiValue {
            return ascii >= 48 && ascii <= 57 ? character : nil
        }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.properties.generalCategory == .decimalNumber,
              let value = character.wholeNumberValue, value >= 0, value <= 9
        else { return nil }
        return Character(String(value))
    }

    // Ungrouped localised digits of a non-negative number, split at the decimal separator.
    // Grouping is done by hand so it never depends on the locale's own grouping rules.
    private static func digitStrings(_ magnitude: Double, fractionDigits: Int) -> (integer: String, fraction: String) {
        let digits = max(0, min(fractionDigits, 6))
        let key = "number|" + Locale.current.identifier + "|" + String(digits)

        lock.lock()
        installObserverIfNeeded()
        let formatter: NumberFormatter
        if let cached = formatterCache[key] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.locale = Locale.current
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumIntegerDigits = 1
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            formatter.roundingMode = .halfUp
            formatterCache[key] = formatter
        }
        let raw = formatter.string(from: NSNumber(value: magnitude)) ?? ""
        let separator = formatter.decimalSeparator ?? "."
        lock.unlock()

        guard !raw.isEmpty else { return ("0", "") }
        if digits > 0, !separator.isEmpty, let range = raw.range(of: separator, options: .backwards) {
            return (String(raw[..<range.lowerBound]), String(raw[range.lowerBound...]))
        }
        return (raw, "")
    }

    private static func grouped(_ digits: String) -> String {
        let characters = Array(digits)
        guard characters.count > 3 else { return digits }
        var result = ""
        for (index, character) in characters.enumerated() {
            if index > 0, (characters.count - index) % 3 == 0 {
                result += groupingSeparator
            }
            result.append(character)
        }
        return result
    }

    private static let unitValues: [Double] = [1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000]

    private static var unitNames: (names: [String], separator: String) {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        if language.hasPrefix("ru") {
            return (["тыс.", "млн", "млрд", "трлн"], noBreakSpace)
        }
        return (["K", "M", "B", "T"], "")
    }

    // Rounds to the significant digits first and only then picks the unit, so 999 950 becomes 1M and not 1000K.
    private static func scale(_ magnitude: Double, significantDigits: Int)
        -> (number: Double, fractionDigits: Int, unit: String, unitSeparator: String)? {
        guard magnitude.isFinite, magnitude >= 1_000 else { return nil }
        let significant = max(1, min(significantDigits, 6))

        var exponent = Int(floor(log10(magnitude)))
        if pow10(exponent + 1) <= magnitude { exponent += 1 }
        if pow10(exponent) > magnitude { exponent -= 1 }

        let step = pow10(exponent - significant + 1)
        let rounded = (magnitude / step).rounded() * step

        var unitIndex = 0
        for (index, unitValue) in unitValues.enumerated() where rounded >= unitValue {
            unitIndex = index
        }
        let scaled = rounded / unitValues[unitIndex]

        let integerDigits = scaled >= 100 ? 3 : (scaled >= 10 ? 2 : 1)
        var decimals = max(0, significant - integerDigits)
        var shifted = (scaled * pow10(decimals)).rounded()
        while decimals > 0, shifted.truncatingRemainder(dividingBy: 10) == 0 {
            shifted /= 10
            decimals -= 1
        }

        let names = unitNames
        return (shifted / pow10(decimals), decimals, names.names[unitIndex], names.separator)
    }

    // Symbols that end with a letter ("so'm", "UZS", "kr") always go after the number with a space.
    // Glyph symbols keep the position the locale gives them.
    private static func symbolPlacement(symbol: String, code: String) -> (leading: Bool, separator: String) {
        guard let last = symbol.last else { return (false, "") }
        if last.isLetter || last.isNumber || last == "." {
            return (false, noBreakSpace)
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        let pattern: String = formatter.positiveFormat ?? ""
        let mark: Character = "\u{00A4}"

        guard let markIndex = pattern.firstIndex(of: mark) else { return (true, "") }
        let digitIndex = pattern.firstIndex(where: { $0 == "#" || $0 == "0" })
        let leading = digitIndex.map { markIndex < $0 } ?? true

        var spaced = false
        if leading {
            var index = markIndex
            while index < pattern.endIndex, pattern[index] == mark {
                index = pattern.index(after: index)
            }
            spaced = index < pattern.endIndex && pattern[index].isWhitespace
        } else if markIndex > pattern.startIndex {
            spaced = pattern[pattern.index(before: markIndex)].isWhitespace
        }
        return (leading, spaced ? noBreakSpace : "")
    }
}
