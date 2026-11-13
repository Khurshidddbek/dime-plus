//
//  SMSParser.swift
//  dime
//
//  Bank SMS parser. Foundation only, no UIKit and no Core Data, so it can be moved
//  into a test target as is.
//
//  Real messages the templates were written against (also in SMSParserSelfCheck):
//  1. HUMOCARD *4417: oplata 3960000.00 UZS; Humo to Visa>Tashken; 25-03-10 16:09;  Dostupno: 48825285.78 UZS
//  2. HUMOCARD *4417: popolnenie 14850.00 UZS; TBC CASHBACK>TASHKEN; 25-03-12 14:41;  Dostupno: 45749635.83 UZS
//  3. HUMOCARD *4417: oplata 42000.00 UZS; YandexGO Taxi UB OPL; 25-03-12 16:06;  Dostupno: 45707635.83 UZS
//  4. HUMOCARD *4417: popolnenie 29999999.97 UZS; ORIENT POPOLN NA K; 25-03-12 19:14;  Dostupno: 74159635.80 UZS
//  5. HUMOCARD *4417: oplata 690090.00 UZS; alifnasiyauz rassroc; 25-03-12 19:22;  Dostupno: 107509886.10 UZS
//  6. Kartaga o'tkazma: TBC EDIN EPOS H2U, UZ,12.03.25 03:27,karta ***8821. Miqdor:1046448.00 UZS Qoldiq:16954545.96 UZS
//  7. Bankomatda naqd pul yechish: AT ASAKA BANK TOSHKENT SHAHAR FILIALI, UZ,10.03.25 10:20,karta ***8821. Miqdor:5454000.00 UZS Qoldiq:10195548.48 UZS
//  8. To'lov: ALIFNASIYA.UZ, UZ,11.03.25 03:31,karta ***8821. Miqdor:835696.80 UZS Qoldiq:10418851.68 UZS
//     (the real one has the typographic apostrophe U+2018 in "To'lov")
//  9. To'lov: UZCARD TO VISA, UZ,09.03.25 22:30,karta ***8821. Miqdor:300000.00 UZS Qoldiq:15649548.48 UZS
//

import Foundation

enum SMSKind: String, Codable {
    case payment // card payment, real spending
    case topUp // incoming money
    case transfer // card to card marker in the merchant, direction is still filled
    case atmWithdrawal
    case refund
    case ignored // one-time code or declined operation, never shown
    case unknown // could not tell what it is
}

enum SMSDirection: String, Codable {
    case expense
    case income
}

struct ParsedSMS: Codable, Equatable {
    var format: String // "humo" | "uzcard" | "generic"
    var kind: SMSKind
    var direction: SMSDirection?
    /// Amount in 1/100 of the currency unit: 3960000.00 is 396000000. Exact, safe to compare and to store.
    var amountMinor: Int64?
    var currency: String? // "UZS"
    var merchantRaw: String // "YandexGO Taxi UB OPL"
    var merchantKey: String // "yandexgo taxi"
    var merchantDisplay: String // "YandexGO Taxi"
    var city: String?
    /// Time of the operation. Falls back to the receive time when the text has no readable date,
    /// and is never later than the receive time (a future date hides the row from the Log).
    var date: Date
    var dateFromText: Bool
    var cardLast4: String?
    var balanceMinor: Int64?
    /// The merchant names two card networks ("Humo to Visa"): a transfer between own cards.
    var namesTwoNetworks: Bool
    var confidence: Double // 1 template, 0.5 generic with direction, 0.3 generic without, 0 no amount
    var fingerprint: String

    var amount: Decimal? {
        amountMinor.map { Decimal($0) / 100 }
    }

    var balance: Decimal? {
        balanceMinor.map { Decimal($0) / 100 }
    }

    var amountValue: Double? {
        amountMinor.map { Double($0) / 100 }
    }

    var isIncome: Bool {
        direction == .income
    }
}

