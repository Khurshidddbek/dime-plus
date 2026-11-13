//
//  AmountText.swift
//  dime
//

import SwiftUI

// Compiled into the app and the widget extension: no packages, no app-only helpers.

// True when the drawn amount is the compact form. Read by .amountReveal() in the app.
struct AmountCompactPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct AmountText: View {
    enum Role {
        case hero // 50 pt, Log summary and entry
        case title // 34 pt, budget gauges and detail headers
        case headline // 28 pt, Insights headline, big widget numbers
        case row // 20 pt, list rows and cards
        case caption // 16 pt, day headers, chips
        case micro // 11 pt, labels under bars and gauges
    }

    enum Style {
        case uniform // one font and colour for the whole string
        case hero // large integer part, smaller symbol and decimals
    }

    enum Fit {
        case ladder // full size, shrink to the floor, then compact
        case fullOnly // never compact, keeps shrinking below the floor instead
        case compactAlways // chart labels, lock screen, tiny widget slots
    }

    private let value: Double
    private let weight: Font.Weight
    private let style: Style
    private let secondaryRatio: CGFloat
    private let sign: MoneySign
    private let fit: Fit
    private let color: Color
    private let secondaryColor: Color?
    private let minimumScale: CGFloat
    private let fractionDigits: Int?
    private let monospacedDigits: Bool
    private let dimsZero: Bool
    private let animated: Bool

    @ScaledMetric private var size: CGFloat

    // Own subscriptions: a static snapshot would leave stale amounts on screens that are already alive.
    @AppStorage("currency", store: UserDefaults.appGroup) private var currency: String = MoneyFormat.defaultCurrencyCode
    @AppStorage("showCents", store: UserDefaults.appGroup) private var showCents: Bool = true
    @AppStorage("currencySymbolOverride", store: UserDefaults.appGroup) private var symbolOverride: String = ""

