//
//  SMSRuleStore.swift
//  dime
//
//  Learned "merchant goes to category" rules. Stored in <app group>/Sms/rules.json.
//  Main thread only.
//

import Combine
import Foundation

struct MerchantRule: Codable, Identifiable, Equatable {
    enum Action: String, Codable {
        case categorize
        case skip // messages of this merchant never reach the inbox
    }

    var id: UUID
    var key: String // "yandexgo taxi", editable
    var isIncome: Bool // a rule is per direction, like a category
    var action: Action
    var categoryID: UUID? // Category.id, the same on every device
    var categoryName: String? // shown when the category was deleted
    var note: String // "YandexGO Taxi", becomes the transaction note
    var autoAdd: Bool // add without review
    var cardLast4: String? // nil = any card
    var hits: Int // confirmed with this category
    var overrides: Int // confirmed with another category
    var createdAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(), key: String, isIncome: Bool, action: Action = .categorize, categoryID: UUID? = nil,
        categoryName: String? = nil, note: String = "", autoAdd: Bool = false, cardLast4: String? = nil,
        hits: Int = 0, overrides: Int = 0, createdAt: Date = Date(), lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.key = key
        self.isIncome = isIncome
        self.action = action
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.note = note
        self.autoAdd = autoAdd
        self.cardLast4 = cardLast4
        self.hits = hits
        self.overrides = overrides
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, key, isIncome, action, categoryID, categoryName, note, autoAdd, cardLast4, hits, overrides, createdAt, lastUsedAt
    }

    // Only the key is required, so a file written by an older build still loads after a field is added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decode(String.self, forKey: .key)
        isIncome = try container.decodeIfPresent(Bool.self, forKey: .isIncome) ?? false
        action = try container.decodeIfPresent(Action.self, forKey: .action) ?? .categorize
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        autoAdd = try container.decodeIfPresent(Bool.self, forKey: .autoAdd) ?? false
        cardLast4 = try container.decodeIfPresent(String.self, forKey: .cardLast4)
        hits = try container.decodeIfPresent(Int.self, forKey: .hits) ?? 0
        overrides = try container.decodeIfPresent(Int.self, forKey: .overrides) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? Date()
    }
}

struct SMSRuleMatch {
    let rule: MerchantRule
    let score: Double

    /// Exact key or a cut-off token: sure enough to add without asking.
    var isStrong: Bool {
        score >= 0.9
    }
}

enum MerchantMatcher {
    static func normalizedKey(_ text: String) -> String {
        MerchantNormalizer.tokens(text).joined(separator: " ")
    }

