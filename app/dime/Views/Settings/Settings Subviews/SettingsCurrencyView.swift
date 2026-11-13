//
//  SettingsCurrencyView.swift
//  dime
//
//  Created by Rafael Soh on 5/11/23.
//

import Foundation
import SwiftUI
import WidgetKit

struct SettingsCurrencyView: View {
    @AppStorage("currency", store: UserDefaults.appGroup)
    var currencyCode: String = MoneyFormat.defaultCurrencyCode
    @AppStorage("currencySymbolOverride", store: UserDefaults.appGroup)
    var symbolOverride: String = ""
    @AppStorage("showCents", store: UserDefaults.appGroup)
    var showCents: Bool = true
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    // Built once per visit: the list makes a Locale lookup for each of its codes.
    @State private var currencies: [Currency] = []
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    @Namespace var animation

    /// Metals, fund units and retired codes that nobody keeps a budget in.
    private static let hiddenCodes: Set<String> = ["XAU", "XAG", "XPD", "XPT", "XBA", "XBB", "XDR", "XFU", "BOV", "CHE", "CHW", "CLF", "COU", "MXV", "LTL", "LVL", "STD", "HRK", "SLL"]

    private static let pinnedCodes = ["UZS", "USD", "EUR", "RUB", "KZT"]

    private var pinned: [Currency] {
        var codes = Self.pinnedCodes
        let deviceCode = MoneyFormat.defaultCurrencyCode

        if !codes.contains(deviceCode) {
            codes.insert(deviceCode, at: 0)
        }

        if !codes.contains(currencyCode) {
            codes.insert(currencyCode, at: 0)
        }

        return codes.compactMap { code in currencies.first { $0.code == code } }
    }

    private var filtered: [Currency] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !text.isEmpty else {
            return currencies
        }

        return currencies.filter { $0.code.lowercased().contains(text) || $0.name.lowercased().contains(text) }
    }

    private var previewText: String {
        let settings = MoneySettings.resolve(currency: currencyCode, showCents: showCents, symbolOverride: symbolOverride)

        return MoneyFormat.string(35_880_000, settings: settings)
    }

    var body: some View {
        VStack(spacing: 10) {
            SettingsSubviewHeader(title: "Currencies")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.SubtitleText)

                TextField("Search", text: $query)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(Color.PrimaryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.done)
                    .focused($searchFocused)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.body, design: .rounded))
                            .foregroundColor(Color.SubtitleText)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if query.isEmpty {
                        SettingsSectionTitle(text: "SYMBOL")

                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text("Own symbol")
                                    .font(.system(.body, design: .rounded))
                                    .foregroundColor(Color.PrimaryText)

                                TextField(MoneyFormat.symbol(for: currencyCode), text: $symbolOverride)
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .foregroundColor(Color.PrimaryText)
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .submitLabel(.done)
                            }
                            .padding(.vertical, 11)

                            Divider()

                            SettingsValueRow(title: "Example", value: previewText, valueColor: Color.PrimaryText)
                        }
                        .padding(.horizontal, 15)
                        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))

                        SettingsFootnote(text: "Leave the symbol empty to use the standard one. Up to 5 characters.")
                            .padding(.bottom, 8)

                        SettingsSectionTitle(text: "FREQUENT")

                        card(pinned)
                            .padding(.bottom, 8)

                        SettingsSectionTitle(text: "ALL CURRENCIES")
                    }

                    if filtered.isEmpty {
                        Text("Nothing found")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundColor(Color.SubtitleText)
                            .padding(.vertical, 30)
                    } else {
                        card(filtered)
                    }

                    SettingsFootnote(text: "Changing the currency only changes how amounts are shown. Nothing is converted.")
                }
                .padding(.bottom, 90)
            }
            .scrollDismissesKeyboard(.immediately)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(SettingsSubviewModifier())
        .onAppear {
            if currencies.isEmpty {
                currencies = Currency.allCurrencies.filter { !Self.hiddenCodes.contains($0.code) || $0.code == currencyCode }
            }
        }
        .onChange(of: symbolOverride) { newValue in
            let trimmed = String(newValue.trimmingCharacters(in: .newlines).prefix(5))

            if trimmed != newValue {
                symbolOverride = trimmed
            }

            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func card(_ list: [Currency]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(list, id: \.code) { currency in
                Button {
                    select(currency)
                } label: {
                    HStack(spacing: 10) {
                        Text(currency.code)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundColor(Color.SubtitleText)
                            .lineLimit(1)
                            .frame(width: dynamicTypeSize > .xLarge ? 55 : 45, alignment: .leading)

                        Text(currency.name)
                            .font(.system(.body, design: .rounded))
                            .foregroundColor(Color.PrimaryText)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if currency.code == currencyCode {
                            Image(systemName: "checkmark")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.DarkIcon.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if currency.code != list.last?.code {
                            Divider()
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(currency.code == currencyCode ? .isSelected : [])
            }
        }
        .padding(.horizontal, 15)
        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    private func select(_ currency: Currency) {
        guard currency.code != currencyCode else {
            return
        }

        Haptics.selection()

        withAnimation(.easeIn(duration: 0.15)) {
            currencyCode = currency.code
        }

        // A symbol typed for the old currency would be wrong for the new one.
        symbolOverride = ""

        // The stored cents and number entry settings stay as they are: a currency without
        // small change overrides them while it is selected, and they come back afterwards.
        NSUbiquitousKeyValueStore.default.set(currency.code, forKey: "currency")
        WidgetCenter.shared.reloadAllTimelines()
        searchFocused = false
    }
}
