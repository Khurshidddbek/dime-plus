//
//  Currency.swift
//  dime
//
//  Created by Rafael Soh on 5/9/22.
//

import Foundation

struct Currency: Hashable {
    let name: String
    let code: String
    let symbol: String
}

extension Locale {
    // Kept optional for the old call sites that force-unwrap it. Never returns nil now.
    func localizedCurrencySymbol(forCurrencyCode currencyCode: String) -> String? {
        MoneyFormat.symbol(for: currencyCode)
    }
}

extension Currency {
    // Default for every @AppStorage("currency") declaration.
    static var defaultCode: String { MoneyFormat.defaultCurrencyCode }

    static var currencyCodes: [String] = ["AED", "AFN", "ALL", "AMD", "ANG", "AOA", "ARS", "AUD", "AWG", "AZN", "BAM", "BBD", "BDT", "BGN", "BHD", "BIF", "BMD", "BND", "BOB", "BOV", "BRL", "BSD", "BTN", "BWP", "BYN", "BZD", "CAD", "CDF", "CHE", "CHF", "CHW", "CLF", "CLP", "CNY", "COP", "COU", "CRC", "CUC", "CUP", "CVE", "CZK", "DJF", "DKK", "DOP", "DZD", "EGP", "ERN", "ETB", "EUR", "FJD", "FKP", "GBP", "GEL", "GHS", "GIP", "GMD", "GNF", "GTQ", "GYD", "HKD", "HNL", "HRK", "HTG", "HUF", "IDR", "ILS", "INR", "IQD", "IRR", "ISK", "JMD", "JOD", "JPY", "KES", "KGS", "KHR", "KMF", "KPW", "KRW", "KWD", "KYD", "KZT", "LAK", "LBP", "LKR", "LRD", "LSL", "LTL", "LVL", "LYD", "MAD", "MDL", "MGA", "MKD", "MMK", "MNT", "MOP", "MUR", "MVR", "MWK", "MXN", "MXV", "MYR", "MZN", "NAD", "NGN", "NIO", "NOK", "NPR", "NZD", "OMR", "PAB", "PEN", "PGK", "PHP", "PKR", "PLN", "PYG", "QAR", "RON", "RSD", "RUB", "RWF", "SAR", "SBD", "SCR", "SDG", "SEK", "SGD", "SHP", "SLL", "SOS", "SRD", "SSP", "STD", "SYP", "SZL", "THB", "TJS", "TMT", "TND", "TOP", "TRY", "TTD", "TWD", "TZS", "UAH", "UGX", "USD", "UYU", "UZS", "VND", "VUV", "WST", "XAF", "XAG", "XAU", "XBA", "XBB", "XCD", "XDR", "XFU", "XOF", "XPD", "XPF", "XPT", "YER", "ZAR", "ZMW"]

    static var allCurrencies: [Currency] {
        let currencies: [Currency] = currencyCodes.compactMap {
            let name = Locale.current.localizedString(forCurrencyCode: $0) ?? ""
            let symbol = MoneyFormat.symbol(for: $0)
            return Currency(name: name, code: $0, symbol: symbol)
        }
        return currencies
    }
}
