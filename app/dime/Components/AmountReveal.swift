//
//  AmountReveal.swift
//  dime
//

import Popovers
import SwiftUI

// App target only (Popovers and Haptics are not linked into the widget).
// Opt-in: put it on an AmountText that may fall back to the compact form and has no
// tap action of its own or of its parent. It does nothing while the full value is drawn.

private struct AmountRevealModifier: ViewModifier {
    let value: Double
    let sign: MoneySign

    @State private var isCompact = false
    @State private var showFull = false

    @AppStorage("currency", store: UserDefaults.appGroup) private var currency: String = MoneyFormat.defaultCurrencyCode
    @AppStorage("showCents", store: UserDefaults.appGroup) private var showCents: Bool = true
    @AppStorage("currencySymbolOverride", store: UserDefaults.appGroup) private var symbolOverride: String = ""

    private var fullText: String {
        let settings = MoneySettings.resolve(currency: currency, showCents: showCents, symbolOverride: symbolOverride)
        return MoneyFormat.string(value, sign: sign, settings: settings)
    }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(AmountCompactPreferenceKey.self) { newValue in
                isCompact = newValue
                if !newValue {
                    showFull = false
                }
            }
            .contentShape(Rectangle())
            // Simultaneous, so a parent tap handler keeps working. Switched off while the full value is on screen.
            .simultaneousGesture(
                TapGesture().onEnded {
                    Haptics.tap()
                    showFull.toggle()
                },
                including: isCompact ? .all : .subviews
            )
            .popover(present: $showFull, attributes: {
                $0.position = .absolute(
                    originAnchor: .top,
                    popoverAnchor: .bottom
                )
                $0.rubberBandingMode = .none
                $0.sourceFrameInset = UIEdgeInsets(top: -6, left: 0, bottom: 0, right: 0)
                $0.presentation.animation = .easeInOut(duration: 0.2)
                $0.dismissal.animation = .easeInOut(duration: 0.2)
            }) {
                Text(fullText)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                    .onTapGesture {
                        showFull = false
                    }
            }
            .task(id: showFull) {
                guard showFull else { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if !Task.isCancelled {
                    showFull = false
                }
            }
    }
}

extension View {
    // Tap shows a bubble with the full grouped value when the amount was drawn compact.
    func amountReveal(_ value: Double, sign: MoneySign = .automatic) -> some View {
        modifier(AmountRevealModifier(value: value, sign: sign))
    }
}