    static func best(for sms: ParsedSMS, in rules: [MerchantRule]) -> SMSRuleMatch? {
        guard !sms.merchantKey.isEmpty else {
            return nil
        }

        let isIncome = sms.direction == .income
        let tokens = sms.merchantKey.split(separator: " ").map { String($0) }
        let squashed = tokens.joined()
        var best: SMSRuleMatch?

        for rule in rules {
            if rule.isIncome != isIncome || rule.key.isEmpty {
                continue
            }

            if let card = rule.cardLast4, card != sms.cardLast4 {
                continue
            }

            let value = score(ruleKey: rule.key, tokens: tokens, squashed: squashed)

            if value <= 0 {
                continue
            }

            let candidate = SMSRuleMatch(rule: rule, score: value)

            if let current = best {
                if isBetter(candidate, than: current) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }

    private static func isBetter(_ a: SMSRuleMatch, than b: SMSRuleMatch) -> Bool {
        if a.score != b.score {
            return a.score > b.score
        }

        // The longer key is the more specific rule.
        if a.rule.key.count != b.rule.key.count {
            return a.rule.key.count > b.rule.key.count
        }

        return a.rule.lastUsedAt > b.rule.lastUsedAt
    }

    /// 1.0 exact key, 0.9 token prefix ("yandexgo" for "yandexgo taxi", "korzinka chilan" for
    /// "korzinka chilanzar"), 0.8 glued ("alifnasiya" for "alifnasiyauz"), 0.6 one typo in the first token.
    static func score(ruleKey: String, tokens: [String], squashed: String) -> Double {
        let ruleTokens = ruleKey.split(separator: " ").map { String($0) }
        let ruleSquashed = ruleTokens.joined()

        if ruleTokens.isEmpty || tokens.isEmpty {
            return 0
        }

        if ruleTokens == tokens {
            return 1.0
        }

        if tokenPrefixSubset(ruleTokens, of: tokens) {
            return 0.9
        }

        if ruleSquashed.count >= 5, squashed.count >= 5 {
            if squashed.hasPrefix(ruleSquashed) || ruleSquashed.hasPrefix(squashed) {
                return 0.8
            }
        }

        if let a = ruleTokens.first, let b = tokens.first, a.count >= 5, b.count >= 5 {
            let allowed = max(a.count, b.count) >= 9 ? 2 : 1

            if levenshtein(a, b) <= allowed {
                return 0.6
            }
        }

        return 0
    }

    /// Every rule token matches some SMS token, in order. "Matches" is equal, or one is a prefix
    /// of the other and the shorter one has 4+ letters ("tashken" for "tashkent").
    static func tokenPrefixSubset(_ rule: [String], of tokens: [String]) -> Bool {
        var index = 0

        for ruleToken in rule {
            var found = false

            while index < tokens.count {
                let token = tokens[index]
                index += 1

                if token == ruleToken {
                    found = true
                    break
                }

                if min(token.count, ruleToken.count) >= 4, token.hasPrefix(ruleToken) || ruleToken.hasPrefix(token) {
                    found = true
                    break
                }
            }

            if !found {
                return false
            }
        }

        return true
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let first = Array(a)
        let second = Array(b)

        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        var previous = Array(0 ... second.count)
        var current = [Int](repeating: 0, count: second.count + 1)

        for i in 1 ... first.count {
            current[0] = i

            for j in 1 ... second.count {
                let cost = first[i - 1] == second[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }

            previous = current
        }

        return previous[second.count]
    }
}

final class SMSRuleStore: ObservableObject {
    static let shared = SMSRuleStore()

    @Published private(set) var rules: [MerchantRule] = []
    private(set) var isUsable = false

    private let file: SMSJSONFile<MerchantRule>

    init(file: SMSJSONFile<MerchantRule> = SMSJSONFile<MerchantRule>(name: "rules.json")) {
        self.file = file
        reload()
    }

    func reload() {
        let loaded = file.load()

        isUsable = loaded.state == .loaded
        rules = loaded.items
    }

    /// A second try for a file that was locked when the process started.
    func reloadIfNeeded() {
        if !isUsable {
            reload()
        }
    }

    // MARK: Lookup

    func bestMatch(for sms: ParsedSMS) -> SMSRuleMatch? {
        MerchantMatcher.best(for: sms, in: rules)
    }

    func rule(withID id: UUID?) -> MerchantRule? {
        guard let id = id else {
            return nil
        }

        return rules.first { $0.id == id }
    }

    func exactRule(key: String, isIncome: Bool) -> MerchantRule? {
        rules.first { $0.key == key && $0.isIncome == isIncome }
    }

    /// How many remembered messages a key would catch (for the rule editor).
    func rules(matching text: String) -> [MerchantRule] {
        let query = SMSText.fold(text)

        if query.isEmpty {
            return rules
        }

        return rules.filter { rule in
            rule.key.contains(query) || SMSText.fold(rule.note).contains(query)
                || SMSText.fold(rule.categoryName ?? "").contains(query)
        }
    }

    // MARK: Learning

    /// Called after the user confirmed a message with a category.
    /// - no rule for this merchant and direction: one is created
    /// - same category: one more hit
    /// - another category: counted as an exception; the rule moves to the new category only when
    ///   exceptions outnumber hits, or at once when `autoAdd` is switched on with it
    /// `autoAdd` nil leaves the flag as it is. An exception always switches auto-add off.
    @discardableResult
    func learn(key: String, isIncome: Bool, categoryID: UUID, categoryName: String, note: String, autoAdd: Bool?) -> MerchantRule? {
        let cleanKey = MerchantMatcher.normalizedKey(key)

        guard !cleanKey.isEmpty else {
            return nil
        }

        if let index = rules.firstIndex(where: { $0.key == cleanKey && $0.isIncome == isIncome }) {
            var rule = rules[index]

            if rule.action == .categorize, rule.categoryID == categoryID {
                rule.hits += 1
                rule.categoryName = categoryName

                if let autoAdd = autoAdd {
                    rule.autoAdd = autoAdd
                }
            } else {
                rule.overrides += 1

                if autoAdd == true || rule.overrides > rule.hits || rule.action == .skip || rule.categoryID == nil {
                    rule.action = .categorize
                    rule.categoryID = categoryID
                    rule.categoryName = categoryName
                    rule.hits = 1
                    rule.overrides = 0
                    rule.autoAdd = autoAdd ?? false
                } else {
                    rule.autoAdd = false
                }
            }

            rule.lastUsedAt = Date()
            rules[index] = rule
            persist()

            return rule
        }

        let rule = MerchantRule(
            key: cleanKey, isIncome: isIncome, action: .categorize, categoryID: categoryID,
            categoryName: categoryName, note: note, autoAdd: autoAdd ?? false, hits: 1
        )

        rules.append(rule)
        persist()

        return rule
    }

    /// "Always skip this merchant".
    @discardableResult
    func learnSkip(key: String, isIncome: Bool, note: String) -> MerchantRule? {
        let cleanKey = MerchantMatcher.normalizedKey(key)

        guard !cleanKey.isEmpty else {
            return nil
        }

        if let index = rules.firstIndex(where: { $0.key == cleanKey && $0.isIncome == isIncome }) {
            rules[index].action = .skip
            rules[index].autoAdd = false
            rules[index].lastUsedAt = Date()
            persist()

            return rules[index]
        }

        let rule = MerchantRule(key: cleanKey, isIncome: isIncome, action: .skip, note: note)

        rules.append(rule)
        persist()

        return rule
    }

    func touch(_ id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return
        }

        rules[index].hits += 1
        rules[index].lastUsedAt = Date()
        persist()
    }

    // MARK: Editing

    func setAutoAdd(_ id: UUID, _ value: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return
        }

        rules[index].autoAdd = value
        persist()
    }

    /// Replaces the rule with the same id, or adds it (undo of a delete).
    func update(_ rule: MerchantRule) {
        var edited = rule
        edited.key = MerchantMatcher.normalizedKey(rule.key)

        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = edited
        } else {
            rules.append(edited)
        }

        persist()
    }

    func delete(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard isUsable else {
            return
        }

        file.save(rules)
    }
}