enum SMSText {
    // Typographic apostrophes banks use in "To'lov", "o'tkazma", "so'm".
    static let apostrophes: Set<Unicode.Scalar> = [
        "\u{2018}", "\u{2019}", "\u{02BB}", "\u{02BC}", "\u{0060}", "\u{00B4}", "\u{2032}", "\u{02B9}",
    ]

    // Invisible characters Shortcuts and Messages can put around the text.
    static let invisibles: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{2060}", "\u{FEFF}",
    ]

    /// Apostrophe variants to ', then NFKC, then every run of unicode spaces to one space.
    /// The apostrophes must be mapped BEFORE NFKC: NFKC turns U+00B4 into "space + U+0301",
    /// which would split "To'lov" into two words.
    static func normalize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()

        for scalar in raw.unicodeScalars {
            if invisibles.contains(scalar) {
                continue
            }

            if apostrophes.contains(scalar) {
                scalars.append("'")
            } else {
                scalars.append(scalar)
            }
        }

        let composed = String(scalars).precomposedStringWithCompatibilityMapping
        let parts = composed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        return parts.joined(separator: " ")
    }

    /// Lowercase, no diacritics, no apostrophes: "To'lov" gives "tolov", "o'tkazma" gives "otkazma".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
    }
}

enum SMSParser {
    static let bankTimeZone = TimeZone(identifier: "Asia/Tashkent") ?? TimeZone(secondsFromGMT: 5 * 3600) ?? TimeZone.current

    // MARK: Patterns

    private static let amt = #"\d[\d ',.]*\d|\d"# // 42000.00 | 3 960 000,00 | 1'320'000.00 | 5

    // groups: 1 card, 2 operation, 3 amount, 4 currency, 5 merchant, 6 date, 7 balance?, 8 balance currency?
    private static let humo = rx(
        #"^HUMO\s*CARD\s*\*+\s*(\d{4})\s*:\s*([\p{L}' ]+?)\s+("# + amt
            + #")\s*([A-Za-z]{3})\s*;\s*(.*?)\s*;\s*(\d{2}-\d{2}-\d{2}\s+\d{1,2}:\d{2})\s*;?\s*(?:Dostupno\s*:\s*(-?(?:"#
            + amt + #"))\s*([A-Za-z]{3}))?"#
    )

    // groups: 1 operation, 2 merchant, 3 country, 4 date, 5 card, 6 amount, 7 currency, 8 balance?, 9 balance currency?
    // The merchant group is lazy and must be followed by ", <2 letters>, <date>", so commas inside
    // the merchant ("AT ASAKA BANK TOSHKENT SHAHAR FILIALI, UZ") stay in it.
    private static let uzcard = rx(
        #"^([^:]{3,60}?)\s*:\s*(.+?)\s*,\s*([A-Za-z]{2})\s*,\s*(\d{2}\.\d{2}\.\d{2,4}\s+\d{1,2}:\d{2})\s*,\s*(?:karta|card)\s*\*+\s*(\d{4})\s*\.?\s*(?:Miqdor|Summa)\s*:\s*("#
            + amt + #")\s*([A-Za-z]{3})\s*(?:(?:Qoldiq|Balans)\s*:\s*(-?(?:"# + amt + #"))\s*([A-Za-z]{3}))?"#
    )

