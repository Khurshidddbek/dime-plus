//
//  SMSParserSelfCheck.swift
//  dime
//
//  There is no test target, so the expected parse of the owner's 9 real messages lives here.
//  Debug builds only. Call SMSParserSelfCheck.run() from a debugger or a debug button:
//  an empty result means the parser still reads every sample the way it should.
//

#if DEBUG
    import Foundation

    enum SMSParserSelfCheck {
        struct Expectation {
            let text: String
            let format: String
            let kind: SMSKind
            let direction: SMSDirection?
            let amountMinor: Int64
            let merchantKey: String
            let merchantDisplay: String
            let city: String?
            let stamp: String // yyyyMMddHHmm in Asia/Tashkent
            let card: String
            let balanceMinor: Int64
            let namesTwoNetworks: Bool
        }

        static let samples: [Expectation] = [
            Expectation(
                text: "HUMOCARD *4417: oplata 3960000.00 UZS; Humo to Visa>Tashken; 25-03-10 16:09;  Dostupno: 48825285.78 UZS",
                format: "humo", kind: .transfer, direction: .expense, amountMinor: 396_000_000,
                merchantKey: "humo to visa", merchantDisplay: "Humo to Visa", city: "Tashken",
                stamp: "202503101609", card: "4417", balanceMinor: 4_882_528_578, namesTwoNetworks: true
            ),
            Expectation(
                text: "HUMOCARD *4417: popolnenie 14850.00 UZS; TBC CASHBACK>TASHKEN; 25-03-12 14:41;  Dostupno: 45749635.83 UZS",
                format: "humo", kind: .topUp, direction: .income, amountMinor: 1_485_000,
                merchantKey: "tbc cashback", merchantDisplay: "TBC Cashback", city: "TASHKEN",
                stamp: "202503121441", card: "4417", balanceMinor: 4_574_963_583, namesTwoNetworks: false
            ),
            Expectation(
                text: "HUMOCARD *4417: oplata 42000.00 UZS; YandexGO Taxi UB OPL; 25-03-12 16:06;  Dostupno: 45707635.83 UZS",
                format: "humo", kind: .payment, direction: .expense, amountMinor: 4_200_000,
                merchantKey: "yandexgo taxi", merchantDisplay: "YandexGO Taxi", city: nil,
                stamp: "202503121606", card: "4417", balanceMinor: 4_570_763_583, namesTwoNetworks: false
            ),
            Expectation(
                text: "HUMOCARD *4417: popolnenie 29999999.97 UZS; ORIENT POPOLN NA K; 25-03-12 19:14;  Dostupno: 74159635.80 UZS",
                format: "humo", kind: .topUp, direction: .income, amountMinor: 2_999_999_997,
                merchantKey: "orient", merchantDisplay: "Orient", city: nil,
                stamp: "202503121914", card: "4417", balanceMinor: 7_415_963_580, namesTwoNetworks: false
            ),
            Expectation(
                text: "HUMOCARD *4417: oplata 690090.00 UZS; alifnasiyauz rassroc; 25-03-12 19:22;  Dostupno: 107509886.10 UZS",
                format: "humo", kind: .payment, direction: .expense, amountMinor: 69_009_000,
                merchantKey: "alifnasiya", merchantDisplay: "Alifnasiya", city: nil,
                stamp: "202503121922", card: "4417", balanceMinor: 10_750_988_610, namesTwoNetworks: false
            ),
            // H2U is only a marker: it can be the owner's Humo card or another person, so it is
            // a transfer that is NOT flagged as "between own cards".
            Expectation(
                text: "Kartaga o'tkazma: TBC EDIN EPOS H2U, UZ,12.03.25 03:27,karta ***8821. Miqdor:1046448.00 UZS Qoldiq:16954545.96 UZS",
                format: "uzcard", kind: .transfer, direction: .income, amountMinor: 104_644_800,
                merchantKey: "tbc h2u", merchantDisplay: "TBC H2U", city: nil,
                stamp: "202503120327", card: "8821", balanceMinor: 1_695_454_596, namesTwoNetworks: false
            ),
            Expectation(
                text: "Bankomatda naqd pul yechish: AT ASAKA BANK TOSHKENT SHAHAR FILIALI, UZ,10.03.25 10:20,karta ***8821. Miqdor:5454000.00 UZS Qoldiq:10195548.48 UZS",
                format: "uzcard", kind: .atmWithdrawal, direction: .expense, amountMinor: 545_400_000,
                merchantKey: "asaka bank", merchantDisplay: "Asaka Bank", city: nil,
                stamp: "202503101020", card: "8821", balanceMinor: 1_019_554_848, namesTwoNetworks: false
            ),
            // The real message has the typographic apostrophe U+2018.
            Expectation(
                text: "To\u{2018}lov: ALIFNASIYA.UZ, UZ,11.03.25 03:31,karta ***8821. Miqdor:835696.80 UZS Qoldiq:10418851.68 UZS",
                format: "uzcard", kind: .payment, direction: .expense, amountMinor: 83_569_680,
                merchantKey: "alifnasiya", merchantDisplay: "Alifnasiya", city: nil,
                stamp: "202503110331", card: "8821", balanceMinor: 1_041_885_168, namesTwoNetworks: false
            ),
            Expectation(
                text: "To'lov: UZCARD TO VISA, UZ,09.03.25 22:30,karta ***8821. Miqdor:300000.00 UZS Qoldiq:15649548.48 UZS",
                format: "uzcard", kind: .transfer, direction: .expense, amountMinor: 30_000_000,
                merchantKey: "uzcard to visa", merchantDisplay: "Uzcard to Visa", city: nil,
                stamp: "202503092230", card: "8821", balanceMinor: 1_564_954_848, namesTwoNetworks: true
            ),
        ]

        /// Returns one line per mismatch. Empty means everything is as expected.
        static func run() -> [String] {
            var failures = [String]()

            // The day after the newest sample, so every date is plausible and nothing is clamped.
            let now = SMSParser.makeDate(year: 2025, month: 3, day: 13, hour: 12, minute: 0) ?? Date()

            for (index, sample) in samples.enumerated() {
                let number = index + 1
                let parsed = SMSParser.parse(sample.text, receivedAt: now)

                func check(_ name: String, _ got: String, _ want: String) {
                    if got != want {
                        failures.append("sample \(number) \(name): got \(got), want \(want)")
                    }
                }

                check("format", parsed.format, sample.format)
                check("kind", parsed.kind.rawValue, sample.kind.rawValue)
                check("direction", parsed.direction?.rawValue ?? "nil", sample.direction?.rawValue ?? "nil")
                check("amount", String(parsed.amountMinor ?? -1), String(sample.amountMinor))
                check("currency", parsed.currency ?? "nil", "UZS")
                check("key", parsed.merchantKey, sample.merchantKey)
                check("display", parsed.merchantDisplay, sample.merchantDisplay)
                check("city", parsed.city ?? "nil", sample.city ?? "nil")
                check("date", SMSParser.stamp(parsed.date), sample.stamp)
                check("card", parsed.cardLast4 ?? "nil", sample.card)
                check("balance", String(parsed.balanceMinor ?? -1), String(sample.balanceMinor))
                check("pair", String(parsed.namesTwoNetworks), String(sample.namesTwoNetworks))
                check("confidence", String(parsed.confidence), "1.0")

                let side = sample.direction == .income ? "in" : "out"
                check(
                    "fingerprint", parsed.fingerprint,
                    "v1|\(sample.card)|\(side)|\(sample.amountMinor)|\(sample.stamp)|\(sample.balanceMinor)"
                )
            }

            func expect(_ name: String, _ condition: Bool) {
                if !condition {
                    failures.append("variant failed: \(name)")
                }
            }

            let spaced = SMSParser.parse(
                "humocard*4417:Oplata 3 960 000,00 uzs;Korzinka>Tashkent;25-03-10 16:09;Dostupno:48 825 285,78 UZS",
                receivedAt: now
            )
            expect("humo with spaces: format", spaced.format == "humo")
            expect("humo with spaces: kind", spaced.kind == .payment)
            expect("humo with spaces: amount", spaced.amountMinor == 396_000_000)
            expect("humo with spaces: key", spaced.merchantKey == "korzinka")
            expect("humo with spaces: balance", spaced.balanceMinor == 4_882_528_578)

            // "otkaz" must not be read as declined inside "o'tkazma".
            let incoming = SMSParser.parse(
                "KARTAGA O\u{02BB}TKAZMA:TBC EDIN EPOS H2U,UZ,12.03.25 03:27,Karta *8821.Miqdor: 1 046 448.00 UZS  Qoldiq: 16 954 545.96 UZS",
                receivedAt: now
            )
            expect("otkazma: format", incoming.format == "uzcard")
            expect("otkazma: kind", incoming.kind == .transfer)
            expect("otkazma: direction", incoming.direction == .income)
            expect("otkazma: amount", incoming.amountMinor == 104_644_800)

            let code = SMSParser.parse("Kod: 482913. Summa 50000.00 UZS. Nikomu ne soobshayte", receivedAt: now)
            expect("one-time code is ignored", code.kind == .ignored)

            // Declined, but with a card mask: it stays visible as unrecognised instead of vanishing.
            let declined = SMSParser.parse(
                "Operatsiya otklonena: nedostatochno sredstv. Karta *4417, 50000.00 UZS", receivedAt: now
            )
            expect("declined with a card: kind", declined.kind == .unknown)
            expect("declined with a card: direction", declined.direction == nil)

            let foreign = SMSParser.parse(
                "Pokupka 45.99 USD, karta *1234, AMAZON, ostatok 120.50 USD 13.03.2025 09:15", receivedAt: now
            )
            expect("generic USD: format", foreign.format == "generic")
            expect("generic USD: kind", foreign.kind == .payment)
            expect("generic USD: amount", foreign.amountMinor == 4599)
            expect("generic USD: currency", foreign.currency == "USD")
            expect("generic USD: key", foreign.merchantKey == "amazon")
            expect("generic USD: card", foreign.cardLast4 == "1234")
            expect("generic USD: balance", foreign.balanceMinor == 12050)
            expect("generic USD: confidence", foreign.confidence == 0.5)

            let som = SMSParser.parse("Sizning kartangizga 250000 so'm tushdi", receivedAt: now)
            expect("generic so'm: amount", som.amountMinor == 25_000_000)
            expect("generic so'm: currency", som.currency == "UZS")
            expect("generic so'm: direction", som.direction == .income)

            let amounts: [(String, Int64)] = [
                ("42000", 4_200_000), ("14000.5", 1_400_050), ("3,960,000", 396_000_000),
                ("1.320.000,50", 132_000_050), ("-5.00", -500),
            ]

            for (text, want) in amounts where SMSParser.minorUnits(text) != want {
                failures.append("amount \(text): got \(String(describing: SMSParser.minorUnits(text))), want \(want)")
            }

            let blob = samples.map { $0.text }.joined(separator: "\n")

            if SMSParser.splitMessages(blob).count != samples.count {
                failures.append("split: got \(SMSParser.splitMessages(blob).count) messages, want \(samples.count)")
            }

            return failures
        }
    }
#endif