    init(
        _ value: Double,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle = .body,
        weight: Font.Weight = .medium,
        style: Style = .uniform,
        secondaryRatio: CGFloat = 0.6,
        sign: MoneySign = .automatic,
        fit: Fit = .ladder,
        color: Color = Color.PrimaryText,
        secondaryColor: Color? = nil,
        minimumScale: CGFloat = 0.72,
        fractionDigits: Int? = nil,
        monospacedDigits: Bool = false,
        dimsZero: Bool = false,
        animated: Bool = false
    ) {
        self.value = value
        self.weight = weight
        self.style = style
        self.secondaryRatio = secondaryRatio
        self.sign = sign
        self.fit = fit
        self.color = color
        self.secondaryColor = secondaryColor
        self.minimumScale = min(1, max(0.3, minimumScale))
        self.fractionDigits = fractionDigits
        self.monospacedDigits = monospacedDigits
        self.dimsZero = dimsZero
        self.animated = animated
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    init(
        _ value: Double,
        role: Role,
        sign: MoneySign = .automatic,
        fit: Fit = .ladder,
        color: Color = Color.PrimaryText,
        secondaryColor: Color? = nil,
        fractionDigits: Int? = nil,
        dimsZero: Bool = false,
        animated: Bool = false
    ) {
        let size: CGFloat
        let textStyle: Font.TextStyle
        let weight: Font.Weight
        let style: Style
        let ratio: CGFloat
        let monospaced: Bool

        switch role {
        case .hero:
            size = 50; textStyle = .largeTitle; weight = .regular; style = .hero; ratio = 0.5; monospaced = false
        case .title:
            size = 34; textStyle = .largeTitle; weight = .medium; style = .hero; ratio = 0.6; monospaced = false
        case .headline:
            size = 28; textStyle = .title; weight = .medium; style = .hero; ratio = 0.6; monospaced = false
        case .row:
            size = 20; textStyle = .title3; weight = .medium; style = .hero; ratio = 0.65; monospaced = true
        case .caption:
            size = 16; textStyle = .callout; weight = .semibold; style = .uniform; ratio = 1; monospaced = true
        case .micro:
            size = 11; textStyle = .caption2; weight = .medium; style = .uniform; ratio = 1; monospaced = false
        }

        self.init(
            value, size: size, relativeTo: textStyle, weight: weight, style: style, secondaryRatio: ratio,
            sign: sign, fit: fit, color: color, secondaryColor: secondaryColor, fractionDigits: fractionDigits,
            monospacedDigits: monospaced, dimsZero: dimsZero, animated: animated
        )
    }

    var body: some View {
        let settings = MoneySettings.resolve(currency: currency, showCents: showCents, symbolOverride: symbolOverride)
        let full = MoneyFormat.parts(value, sign: sign, settings: settings, fractionDigits: fractionDigits)
        let compact = MoneyFormat.compactParts(value, sign: sign, settings: settings)

        fitted(full: full, compact: compact)
            .contentTransition(.numericText(value: value.isFinite ? value : 0))
            .animation(animated ? Animation.snappy : nil, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(MoneyFormat.spoken(value, sign: sign, settings: settings)))
    }

    @ViewBuilder
    private func fitted(full: MoneyParts, compact: MoneyParts) -> some View {
        let middleScale = (1 + minimumScale) / 2

        switch fit {
        case .ladder:
            // ViewThatFits compares ideal sizes, so every step has an explicit font size.
            // Only the last one may scale: it is the one used when nothing fits.
            ViewThatFits(in: .horizontal) {
                line(full, scale: 1).lineLimit(1).fixedSize()
                line(full, scale: middleScale).lineLimit(1).fixedSize()
                line(full, scale: minimumScale).lineLimit(1).fixedSize()
                line(compact, scale: 1).lineLimit(1).minimumScaleFactor(0.7)
                    .preference(key: AmountCompactPreferenceKey.self, value: compact.isCompact)
            }
        case .fullOnly:
            ViewThatFits(in: .horizontal) {
                line(full, scale: 1).lineLimit(1).fixedSize()
                line(full, scale: middleScale).lineLimit(1).fixedSize()
                line(full, scale: minimumScale).lineLimit(1).minimumScaleFactor(0.7)
            }
        case .compactAlways:
            line(compact, scale: 1).lineLimit(1).minimumScaleFactor(0.7)
                .preference(key: AmountCompactPreferenceKey.self, value: compact.isCompact)
        }
    }

    private func line(_ parts: MoneyParts, scale: CGFloat) -> Text {
        let mainSize = size * scale
        let plainFont = Font.system(size: mainSize, weight: weight, design: .rounded)
        let mainFont = monospacedDigits ? plainFont.monospacedDigit() : plainFont
        let mainColor = (dimsZero && value == 0) ? Color.SubtitleText : color

        if style == .uniform {
            return Text(parts.text).font(mainFont).foregroundColor(mainColor)
        }

        let smallFont = Font.system(size: mainSize * secondaryRatio, weight: weight, design: .rounded)
        let smallColor = secondaryColor ?? Color.SubtitleText

        var text: Text
        if parts.symbolLeading, !parts.symbol.isEmpty {
            text = Text(parts.sign + parts.symbol + parts.symbolSeparator).font(smallFont).foregroundColor(smallColor)
                + Text(parts.integer).font(mainFont).foregroundColor(mainColor)
        } else {
            text = Text(parts.sign + parts.integer).font(mainFont).foregroundColor(mainColor)
        }

        if !parts.fraction.isEmpty {
            // In the compact form the fraction carries the value ("35,9"), so it stays large.
            if parts.isCompact {
                text = text + Text(parts.fraction).font(mainFont).foregroundColor(mainColor)
            } else {
                text = text + Text(parts.fraction).font(smallFont).foregroundColor(smallColor)
            }
        }

        if parts.isCompact {
            text = text + Text(parts.unitSeparator + parts.unit).font(smallFont).foregroundColor(smallColor)
        }

        if !parts.symbolLeading, !parts.symbol.isEmpty {
            text = text + Text(parts.symbolSeparator + parts.symbol).font(smallFont).foregroundColor(smallColor)
        }

        return text
    }
}