    private static let genericBalance = rx(
        #"(?:dostupno|qoldiq|balans|balance|ostatok|mavjud|available|остаток|доступно|баланс|қолдиқ)\s*:?\s*(-?(?:"#
            + amt + #"))\s*([A-Za-z']{3,4})?"#
    )
    private static let genericAmount = rx(
        #"(?<![\d*.,:-])(-?(?:"# + amt + #"))\s*(UZS|USD|EUR|RUB|KZT|sum|so'm|som|сум|сўм)(?![a-z])"#
    )
    private static let genericCard = rx(#"(?:\*+|x{2,}|karta\s*|card\s*)\s*(\d{4})(?!\d)"#)
    private static let genericDateDMY = rx(#"(?<!\d)(\d{2})[.\-/](\d{2})[.\-/](\d{2,4})\s+(\d{1,2}):(\d{2})"#)
    private static let genericDateISO = rx(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})"#)
    private static let threeLetters = rx(#"\p{L}{3}"#)
    private static let longNumber = rx(#"\d{4,}"#)
    private static let bankWords = rx(#"humo\s*card|\bkarta\b|\bmiqdor\b|\bqoldiq\b|\bdostupno\b"#)

    // "Humo to Visa", "UZCARD TO VISA". No "-" and no ">" among the connectors:
    // "MC-MIR SHOP" is a shop and ">" separates the city in Humo messages.
    private static let networks = "(?:humo|uzcard|visa|mastercard|master|mc|mir|unionpay|upi)"
    private static let networkPair = rx(#"\b"# + networks + #"\s*(?:to|2|na)\s*"# + networks + #"\b"#)
    private static let transferWord = rx(#"\b(?:p2p|h2u|u2h|h2h|u2u|h2v|u2v|v2h|v2u|card2card|c2c|perevod|otkazma)\b"#)

    private static let humoStart = rx(#"HUMO\s*CARD\s*\*"#)
    // "[12.03.25, 16:06] HUMOCARD: " in front of a message exported from Messages.
    private static let exportPrefix = rx(#"^\[[^\]]{5,30}\]\s*[^:]{2,20}:\s*"#)
    private static let balanceLine = rx(#"^(?:dostupno|qoldiq|balans|balance|ostatok|mavjud|available)\b"#)

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants checked against the samples. A broken one must not crash
        // a background run, it just never matches.
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            return regex
        }

        return NSRegularExpression()
    }

    // MARK: Entry points

    static func parse(_ raw: String, receivedAt: Date = Date()) -> ParsedSMS {
        let text = SMSText.normalize(raw)

        // A lead-in with a colon ("[12.03.25, 16:06] UZCARD: ") lets the Uzcard template match the
        // whole text with a junk operation, so a half-read candidate does not stop the search.
        var halfRead: ParsedSMS?

        for candidate in templateCandidates(text) {
            guard let parsed = parseHumo(candidate, receivedAt: receivedAt) ?? parseUzcard(candidate, receivedAt: receivedAt) else {
                continue
            }

            if parsed.confidence == 1 {
                return parsed
            }

            if halfRead == nil {
                halfRead = parsed
            }
        }

        if let parsed = halfRead {
            return parsed
        }

        return parseGeneric(text, receivedAt: receivedAt)
    }

    /// Cheap test used for pasted lines and the clipboard: is this text worth keeping as "unrecognised"?
    static func looksLikeBankMessage(_ raw: String) -> Bool {
        let text = SMSText.normalize(raw)

        if text.count < 12 {
            return false
        }

        for candidate in templateCandidates(text) {
            if humo.firstMatch(in: candidate) != nil || uzcard.firstMatch(in: candidate) != nil {
                return true
            }
        }

        if genericAmount.firstMatch(in: text) != nil {
            return true
        }

        return bankWords.firstMatch(in: text) != nil && longNumber.firstMatch(in: text) != nil
    }

    /// Splits a pasted block (many forwarded SMS) into single messages.
    static func splitMessages(_ blob: String) -> [String] {
        // 1. Every "HUMOCARD *" starts a new message even without a line break.
        let marked = NSMutableString(string: blob)
        let source = blob as NSString
        let starts = humoStart.matches(in: blob, options: [], range: NSRange(location: 0, length: source.length))

        for match in starts.reversed() where match.range.location > 0 {
            // Only a previous message on the same line is cut off. A short lead-in
            // ("[12.03.2025, 16:06] HUMOCARD: ") stays with its message: the templates skip it,
            // and on a line of its own it would land in the inbox as unrecognised.
            let before = source.substring(to: match.range.location) as NSString
            let lineBreak = before.rangeOfCharacter(from: .newlines, options: .backwards)
            let lead = lineBreak.location == NSNotFound ? (before as String) : before.substring(from: lineBreak.location + lineBreak.length)

            if lead.count <= 40, !lead.contains(";") {
                continue
            }

            marked.insert("\n", at: match.range.location)
        }

        let lines = (marked as String).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 2. A line that starts with the balance word belongs to the message above it.
        var merged = [String]()

        for line in lines {
            if balanceLine.firstMatch(in: line) != nil, let last = merged.last {
                merged[merged.count - 1] = last + " " + line
            } else {
                merged.append(line)
            }
        }

        // 3. A message wrapped over several lines: glue up to 3 following lines and take the
        //    shortest glue that parses as a template. Lines that are complete on their own are never eaten.
        var result = [String]()
        var index = 0

        while index < merged.count {
            var taken = 1

            if parse(merged[index]).confidence < 1 {
                var count = 2

                while count <= 4, index + count <= merged.count {
                    let tail = merged[(index + 1) ..< (index + count)].joined(separator: " ")

                    if parse(tail).confidence == 1 {
                        break
                    }

                    let glued = merged[index ..< (index + count)].joined(separator: " ")

                    if parse(glued).confidence == 1 {
                        taken = count
                        break
                    }

                    count += 1
                }
            }

            result.append(merged[index ..< (index + taken)].joined(separator: " "))
            index += taken
        }

        return result
    }

    /// A message in the Humo format dated `now`, for the "Test with a sample" button.
    static func sampleMessage(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = bankTimeZone

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let stamp = String(
            format: "%02d-%02d-%02d %02d:%02d",
            (parts.year ?? 2026) % 100, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0
        )

        return "HUMOCARD *4417: oplata 42000.00 UZS; YandexGO Taxi UB OPL; \(stamp);  Dostupno: 45707635.83 UZS"
    }

    // MARK: Templates

    private static func templateCandidates(_ text: String) -> [String] {
        var candidates = [text]
        let ns = text as NSString

        // Shortcuts may pass "sender + body": cut everything before the Humo header.
        if let match = humoStart.firstMatch(in: text), match.range.location > 0 {
            candidates.append(ns.substring(from: match.range.location))
        }

        if let match = exportPrefix.firstMatch(in: text), match.range.length < ns.length {
            candidates.append(ns.substring(from: match.range.location + match.range.length))
        }

        return candidates
    }

    private static func parseHumo(_ text: String, receivedAt: Date) -> ParsedSMS? {
        guard let groups = humo.groups(in: text), groups.count >= 9,
              let card = groups[1], let operation = groups[2], let amountText = groups[3],
              let currency = groups[4], let merchant = groups[5], let dateText = groups[6]
        else {
            return nil
        }

        // Humo prints yy-MM-dd. The swapped reading covers a firmware that prints dd-MM-yy.
        let numbers = ints(dateText)
        var parsedDate: Date?

        if numbers.count == 5 {
            parsedDate = plausible(
                makeDate(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4]),
                swapped: makeDate(year: numbers[2], month: numbers[1], day: numbers[0], hour: numbers[3], minute: numbers[4]),
                now: receivedAt
            )
        }

        return build(
            format: "humo", operation: operation, amountText: amountText, currency: currency, merchant: merchant,
            parsedDate: parsedDate, receivedAt: receivedAt, card: card, balanceText: groups[7], text: text
        )
    }

    private static func parseUzcard(_ text: String, receivedAt: Date) -> ParsedSMS? {
        guard let groups = uzcard.groups(in: text), groups.count >= 10,
              let operation = groups[1], let merchant = groups[2], let dateText = groups[4],
              let card = groups[5], let amountText = groups[6], let currency = groups[7]
        else {
            return nil
        }

        // Uzcard prints dd.MM.yy (or dd.MM.yyyy).
        let numbers = ints(dateText)
        var parsedDate: Date?

        if numbers.count == 5 {
            parsedDate = plausible(
                makeDate(year: numbers[2], month: numbers[1], day: numbers[0], hour: numbers[3], minute: numbers[4]),
                swapped: makeDate(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4]),
                now: receivedAt
            )
        }

        return build(
            format: "uzcard", operation: operation, amountText: amountText, currency: currency, merchant: merchant,
            parsedDate: parsedDate, receivedAt: receivedAt, card: card, balanceText: groups[8], text: text
        )
    }

    private static func build(
        format: String, operation: String, amountText: String, currency: String, merchant: String,
        parsedDate: Date?, receivedAt: Date, card: String?, balanceText: String?, text: String
    ) -> ParsedSMS? {
        guard let amountMinor = minorUnits(amountText) else {
            return nil
        }

        var kind = SMSKind.unknown
        var direction: SMSDirection?

        switch classify(operation) {
        case .some(.declined):
            kind = .ignored
        case .some(.cash):
            kind = .atmWithdrawal
            direction = .expense
        case .some(.refund):
            kind = .refund
            direction = .income
        case .some(.income):
            kind = .topUp
            direction = .income
        case .some(.payment):
            kind = .payment
            direction = .expense
        case .some(.otp), .none:
            // A full template with an amount is never a one-time code: keep it visible.
            kind = .unknown
        }

        let merchantRaw = merchant.trimmingCharacters(in: .whitespaces)
        let marker = transferMarker(in: merchantRaw)

        if marker.any, kind == .payment || kind == .topUp {
            kind = .transfer
        }

        let balanceMinor = balanceText.flatMap { minorUnits($0) }

        return ParsedSMS(
            format: format,
            kind: kind,
            direction: direction,
            amountMinor: amountMinor,
            currency: normalizedCurrency(currency),
            merchantRaw: merchantRaw,
            merchantKey: MerchantNormalizer.key(merchantRaw),
            merchantDisplay: MerchantNormalizer.display(merchantRaw),
            city: MerchantNormalizer.city(merchantRaw),
            date: effectiveDate(parsedDate, receivedAt: receivedAt),
            dateFromText: parsedDate != nil,
            cardLast4: card,
            balanceMinor: balanceMinor,
            namesTwoNetworks: marker.pair && kind == .transfer,
            confidence: direction == nil ? 0.5 : 1,
            fingerprint: fingerprint(
                card: card, direction: direction, amountMinor: amountMinor, parsedDate: parsedDate,
                balanceMinor: balanceMinor, text: text
            )
        )
    }

    // MARK: Generic fallback

    private static func parseGeneric(_ text: String, receivedAt: Date) -> ParsedSMS {
        let operation = classify(text)
        let cardMatch = genericCard.groups(in: text)
        let balanceMatch = genericBalance.firstMatch(in: text)
        let ns = text as NSString

        var result = ParsedSMS(
            format: "generic", kind: .unknown, direction: nil, amountMinor: nil, currency: nil,
            merchantRaw: "", merchantKey: "", merchantDisplay: "", city: nil,
            date: receivedAt, dateFromText: false, cardLast4: nil, balanceMinor: nil,
            namesTwoNetworks: false, confidence: 0,
            fingerprint: fingerprint(card: nil, direction: nil, amountMinor: nil, parsedDate: nil, balanceMinor: nil, text: text)
        )

        let codeOrDeclined = operation == .otp || operation == .declined

        // A code or a declined operation is dropped only when the text has neither a card mask nor
        // a balance. Otherwise a merchant like "KODAK" would make a real payment vanish.
        if codeOrDeclined, cardMatch == nil, balanceMatch == nil {
            result.kind = .ignored
            return result
        }

        // The balance is blanked out so it is not taken for the amount.
        var rest = text
        var balanceMinor: Int64?

        if let match = balanceMatch {
            let valueRange = match.range(at: 1)

            if valueRange.location != NSNotFound {
                balanceMinor = minorUnits(ns.substring(with: valueRange))
            }

            rest = ns.replacingCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }

        result.balanceMinor = balanceMinor
        result.cardLast4 = cardMatch.flatMap { $0.count > 1 ? $0[1] : nil }

        let parsedDate = genericDate(in: text, now: receivedAt)
        result.date = effectiveDate(parsedDate, receivedAt: receivedAt)
        result.dateFromText = parsedDate != nil

        let restNS = rest as NSString

        guard let amountMatch = genericAmount.firstMatch(in: rest),
              amountMatch.numberOfRanges >= 3,
              amountMatch.range(at: 1).location != NSNotFound,
              amountMatch.range(at: 2).location != NSNotFound,
              let amountMinor = minorUnits(restNS.substring(with: amountMatch.range(at: 1)))
        else {
            return result
        }

        result.amountMinor = amountMinor
        result.currency = normalizedCurrency(restNS.substring(with: amountMatch.range(at: 2)))

        if !codeOrDeclined {
            switch operation {
            case .some(.cash):
                result.kind = .atmWithdrawal
                result.direction = .expense
            case .some(.refund):
                result.kind = .refund
                result.direction = .income
            case .some(.income):
                result.kind = .topUp
                result.direction = .income
            case .some(.payment):
                result.kind = .payment
                result.direction = .expense
            default:
                break
            }
        }

        // Merchant: the longest ";" or "," segment that is not a card, a date or an operation word.
        let withoutAmount = restNS.replacingCharacters(in: amountMatch.range, with: " ; ")
        let segments = withoutAmount.components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var merchantRaw = ""

        for segment in segments where !segment.isEmpty {
            if genericCard.firstMatch(in: segment) != nil { continue }
            if genericDateDMY.firstMatch(in: segment) != nil { continue }
            if genericDateISO.firstMatch(in: segment) != nil { continue }
            if classify(segment) != nil { continue }
            if threeLetters.firstMatch(in: segment) == nil { continue }

            if segment.count > merchantRaw.count {
                merchantRaw = segment
            }
        }

        if !merchantRaw.isEmpty {
            let marker = transferMarker(in: merchantRaw)

            if marker.any, result.kind == .payment || result.kind == .topUp {
                result.kind = .transfer
                result.namesTwoNetworks = marker.pair
            }

            result.merchantRaw = merchantRaw
            result.merchantKey = MerchantNormalizer.key(merchantRaw)
            result.merchantDisplay = MerchantNormalizer.display(merchantRaw)
            result.city = MerchantNormalizer.city(merchantRaw)
        }

        result.confidence = result.direction == nil ? 0.3 : 0.5
        result.fingerprint = fingerprint(
            card: result.cardLast4, direction: result.direction, amountMinor: amountMinor,
            parsedDate: parsedDate, balanceMinor: balanceMinor, text: text
        )

        return result
    }

    private static func genericDate(in text: String, now: Date) -> Date? {
        if let groups = genericDateISO.groups(in: text), groups.count >= 6 {
            let numbers = groups.dropFirst().compactMap { $0.flatMap { Int($0) } }

            if numbers.count == 5 {
                let date = makeDate(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4])

                if let found = plausible(date, swapped: nil, now: now) {
                    return found
                }
            }
        }

        if let groups = genericDateDMY.groups(in: text), groups.count >= 6 {
            let numbers = groups.dropFirst().compactMap { $0.flatMap { Int($0) } }

            if numbers.count == 5 {
                let dayFirst = makeDate(year: numbers[2], month: numbers[1], day: numbers[0], hour: numbers[3], minute: numbers[4])
                var yearFirst: Date?

                if numbers[2] < 100 {
                    yearFirst = makeDate(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4])
                }

                return plausible(dayFirst, swapped: yearFirst, now: now)
            }
        }

        return nil
    }

    // MARK: OperationClass classifier

    private enum OperationClass {
        case otp
        case declined
        case cash
        case refund
        case income
        case payment
    }

    // Order matters, the first hit wins. "otkaz" alone is NOT a declined stem: after folding it
    // also matches "Kartaga o'tkazma" (a real incoming transfer), so the declined row uses
    // "otkazano" / "otkaz v", and "kartaga otkazma" is checked before the bare "otkazma".
    private static let operationStems: [(operation: OperationClass, stems: [String])] = {
        let table: [(OperationClass, [String])] = [
            (.otp, ["kod", "code", "parol", "password", "podtverzhd", "tasdiqlash", "код", "пароль", "подтвержд"]),
            (.declined, [
                "otkazano", "otkaz v", "otklon", "rad etildi", "declin", "insufficient", "nedostatochno", "yetarli emas",
                "отказ", "отклон", "недостаточно", "рад этилди",
            ]),
            (.cash, [
                "bankomat", "naqd pul", "snyatie", "nalichn", "cash withdraw", "atm ",
                "банкомат", "снятие", "наличн", "нақд пул",
            ]),
            (.refund, ["vozvrat", "qaytar", "refund", "otmena", "reversal", "bekor", "возврат", "отмена", "қайтар", "бекор"]),
            (.income, [
                "popolnenie", "kartaga otkazma", "zachislen", "postuplen", "kirim", "tushum", "tushdi", "credit",
                "hisobni toldirish", "пополнение", "зачислен", "поступлен", "кирим", "тушум", "тушди",
            ]),
            (.payment, [
                "oplata", "tolov", "pokupka", "xarid", "spisanie", "platezh", "payment", "purchase", "kartadan otkazma",
                "perevod", "otkazma", "debit", "yechildi",
                "оплата", "покупка", "списание", "платеж", "тўлов", "харид", "перевод", "ўтказма", "ечилди",
            ]),
        ]

        var folded = [(operation: OperationClass, stems: [String])]()

        for row in table {
            // Stems go through the same folding as the text, so both sides lose diacritics the same way.
            folded.append((operation: row.0, stems: row.1.map { SMSText.fold($0) }))
        }

        return folded
    }()

    private static func classify(_ text: String) -> OperationClass? {
        // The trailing space lets a stem like "atm " match at the very end.
        let folded = SMSText.fold(text) + " "

        for row in operationStems {
            for stem in row.stems where containsStem(stem, in: folded) {
                return row.operation
            }
        }

        return nil
    }

    /// The stem must start at a word boundary and may continue ("popolnenie karty").
    private static func containsStem(_ stem: String, in folded: String) -> Bool {
        if stem.isEmpty {
            return false
        }

        var searchStart = folded.startIndex

        while searchStart < folded.endIndex,
              let range = folded.range(of: stem, options: [.literal], range: searchStart ..< folded.endIndex)
        {
            if range.lowerBound == folded.startIndex {
                return true
            }

            let previous = folded[folded.index(before: range.lowerBound)]

            if !previous.isLetter {
                return true
            }

            searchStart = folded.index(after: range.lowerBound)
        }

        return false
    }

    private static func transferMarker(in merchant: String) -> (any: Bool, pair: Bool) {
        let beforeCity = merchant.components(separatedBy: ">").first ?? merchant
        let folded = SMSText.fold(beforeCity)
        let pair = networkPair.firstMatch(in: folded) != nil
        let word = transferWord.firstMatch(in: folded) != nil

        return (any: pair || word, pair: pair)
    }

    // MARK: Amount

    /// "3960000.00" | "3 960 000,00" | "1,320,000.00" | "42000" to 1/100 units. Nil when unreadable.
    static func minorUnits(_ raw: String) -> Int64? {
        var text = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        let negative = text.hasPrefix("-")

        if negative {
            text.removeFirst()
        }

        let lastDot = text.lastIndex(of: ".")
        let lastComma = text.lastIndex(of: ",")
        var decimal: Character?

        if let dot = lastDot, let comma = lastComma {
            // With both present the later one is the decimal separator.
            decimal = dot > comma ? "." : ","
        } else if let index = lastDot ?? lastComma {
            let separator = text[index]
            let tail = text.distance(from: index, to: text.endIndex) - 1
            let count = text.filter { $0 == separator }.count

            // "3,960,000" and "1.320" are thousands, "14000.5" and "14000.50" are decimals.
            if count == 1, tail == 1 || tail == 2 {
                decimal = separator
            }
        }

        var integerPart = text
        var fraction = ""

        if let separator = decimal, let index = text.lastIndex(of: separator) {
            integerPart = String(text[..<index])
            fraction = String(text[text.index(after: index)...])
        }

        integerPart.removeAll { $0 == "." || $0 == "," }

        guard let whole = Int64(integerPart), let cents = Int64(String((fraction + "00").prefix(2))) else {
            return nil
        }

        // A long digit run (an account number) must not trap on overflow.
        let scaled = whole.multipliedReportingOverflow(by: 100)

        if scaled.overflow {
            return nil
        }

        let total = scaled.partialValue.addingReportingOverflow(cents)

        if total.overflow {
            return nil
        }

        return negative ? -total.partialValue : total.partialValue
    }

    private static func normalizedCurrency(_ raw: String) -> String {
        let folded = SMSText.fold(raw)

        if ["sum", "som", "сум"].contains(folded) {
            return "UZS"
        }

        return raw.uppercased()
    }

    // MARK: Date

    private static func ints(_ text: String) -> [Int] {
        text.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
    }

    /// The bank prints local Uzbek time, the phone may be abroad: components are built in Asia/Tashkent.
    static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
        guard (1 ... 12).contains(month), (1 ... 31).contains(day), (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = bankTimeZone

        let fullYear = year < 100 ? 2000 + year : year
        let components = DateComponents(year: fullYear, month: month, day: day, hour: hour, minute: minute)

        // The day check rejects 31.02, which Calendar would roll over to March.
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else {
            return nil
        }

        return date
    }

    /// A date is accepted when it is at most 10 minutes ahead of `now` and at most 3 years old.
    /// Otherwise the swapped reading is tried. Nil means "use the receive time".
    private static func plausible(_ primary: Date?, swapped: Date?, now: Date) -> Date? {
        let latest = now.addingTimeInterval(10 * 60)
        let earliest = now.addingTimeInterval(-3 * 365 * 86400)

        if let date = primary, date <= latest, date > earliest {
            return date
        }

        if let date = swapped, date <= latest, date > earliest {
            return date
        }

        return nil
    }

    private static func effectiveDate(_ parsedDate: Date?, receivedAt: Date) -> Date {
        guard let date = parsedDate else {
            return receivedAt
        }

        // The bank clock can run a minute ahead of the phone. A future date would put a fresh
        // payment under Upcoming, so it is pulled back to the receive time.
        return date > receivedAt ? receivedAt : date
    }

    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = bankTimeZone

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        return String(
            format: "%04d%02d%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    // MARK: Fingerprint

    /// Built from parsed fields only, never from the receive time, so the same SMS pasted twice
    /// gives the same value. The balance makes two equal rides in one minute different.
    private static func fingerprint(
        card: String?, direction: SMSDirection?, amountMinor: Int64?, parsedDate: Date?, balanceMinor: Int64?, text: String
    ) -> String {
        if let card = card, let amountMinor = amountMinor, let date = parsedDate, let balanceMinor = balanceMinor {
            var side = "na"

            if let direction = direction {
                side = direction == .income ? "in" : "out"
            }

            return "v1|\(card)|\(side)|\(amountMinor)|\(stamp(date))|\(balanceMinor)"
        }

        return "t1|" + fnv1a(SMSText.fold(text))
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        return String(hash, radix: 16)
    }
}

private extension NSRegularExpression {
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Capture groups of the first match. Index 0 is the whole match, nil for a group that did not take part.
    func groups(in text: String) -> [String?]? {
        let ns = text as NSString

        guard let match = firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }

        var values = [String?]()

        for index in 0 ..< match.numberOfRanges {
            let range = match.range(at: index)
            values.append(range.location == NSNotFound ? nil : ns.substring(with: range))
        }

        return values
    }
}
