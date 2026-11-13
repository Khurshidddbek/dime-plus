//
//  SMSParserSelfCheck.swift
//  dime
//
//  There is no test target, so the expected parse of the owner's real messages lives here:
//  9 samples checked field by field, all 36 real messages checked for kind, amount, direction
//  and card, the pairing of own card transfers and the category guess from history.
//  Debug builds only. Call SMSParserSelfCheck.run() from a debugger or the debug button in the
//  SMS settings: an empty result means the parser still reads every sample the way it should.
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

        /// One real message from the owner's phone with what it must give.
        struct Real {
            let text: String
            let kind: SMSKind
            var direction: SMSDirection?
            var amountMinor: Int64?
            var card: String?
            var stamp: String? // yyyyMMddHHmm in Asia/Tashkent
            var twoNetworks = false
            var reason: SMSSkipReason?
        }

        private static func op(
            _ text: String, _ kind: SMSKind, _ direction: SMSDirection, _ amountMinor: Int64, _ card: String, _ stamp: String,
            twoNetworks: Bool = false
        ) -> Real {
            Real(text: text, kind: kind, direction: direction, amountMinor: amountMinor, card: card, stamp: stamp, twoNetworks: twoNetworks)
        }

        private static func skip(_ text: String, _ reason: SMSSkipReason) -> Real {
            Real(text: text, kind: .ignored, reason: reason)
        }

        // The 36 messages of real_sms_36.txt in its order: Humo *4417 (HUMOCARD), Uzcard *8821 (CARDINFO),
        // then the ones that are not operations.
        static let real: [Real] = [
            op("HUMOCARD *4417: oplata 48000.00 UZS; YandexGO Taxi UB OPL; 25-03-12 17:04;  Dostupno: 44159635.83 UZS",
               .payment, .expense, 4_800_000, "4417", "202503121704"),
            op("HUMOCARD *4417: popolnenie 29999999.97 UZS; ORIENT POPOLN NA K; 25-03-12 19:14;  Dostupno: 74159635.80 UZS",
               .topUp, .income, 2_999_999_997, "4417", "202503121914"),
            op("HUMOCARD *4417: popolnenie 30000000.00 UZS; ORIENT POPOLN NA K; 25-03-12 19:17;  Dostupno: 104159635.80 UZS",
               .topUp, .income, 3_000_000_000, "4417", "202503121917"),
            op("HUMOCARD *4417: popolnenie 30000000.03 UZS; ORIENT POPOLN NA K; 25-03-12 19:18;  Dostupno: 134159635.83 UZS",
               .topUp, .income, 3_000_000_003, "4417", "202503121918"),
            op("HUMOCARD *4417: popolnenie 20398950.27 UZS; ORIENT POPOLN NA K; 25-03-12 19:19;  Dostupno: 154558586.10 UZS",
               .topUp, .income, 2_039_895_027, "4417", "202503121919"),
            op("HUMOCARD *4417: oplata 45843750.00 UZS; OPLATA MCHJ TEXNOMART; 25-03-12 19:21;  Dostupno: 108714836.10 UZS",
               .payment, .expense, 4_584_375_000, "4417", "202503121921"),
            op("HUMOCARD *4417: oplata 514860.00 UZS; alifnasiyauz rassroc; 25-03-12 19:22;  Dostupno: 108199976.10 UZS",
               .payment, .expense, 51_486_000, "4417", "202503121922"),
            op("HUMOCARD *4417: oplata 690090.00 UZS; alifnasiyauz rassroc; 25-03-12 19:22;  Dostupno: 107509886.10 UZS",
               .payment, .expense, 69_009_000, "4417", "202503121922"),
            op("HUMOCARD *4417: oplata 300000.00 UZS; HGT PAYNET>Toshkent; 25-03-13 03:25;  Dostupno: 103813073.40 UZS",
               .payment, .expense, 30_000_000, "4417", "202503130325"),
            op("HUMOCARD *4417: oplata 495000.00 UZS; HGT PAYNET>Toshkent; 25-03-13 03:25;  Dostupno: 104158073.40 UZS",
               .payment, .expense, 49_500_000, "4417", "202503130325"),
            op("HUMOCARD *4417: oplata 45000.00 UZS; HGT PAYNET>Toshkent; 25-03-13 03:25;  Dostupno: 104113073.40 UZS",
               .payment, .expense, 4_500_000, "4417", "202503130325"),
            op("HUMOCARD *4417: oplata 7682295.00 UZS; Humo to Visa>Tashken; 25-03-13 03:28;  Dostupno: 96130778.40 UZS",
               .transfer, .expense, 768_229_500, "4417", "202503130328", twoNetworks: true),
            op("HUMOCARD *4417: oplata 322044.00 UZS; TBC P2P S HUMO NA UZ; 25-03-13 03:36;  Dostupno: 95808734.40 UZS",
               .transfer, .expense, 32_204_400, "4417", "202503130336", twoNetworks: true),
            op("HUMOCARD *4417: oplata 43500.00 UZS; YandexGO Taxi UB OPL; 25-03-13 11:59;  Dostupno: 95765234.40 UZS",
               .payment, .expense, 4_350_000, "4417", "202503131159"),
            op("HUMOCARD *4417: oplata 48000.00 UZS; YandexGO Taxi UB OPL; 25-03-13 13:07;  Dostupno: 95717234.40 UZS",
               .payment, .expense, 4_800_000, "4417", "202503131307"),
            op("HUMOCARD *4417: oplata 3960000.00 UZS; Humo to Visa>Tashken; 25-03-10 16:09;  Dostupno: 48825285.78 UZS",
               .transfer, .expense, 396_000_000, "4417", "202503101609", twoNetworks: true),
            op("HUMOCARD *4417: oplata 844051.95 UZS; UB P2P Humo2Uzcard>T; 25-03-11 03:39;  Dostupno: 47981233.83 UZS",
               .transfer, .expense, 84_405_195, "4417", "202503110339", twoNetworks: true),
            op("HUMOCARD *4417: oplata 1046448.00 UZS; TBC P2P S HUMO NA UZ; 25-03-12 03:27;  Dostupno: 46934785.83 UZS",
               .transfer, .expense, 104_644_800, "4417", "202503120327", twoNetworks: true),
            op("HUMOCARD *4417: oplata 1200000.00 UZS; TBC P2P S HUMO NA UZ; 25-03-12 11:49;  Dostupno: 45734785.83 UZS",
               .transfer, .expense, 120_000_000, "4417", "202503121149", twoNetworks: true),
            op("HUMOCARD *4417: popolnenie 14850.00 UZS; TBC CASHBACK>TASHKEN; 25-03-12 14:41;  Dostupno: 45749635.83 UZS",
               .topUp, .income, 1_485_000, "4417", "202503121441"),
            op("HUMOCARD *4417: oplata 42000.00 UZS; YandexGO Taxi UB OPL; 25-03-12 16:06;  Dostupno: 45707635.83 UZS",
               .payment, .expense, 4_200_000, "4417", "202503121606"),
            op("To'lov: UZCARD TO VISA, UZ,09.03.25 22:30,karta ***8821. Miqdor:300000.00 UZS Qoldiq:15649548.48 UZS",
               .transfer, .expense, 30_000_000, "8821", "202503092230", twoNetworks: true),
            op("Bankomatda naqd pul yechish: AT ASAKA BANK TOSHKENT SHAHAR FILIALI, UZ,10.03.25 10:20,karta ***8821. Miqdor:5454000.00 UZS Qoldiq:10195548.48 UZS",
               .atmWithdrawal, .expense, 545_400_000, "8821", "202503101020"),
            op("Kartaga o'tkazma: CLICK P2P H2UEW, UZ,10.03.25 20:40,karta ***8821. Miqdor:1059000.00 UZS Qoldiq:11254548.48 UZS",
               .transfer, .income, 105_900_000, "8821", "202503102040"),
            op("To'lov: ALIFNASIYA.UZ, UZ,11.03.25 03:31,karta ***8821. Miqdor:835696.80 UZS Qoldiq:10418851.68 UZS",
               .payment, .expense, 83_569_680, "8821", "202503110331"),
            op("Kartaga o'tkazma: UB P2P HUMO2UZCARD, UZ,11.03.25 03:39,karta ***8821. Miqdor:835695.00 UZS Qoldiq:11254546.68 UZS",
               .transfer, .income, 83_569_500, "8821", "202503110339", twoNetworks: true),
            op("Kartaga o'tkazma: BEEPUL P2P, UZ,11.03.25 15:28,karta ***8821. Miqdor:5700000.00 UZS Qoldiq:16954546.68 UZS",
               .transfer, .income, 570_000_000, "8821", "202503111528"),
            op("To'lov: ALIFNASIYA.UZ, UZ,12.03.25 03:14,karta ***8821. Miqdor:1046448.72 UZS Qoldiq:15908097.96 UZS",
               .payment, .expense, 104_644_872, "8821", "202503120314"),
            op("Kartaga o'tkazma: TBC EDIN EPOS H2U, UZ,12.03.25 03:27,karta ***8821. Miqdor:1046448.00 UZS Qoldiq:16954545.96 UZS",
               .transfer, .income, 104_644_800, "8821", "202503120327"),
            op("To'lov: UZCARD TO VISA, UZ,13.03.25 03:33,karta ***8821. Miqdor:322044.00 UZS Qoldiq:16632501.96 UZS",
               .transfer, .expense, 32_204_400, "8821", "202503130333", twoNetworks: true),
            op("Kartaga o'tkazma: TBC EDIN EPOS H2U, UZ,13.03.25 03:36,karta ***8821. Miqdor:322044.00 UZS Qoldiq:16954545.96 UZS",
               .transfer, .income, 32_204_400, "8821", "202503130336"),
            skip("Nedostatochno sredstv, Google GOOGLE*ONE 14M 11.03.25 06:50, karta 418000******1234. summa: 71 640.00 UZS, balans: 0.04 USD",
                 .declined),
            skip("Nedostatochno sredstv, Google GOOGLE*ONE 14M 12.03.25 06:50, karta 418000******1234. summa: 71 640.00 UZS, balans: 0.04 USD",
                 .declined),
            skip("Usluga SMS-servis otklyuchena dlya karti Virtual VE *12", .info),
            skip("Shartnoma #10000001 muvafaqqiyatli tasdiqlandi! Shartnoma summasi: 13608000.00 so'm. Muddat: 12 oy. Oylik to'lov: 1134000.00 so'm. Tel: 78 7771515",
                 .info),
            skip("Oktabr oyi uchun tabiiy gaz iste'molingiz 95 m3 tashkil etdi. Ijtimoiy normadan ortiq iste'molingiz 7 m3. Hisob raqamingiz 3000000003.",
                 .info),
        ]

        /// Own card moves in `real`, as (outgoing index, incoming index, fee in 1/100).
        static let realPairs: [(outgoing: Int, incoming: Int, feeMinor: Int64)] = [
            (outgoing: 16, incoming: 25, feeMinor: 835_695), // UB P2P Humo2Uzcard 844051.95 and 835695.00
            (outgoing: 17, incoming: 28, feeMinor: 0), // TBC P2P S HUMO NA UZ and TBC EDIN EPOS H2U, 1046448
            (outgoing: 12, incoming: 30, feeMinor: 0), // the same pair on 13.03, 322044
        ]

        /// Returns one line per mismatch. Empty means everything is as expected.
        static func run() -> [String] {
            var failures = [String]()

            // After the newest sample (13.03 13:07), so every date is plausible and nothing is clamped.
            let now = SMSParser.makeDate(year: 2025, month: 3, day: 14, hour: 0, minute: 0) ?? Date()

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

            // Declined moves no money, card mask or not.
            let declined = SMSParser.parse(
                "Operatsiya otklonena: nedostatochno sredstv. Karta *4417, 50000.00 UZS", receivedAt: now
            )
            expect("declined with a card: kind", declined.kind == .ignored)
            expect("declined with a card: reason", declined.skipReason == .declined)

            let uzbekDeclined = SMSParser.parse(
                "To'lov rad etildi: mablag' yetarli emas. Karta *8821, 50000.00 UZS", receivedAt: now
            )
            expect("rad etildi: kind", uzbekDeclined.kind == .ignored)

            let englishDeclined = SMSParser.parse("Card *1234: purchase declined, insufficient funds. 12.50 USD", receivedAt: now)
            expect("declined in English: kind", englishDeclined.kind == .ignored)

            // An amount without a card mask and without an operation word is not an expense.
            let bare = SMSParser.parse("Vash limit 5000000.00 UZS", receivedAt: now)
            expect("bare amount: no direction", bare.direction == nil)
            expect("bare amount: no amount", bare.amountMinor == nil)

            // "KODAK" is a merchant, not a one-time code.
            let kodak = SMSParser.parse("Pokupka KODAK SHOP, karta *1234, 150000.00 UZS, 13.03.2025 10:00", receivedAt: now)
            expect("kodak: kind", kodak.kind == .payment)

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

            failures += checkReal(now: now)
            failures += checkHistory(now: now)

            return failures
        }

        /// The 36 real messages and the pairing of own card transfers among them.
        private static func checkReal(now: Date) -> [String] {
            var failures = [String]()
            var parsedAll = [ParsedSMS]()

            for (index, sample) in real.enumerated() {
                let parsed = SMSParser.parse(sample.text, receivedAt: now)
                parsedAll.append(parsed)

                func check(_ name: String, _ got: String, _ want: String) {
                    if got != want {
                        failures.append("real \(index + 1) \(name): got \(got), want \(want)")
                    }
                }

                check("kind", parsed.kind.rawValue, sample.kind.rawValue)
                check("direction", parsed.direction?.rawValue ?? "nil", sample.direction?.rawValue ?? "nil")
                check("amount", parsed.amountMinor.map { String($0) } ?? "nil", sample.amountMinor.map { String($0) } ?? "nil")
                check("reason", parsed.skipReason?.rawValue ?? "nil", sample.reason?.rawValue ?? "nil")

                if sample.kind != .ignored {
                    check("card", parsed.cardLast4 ?? "nil", sample.card ?? "nil")
                    check("date", SMSParser.stamp(parsed.date), sample.stamp ?? "nil")
                    check("two networks", String(parsed.namesTwoNetworks), String(sample.twoNetworks))
                    check("confidence", String(parsed.confidence), "1.0")
                }
            }

            let blob = real.map { $0.text }.joined(separator: "\n")
            let split = SMSParser.splitMessages(blob).count

            if split != real.count {
                failures.append("real split: got \(split) messages, want \(real.count)")
            }

            // Every leg counts as an own card here: in the app both cards are learned from these messages.
            var legs = [SMSTransferLeg]()
            var owners = [Int]()

            for (index, parsed) in parsedAll.enumerated() {
                if let leg = SMSTransferLeg(parsed) {
                    legs.append(leg)
                    owners.append(index)
                }
            }

            let found = SMSTransferPairing.pairs(legs, fresh: Set(legs.indices)).map { pair -> String in
                let outgoing = legs[pair.outgoing]
                let incoming = legs[pair.incoming]

                return "\(owners[pair.outgoing])>\(owners[pair.incoming]) fee \(outgoing.amountMinor - incoming.amountMinor)"
            }

            let want = realPairs.map { "\($0.outgoing)>\($0.incoming) fee \($0.feeMinor)" }

            if Set(found) != Set(want) || found.count != want.count {
                failures.append("real pairs: got \(found.sorted()), want \(want.sorted())")
            }

            return failures
        }

        /// Category guess from notes typed before.
        private static func checkHistory(now: Date) -> [String] {
            var failures = [String]()

            func expect(_ name: String, _ condition: Bool) {
                if !condition {
                    failures.append("history failed: \(name)")
                }
            }

            let taxi = UUID()
            let debt = UUID()
            let cashback = UUID()
            let phone = UUID()
            let categories = [
                SMSCategoryInfo(id: taxi, name: "Taxi", emoji: "", colour: "#000000", income: false),
                SMSCategoryInfo(id: debt, name: "Qarz (Qaytardim)", emoji: "", colour: "#000000", income: false),
                SMSCategoryInfo(id: phone, name: "Telefon", emoji: "", colour: "#000000", income: false),
                SMSCategoryInfo(id: cashback, name: "Keshbek", emoji: "", colour: "#000000", income: true),
            ]

            var index = SMSHistoryIndex()

            for _ in 0 ..< 3 {
                index.add(note: "Taxi", income: false, categoryID: taxi)
            }

            index.add(note: "Alif Nasiya", income: false, categoryID: debt)
            index.add(note: "Alif Nasiya", income: false, categoryID: debt)
            index.add(note: "TBC cashback", income: true, categoryID: cashback)
            index.add(note: "TBC cashback", income: true, categoryID: cashback)
            index.add(note: "Paynet", income: false, categoryID: phone)

            func guess(_ number: Int) -> UUID? {
                index.category(for: SMSParser.parse(real[number - 1].text, receivedAt: now), categories: categories)
            }

            expect("YandexGO Taxi finds the Taxi notes", guess(1) == taxi)
            expect("alifnasiyauz rassroc finds Alif Nasiya", guess(7) == debt)
            expect("ALIFNASIYA.UZ finds Alif Nasiya", guess(25) == debt)
            expect("TBC Cashback finds the cashback notes", guess(20) == cashback)
            expect("TBC H2U finds nothing by the bank name alone", guess(29) == nil)
            expect("one use of Paynet is not enough", guess(9) == nil)

            // No notes at all: the category name is enough.
            let empty = SMSHistoryIndex()
            let ride = SMSParser.parse(real[0].text, receivedAt: now)
            expect("YandexGO Taxi finds the Taxi category", empty.category(for: ride, categories: categories) == taxi)

            return failures
        }
    }
#endif
