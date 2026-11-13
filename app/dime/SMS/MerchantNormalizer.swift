//
//  MerchantNormalizer.swift
//  dime
//
//  Turns the merchant text of a bank SMS into a stable key (for rules) and a readable
//  name (for the transaction note). Foundation only.
//
//  "YandexGO Taxi UB OPL"                    key "yandexgo taxi"   name "YandexGO Taxi"
//  "alifnasiyauz rassroc", "ALIFNASIYA.UZ"   key "alifnasiya"      name "Alifnasiya"
//  "TBC CASHBACK>TASHKEN"                    key "tbc cashback"    name "TBC Cashback", city "TASHKEN"
//  "AT ASAKA BANK TOSHKENT SHAHAR FILIALI"   key "asaka bank"      name "Asaka Bank"
//

import Foundation

enum MerchantNormalizer {
    // Words that say nothing about the merchant: operation leftovers, legal forms, cities.
    // Transfer markers (h2u, p2p, "to") are NOT here: "tbc h2u" and "tbc cashback" must stay two rules.
    static let noise: Set<String> = Set(
        """
        ub opl oplata tolov pay payment rassroc rassrochka popoln popolnenie na k v s epos edin pos \
        uz uzb com ru llc ooo mchj mchdj xk ok qk ip yatt at aj atb filial filiali viloyat viloyati shahar tuman \
        tashkent tashken tashke toshkent toshken tash tas fargona fergana samarkand samarqand buxoro bukhara \
        andijon namangan the
        """
        .split(separator: " ").map { String($0) }
    )

    // Kept lowercase when a name is title-cased: "Uzcard to Visa".
    static let connectors: Set<String> = ["to", "na"]

    /// Humo puts a (cut) city after ">": "TBC CASHBACK>TASHKEN".
    static func city(_ raw: String) -> String? {
        let parts = raw.components(separatedBy: ">")

        guard parts.count > 1 else {
            return nil
        }

        let city = parts[1].trimmingCharacters(in: .whitespaces)

        return city.isEmpty ? nil : city
    }

    static func tokens(_ raw: String) -> [String] {
        let base = raw.components(separatedBy: ">").first ?? raw
        let folded = SMSText.fold(base)

        return folded.split(whereSeparator: { character in !(character.isLetter || character.isNumber) }).map { String($0) }
    }

    /// At most 3 meaningful tokens, lowercase: "yandexgo taxi".
    static func key(_ raw: String) -> String {
        let all = tokens(raw)

        var significant = all.filter { token in
            if noise.contains(token) || token.count < 2 {
                return false
            }

            return !token.allSatisfy { character in character.isNumber }
        }

        if significant.isEmpty {
            significant = all
        }

        let limited = significant.prefix(3).map { token -> String in
            // "alifnasiyauz" is "alifnasiya.uz" with the dot lost.
            if token.count >= 8, token.hasSuffix("uz") {
                return String(token.dropLast(2))
            }

            return token
        }

        return limited.joined(separator: " ")
    }

    /// Readable name that becomes the transaction note: "YandexGO Taxi".
    static func display(_ raw: String) -> String {
        let base = (raw.components(separatedBy: ">").first ?? raw).trimmingCharacters(in: .whitespaces)
        let words = base.split(separator: " ").map { String($0) }

        var kept = words

        if words.count > 1 {
            kept = words.filter { word in
                let bare = String(word.filter { character in character.isLetter || character.isNumber })
                return !noise.contains(SMSText.fold(bare))
            }
        }

        var name = kept.isEmpty ? base : kept.joined(separator: " ")
        let lowered = name.lowercased()

        for suffix in [".uz", ".com", ".ru"] where lowered.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }

        let trimmed = name.split(separator: " ").map { part -> String in
            let word = String(part)

            if word.count >= 8, word.lowercased().hasSuffix("uz"), !word.contains(".") {
                return String(word.dropLast(2))
            }

            return word
        }

        name = trimmed.joined(separator: " ")

        // Mixed case was typed by a person ("YandexGO Taxi"): leave it alone.
        if name != name.uppercased(), name != name.lowercased() {
            return name
        }

        let titled = trimmed.map { word -> String in
            let lower = word.lowercased()

            if connectors.contains(lower) {
                return lower
            }

            // Short words and words with digits are abbreviations: TBC, H2U.
            if word.count <= 3 || word.contains(where: { character in character.isNumber }) {
                return word.uppercased()
            }

            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }

        return titled.joined(separator: " ")
    }
}
