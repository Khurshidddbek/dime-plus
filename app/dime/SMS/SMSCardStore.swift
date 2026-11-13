//
//  SMSCardStore.swift
//  dime
//
//  The owner's own cards, by the last 4 digits. Used to tell a transfer between own cards
//  from real spending. Stored in <app group>/Sms/cards.json. Main thread only.
//

import Combine
import Foundation

struct SMSCard: Codable, Identifiable, Equatable {
    var last4: String
    var network: String // "Humo", "Uzcard" or ""
    var nickname: String
    var isOwn: Bool
    var lastBalanceMinor: Int64?
    var lastBalanceCurrency: String?
    var lastSeenAt: Date?

    var id: String {
        last4
    }

    /// "Humo *4417", or the nickname when the owner gave one.
    var displayName: String {
        if !nickname.isEmpty {
            return nickname
        }

        return network.isEmpty ? "*\(last4)" : "\(network) *\(last4)"
    }
}

final class SMSCardStore: ObservableObject {
    static let shared = SMSCardStore()

    @Published private(set) var cards: [SMSCard] = []
    private(set) var isUsable = false

    private let file: SMSJSONFile<SMSCard>

    init(file: SMSJSONFile<SMSCard> = SMSJSONFile<SMSCard>(name: "cards.json")) {
        self.file = file
        reload()
    }

    func reload() {
        let loaded = file.load()

        isUsable = loaded.state == .loaded
        cards = loaded.items
    }

    func reloadIfNeeded() {
        if !isUsable {
            reload()
        }
    }

    // MARK: Lookup

    func card(_ last4: String?) -> SMSCard? {
        guard let last4 = last4 else {
            return nil
        }

        return cards.first { $0.last4 == last4 }
    }

    func isOwn(_ last4: String?) -> Bool {
        card(last4)?.isOwn ?? false
    }

    func displayName(for last4: String?) -> String {
        guard let last4 = last4 else {
            return ""
        }

        return card(last4)?.displayName ?? "*\(last4)"
    }

    // MARK: Changes

    /// Learns the cards seen in bank messages and keeps the newest balance of each.
    func note(_ messages: [ParsedSMS]) {
        var changed = false

        for sms in messages {
            guard let last4 = sms.cardLast4 else {
                continue
            }

            let network = Self.network(for: sms.format)

            if let index = cards.firstIndex(where: { $0.last4 == last4 }) {
                var card = cards[index]

                if card.network.isEmpty, !network.isEmpty {
                    card.network = network
                }

                if let balance = sms.balanceMinor, sms.dateFromText, card.lastSeenAt.map({ $0 <= sms.date }) ?? true {
                    card.lastBalanceMinor = balance
                    card.lastBalanceCurrency = sms.currency
                    card.lastSeenAt = sms.date
                }

                if card != cards[index] {
                    cards[index] = card
                    changed = true
                }
            } else {
                // A Humo or Uzcard message, or any message with the card balance, comes only to the
                // card holder. A bare card mask in another format may be someone else's card.
                let own = sms.format != "generic" || sms.balanceMinor != nil

                cards.append(
                    SMSCard(
                        last4: last4, network: network, nickname: "", isOwn: own,
                        lastBalanceMinor: sms.balanceMinor, lastBalanceCurrency: sms.currency,
                        lastSeenAt: sms.dateFromText ? sms.date : nil
                    )
                )
                changed = true
            }
        }

        if changed {
            persist()
        }
    }

    /// Adds a card by hand. Returns false when the text is not 4 digits or the card is already there.
    @discardableResult
    func add(last4: String, nickname: String = "") -> Bool {
        let digits = last4.trimmingCharacters(in: .whitespaces)

        guard digits.count == 4, digits.allSatisfy({ $0.isNumber }), card(digits) == nil else {
            return false
        }

        cards.append(
            SMSCard(
                last4: digits, network: "", nickname: nickname, isOwn: true,
                lastBalanceMinor: nil, lastBalanceCurrency: nil, lastSeenAt: nil
            )
        )
        persist()

        return true
    }

    func setOwn(_ last4: String, _ value: Bool) {
        guard let index = cards.firstIndex(where: { $0.last4 == last4 }) else {
            return
        }

        cards[index].isOwn = value
        persist()
    }

    func rename(_ last4: String, to nickname: String) {
        guard let index = cards.firstIndex(where: { $0.last4 == last4 }) else {
            return
        }

        cards[index].nickname = nickname.trimmingCharacters(in: .whitespaces)
        persist()
    }

    func delete(_ last4: String) {
        cards.removeAll { $0.last4 == last4 }
        persist()
    }

    private static func network(for format: String) -> String {
        switch format {
        case "humo": return "Humo"
        case "uzcard": return "Uzcard"
        default: return ""
        }
    }

    private func persist() {
        guard isUsable else {
            return
        }

        file.save(cards)
    }
}
