//
//  SMSIngestor.swift
//  dime
//
//  Text in, suggestions or transactions out. Every write to Core Data goes through the
//  background write API, never through the view context: an automation that saved the view
//  context would also commit whatever the UI holds unsaved at that moment.
//  Main thread only.
//

import Foundation

struct SMSIngestResult {
    var added = 0 // transactions created by an auto-add rule
    var pending = 0 // new suggestions to review (transfers included)
    var transfers = 0
    var unrecognised = 0
    var duplicates = 0 // the same SMS was already known
    var alreadyLogged = 0 // matched a transaction typed by hand a few minutes before
    var skippedByRule = 0
    var ignored = 0 // one-time codes, declined operations, lines that are not bank messages
    var failed = false // the files could not be opened, nothing was stored
    var addedText: String? // "42 000 so'm", only when exactly one was added
    var addedCategory: String?
    var newSuggestionIDs = [UUID]()

    var stored: Int {
        added + pending + unrecognised
    }

    /// One short line for Shortcuts.
    var summary: String {
        if failed {
            return String(localized: "Couldn't store the message. Open the app and paste it.")
        }

        var parts = [String]()

        if added == 1, let text = addedText, let category = addedCategory {
            parts.append(String(localized: "Added \(text) to \(category)"))
        } else if added > 0 {
            parts.append(String(localized: "Added: \(added)"))
        }

        if pending > 0 {
            parts.append(String(localized: "To review: \(pending)"))
        }

        if unrecognised > 0 {
            parts.append(String(localized: "Unrecognised, saved for review: \(unrecognised)"))
        }

        if parts.isEmpty {
            if duplicates > 0 || alreadyLogged > 0 {
                return String(localized: "Already in the app")
            }

            if skippedByRule > 0 {
                return String(localized: "Skipped by your rule")
            }

            return String(localized: "Nothing to add")
        }

        return parts.joined(separator: ", ")
    }
}

/// One line of the paste preview.
struct SMSPreviewItem: Identifiable {
    enum Status {
        case fresh
        case unrecognised
        case known // already waiting or handled
        case ignored
    }

    let id = UUID()
    let text: String
    let parsed: ParsedSMS
    let status: Status
}

/// What the full entry screen needs to open prefilled from a suggestion.
struct SMSDraftRequest: Identifiable {
    let id: UUID // the suggestion id, hand it back to completeEdit
    let note: String
    let amount: Double
    let date: Date
    let income: Bool
    let categoryID: UUID?
}

struct SMSConfirmation {
    let suggestion: SMSSuggestion
    let category: SMSCategoryInfo
    /// nil leaves the rule's auto-add flag as it is.
    var autoAdd: Bool?
}

/// Everything needed to take one action back.
struct SMSUndoToken {
    struct RuleChange {
        let id: UUID
        let before: MerchantRule? // nil: the rule was created by the action
    }

    var suggestions = [SMSSuggestion]()
    var entryIDs = [UUID]()
    var transactionIDs = [UUID]()
    var ruleChanges = [RuleChange]()
}

final class SMSIngestor {
    static let shared = SMSIngestor()

    let inbox: SMSInboxStore
    let rules: SMSRuleStore
    let cards: SMSCardStore

    init(inbox: SMSInboxStore = .shared, rules: SMSRuleStore = .shared, cards: SMSCardStore = .shared) {
        self.inbox = inbox
        self.rules = rules
        self.cards = cards
    }

    // MARK: Settings

    static var appCurrency: String {
        UserDefaults.appGroup.string(forKey: MoneyFormat.currencyKey) ?? MoneyFormat.defaultCurrencyCode
    }

    /// The amount that goes into the transaction: whole units for a zero-decimal app currency
    /// (835696.80 becomes 835697), exact otherwise.
    static func amount(for parsed: ParsedSMS) -> Double {
        guard let minor = parsed.amountMinor else {
            return 0
        }

        let value = Double(abs(minor)) / 100

        return MoneyFormat.isZeroDecimal(appCurrency) ? value.rounded() : value
    }

    // MARK: Reading

    /// A pasted block as single messages. One message without line breaks stays one message.
    static func messages(in text: String) -> [String] {
        let split = SMSParser.splitMessages(text)

        if !split.isEmpty {
            return split
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? [] : [trimmed]
    }

    /// What `ingest` would do with this text, without storing anything.
    func preview(text: String, receivedAt: Date = Date(), source: SMSSource = .paste) -> [SMSPreviewItem] {
        var seen = Set<String>()
        var items = [SMSPreviewItem]()

        var messages = Self.messages(in: text)

        // An automation hands over exactly one SMS. If Shortcuts passes it as several lines
        // ("sender" + line break + "body", or a wrapped body), read it as one message: a line
        // like "HUMOCARD" on its own would otherwise land in the inbox as unrecognised.
        if source == .automation, messages.count > 1 {
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let readable = messages.filter { SMSParser.parse($0, receivedAt: receivedAt).amountMinor != nil }

            if readable.count <= 1, readable.isEmpty || SMSParser.parse(whole, receivedAt: receivedAt).amountMinor != nil {
                messages = [whole]
            }
        }

        for message in messages {
            let parsed = SMSParser.parse(message, receivedAt: receivedAt)
            var status = SMSPreviewItem.Status.fresh

            if parsed.kind == .ignored {
                status = .ignored
            } else if parsed.amountMinor == nil, source != .automation, !SMSParser.looksLikeBankMessage(message) {
                // A stray line of a pasted block ("Today 16:06"), not a bank message.
                status = .ignored
            } else if inbox.contains(fingerprint: parsed.fingerprint) || seen.contains(parsed.fingerprint) {
                status = .known
            } else if parsed.amountMinor == nil {
                status = .unrecognised
            }

            if status == .fresh || status == .unrecognised {
                seen.insert(parsed.fingerprint)
            }

            items.append(SMSPreviewItem(text: message, parsed: parsed, status: status))
        }

        return items
    }

    // MARK: Ingest

    private struct Candidate {
        var suggestion: SMSSuggestion
        var rule: MerchantRule?
        var strongRule: Bool
    }

    private struct Leg {
        let fingerprint: String
        let card: String
        let income: Bool
        let amountMinor: Int64
        let date: Date
        let pendingID: UUID?
    }

    @discardableResult
    func ingest(
        text: String, receivedAt: Date = Date(), source: SMSSource, allowAutoAdd: Bool = true, notify: Bool = false
    ) -> SMSIngestResult {
        var result = SMSIngestResult()

        inbox.reloadIfNeeded()
        rules.reloadIfNeeded()
        cards.reloadIfNeeded()

        guard inbox.isUsable else {
            result.failed = true
            DiagnosticsLog.shared.log("sms", "ingest refused: the inbox files are not readable")
            return result
        }

        if source == .automation {
            inbox.noteAutomationRun()
        }

        let scanned = preview(text: text, receivedAt: receivedAt, source: source)
        var fresh = [SMSPreviewItem]()

        for item in scanned {
            switch item.status {
            case .ignored: result.ignored += 1
            case .known: result.duplicates += 1
            case .fresh, .unrecognised: fresh.append(item)
            }
        }

        guard !fresh.isEmpty else {
            DiagnosticsLog.shared.log("sms", "ingest \(source.rawValue): nothing new, known \(result.duplicates), ignored \(result.ignored)")
            return result
        }

        cards.note(fresh.map { $0.parsed })

        let appCurrency = Self.appCurrency
        let batchID: UUID? = (source == .paste || source == .file) ? UUID() : nil

        var categories = [UUID: SMSCategoryInfo]()

        for category in SMSDataLookup.categories() {
            categories[category.id] = category
        }

        let existing = existingTransactions(around: fresh.map { $0.parsed })
        var takenTransactions = inbox.createdTransactionIDs
        var history = [String: UUID]()
        var historyMisses = Set<String>()
        var candidates = [Candidate]()
        var ledgerEntries = [SMSLedgerEntry]()

        // Pass 1: rule, category, duplicate check.
        for item in fresh {
            let parsed = item.parsed
            var flags = [SMSSuggestion.Flag]()
            let foreign = parsed.currency != nil && parsed.currency != appCurrency

            if foreign {
                flags.append(.foreignCurrency)
            }

            if parsed.amountMinor != nil, parsed.confidence < 1 || !parsed.dateFromText {
                flags.append(.lowConfidence)
            }

            if parsed.namesTwoNetworks {
                flags.append(.ownTransfer)
            }

            let match = parsed.amountMinor == nil ? nil : rules.bestMatch(for: parsed)

            if let match = match, match.rule.action == .skip, match.isStrong {
                ledgerEntries.append(entry(for: parsed, resolution: .skipped, transactionID: nil, ruleID: match.rule.id, batchID: batchID))
                result.skippedByRule += 1
                continue
            }

            var categoryID: UUID?
            var categorySource: String?
            var matchedRule: MerchantRule?
            var score = 0.0

            if let match = match, match.rule.action == .categorize, let id = match.rule.categoryID,
               let category = categories[id], category.income == parsed.isIncome
            {
                categoryID = id
                categorySource = "rule"
                matchedRule = match.rule
                score = match.score
            } else if parsed.direction != nil, let token = parsed.merchantKey.split(separator: " ").first.map({ String($0) }) {
                // No rule yet: look at what the owner typed by hand for this merchant before.
                let cacheKey = (parsed.isIncome ? "+" : "-") + token

                if let known = history[cacheKey] {
                    categoryID = known
                    categorySource = "history"
                } else if !historyMisses.contains(cacheKey) {
                    if let found = SMSDataLookup.historyCategory(token: token, income: parsed.isIncome), categories[found] != nil {
                        history[cacheKey] = found
                        categoryID = found
                        categorySource = "history"
                    } else {
                        historyMisses.insert(cacheKey)
                    }
                }
            }

            var duplicateID: UUID?

            if !foreign, parsed.amountMinor != nil, parsed.direction != nil,
               let duplicate = Self.duplicate(of: parsed, in: existing, excluding: takenTransactions)
            {
                takenTransactions.insert(duplicate.id)

                if duplicate.strong, source == .automation, duplicate.seconds <= 600 {
                    // The owner typed it at the till a moment ago: link it, show nothing.
                    ledgerEntries.append(entry(for: parsed, resolution: .duplicate, transactionID: duplicate.id, ruleID: nil, batchID: batchID))
                    result.alreadyLogged += 1
                    continue
                }

                flags.append(.possibleDuplicate)
                duplicateID = duplicate.id
            }

            let suggestion = SMSSuggestion(
                id: UUID(), receivedAt: receivedAt, rawText: item.text, parsed: parsed,
                suggestedCategoryID: categoryID, categorySource: categorySource, matchedRuleID: matchedRule?.id,
                matchScore: score, duplicateOfTransactionID: duplicateID, flags: flags, source: source, batchID: batchID
            )

            candidates.append(Candidate(suggestion: suggestion, rule: matchedRule, strongRule: match?.isStrong ?? false))
        }

        // Pass 2: an outgoing and an incoming message on two own cards within 10 minutes are one transfer.
        pairOwnTransfers(&candidates)

        // Pass 3: auto-add what a trusted rule covers, everything else waits for review.
        var automatic = [Candidate]()
        var toReview = [SMSSuggestion]()

        for candidate in candidates {
            let suggestion = candidate.suggestion
            let kind = suggestion.parsed.kind
            let trusted = candidate.rule?.autoAdd == true && candidate.strongRule
            let plainKind = kind == .payment || kind == .topUp || kind == .refund

            if allowAutoAdd, trusted, plainKind, suggestion.flags.isEmpty, suggestion.suggestedCategoryID != nil {
                automatic.append(candidate)
            } else {
                toReview.append(suggestion)
            }
        }

        if !automatic.isEmpty {
            let drafts = automatic.map { candidate -> TransactionDraft in
                let parsed = candidate.suggestion.parsed

                return TransactionDraft(
                    note: candidate.rule?.note.isEmpty == false ? (candidate.rule?.note ?? "") : parsed.merchantDisplay,
                    categoryID: candidate.suggestion.suggestedCategoryID, income: parsed.isIncome,
                    amount: Self.amount(for: parsed), date: parsed.date
                )
            }

            do {
                let ids = try DataController.shared.newTransactions(drafts, reason: "sms auto add")

                for (index, candidate) in automatic.enumerated() where index < ids.count {
                    let parsed = candidate.suggestion.parsed

                    ledgerEntries.append(entry(for: parsed, resolution: .autoAdded, transactionID: ids[index], ruleID: candidate.rule?.id, batchID: batchID))

                    if let rule = candidate.rule {
                        rules.touch(rule.id)
                    }
                }

                result.added = ids.count

                if let only = automatic.first, automatic.count == 1 {
                    let parsed = only.suggestion.parsed

                    result.addedText = MoneyFormat.string(Self.amount(for: parsed))
                    result.addedCategory = only.suggestion.suggestedCategoryID.flatMap { categories[$0]?.name }
                }
            } catch {
                // Nothing was written. Keep the messages for review instead of losing them.
                DiagnosticsLog.shared.log("sms", "auto add FAILED, \(automatic.count) moved to review")
                toReview.append(contentsOf: automatic.map { $0.suggestion })
            }
        }

        inbox.append(ledgerEntries)

        if !inbox.add(toReview) {
            // Not on disk: a background run may be killed before the next write.
            result.failed = true
        }

        for suggestion in toReview {
            if suggestion.isUnrecognised {
                result.unrecognised += 1
            } else {
                result.pending += 1

                if suggestion.isOwnTransfer {
                    result.transfers += 1
                }
            }
        }

        result.newSuggestionIDs = toReview.map { $0.id }

        DiagnosticsLog.shared.log(
            "sms",
            "ingest \(source.rawValue): added \(result.added), review \(result.pending), transfers \(result.transfers), "
                + "unrecognised \(result.unrecognised), known \(result.duplicates), logged \(result.alreadyLogged), "
                + "rule skip \(result.skippedByRule), ignored \(result.ignored)"
        )

        if notify, !toReview.isEmpty {
            SMSNotifier.postNewSuggestions(total: inbox.pending.count)
        }

        return result
    }

    // MARK: Resolving

    /// Creates the transactions with one save, learns the rules and moves the messages to the ledger.
    /// Throws when nothing could be saved; the inbox is untouched then.
    @discardableResult
    func confirm(_ confirmations: [SMSConfirmation]) throws -> SMSUndoToken {
        let valid = confirmations.filter { $0.suggestion.parsed.amountMinor != nil }
        var token = SMSUndoToken()

        guard !valid.isEmpty else {
            return token
        }

        let drafts = valid.map { item -> TransactionDraft in
            let parsed = item.suggestion.parsed

            return TransactionDraft(
                note: parsed.merchantDisplay, categoryID: item.category.id, income: item.category.income,
                amount: Self.amount(for: parsed), date: parsed.date
            )
        }

        let ids = try DataController.shared.newTransactions(drafts, reason: "sms confirm")
        var entries = [SMSLedgerEntry]()

        for (index, item) in valid.enumerated() where index < ids.count {
            let suggestion = item.suggestion
            let parsed = suggestion.parsed
            var ruleID: UUID?

            // A transfer logged by hand or an unknown operation is a one-off, not a habit to learn.
            let learnable = !parsed.merchantKey.isEmpty && parsed.direction != nil && !suggestion.isOwnTransfer

            if learnable {
                let matched = rules.rule(withID: suggestion.matchedRuleID)

                if let matched = matched, item.autoAdd == nil, suggestion.matchScore >= 0.9,
                   matched.action == .categorize, matched.categoryID == item.category.id
                {
                    token.ruleChanges.append(SMSUndoToken.RuleChange(id: matched.id, before: matched))
                    rules.touch(matched.id)
                    ruleID = matched.id
                } else {
                    let before = rules.exactRule(key: MerchantMatcher.normalizedKey(parsed.merchantKey), isIncome: item.category.income)
                    let learned = rules.learn(
                        key: parsed.merchantKey, isIncome: item.category.income, categoryID: item.category.id,
                        categoryName: item.category.name, note: parsed.merchantDisplay, autoAdd: item.autoAdd
                    )

                    if let learned = learned {
                        token.ruleChanges.append(SMSUndoToken.RuleChange(id: learned.id, before: before))
                        ruleID = learned.id
                    }
                }
            }

            var line = entry(for: parsed, resolution: .added, transactionID: ids[index], ruleID: ruleID, batchID: suggestion.batchID)
            line.isIncome = item.category.income
            entries.append(line)
        }

        token.suggestions = valid.map { $0.suggestion }
        token.transactionIDs = ids
        token.entryIDs = entries.map { $0.id }

        inbox.resolve(token.suggestions.map { $0.id }, entries: entries)
        DiagnosticsLog.shared.log("sms", "confirmed \(ids.count)")

        return token
    }

    /// Nothing is created. `.duplicate` links the message to the transaction it matched.
    @discardableResult
    func skip(_ suggestions: [SMSSuggestion], as resolution: SMSLedgerEntry.Resolution = .skipped) -> SMSUndoToken {
        var token = SMSUndoToken()
        var entries = [SMSLedgerEntry]()

        for suggestion in suggestions {
            let linked = resolution == .duplicate ? suggestion.duplicateOfTransactionID : nil

            entries.append(entry(for: suggestion.parsed, resolution: resolution, transactionID: linked, ruleID: nil, batchID: suggestion.batchID))
        }

        token.suggestions = suggestions
        token.entryIDs = entries.map { $0.id }

        inbox.resolve(suggestions.map { $0.id }, entries: entries)
        DiagnosticsLog.shared.log("sms", "\(resolution.rawValue) \(suggestions.count)")

        return token
    }

    /// "Always skip this merchant": a skip rule, and every waiting message of that merchant leaves the inbox.
    @discardableResult
    func alwaysSkip(_ suggestion: SMSSuggestion) -> SMSUndoToken {
        let key = MerchantMatcher.normalizedKey(suggestion.parsed.merchantKey)
        let before = rules.exactRule(key: key, isIncome: suggestion.isIncome)
        let rule = rules.learnSkip(key: key, isIncome: suggestion.isIncome, note: suggestion.parsed.merchantDisplay)

        let same = inbox.pending.filter { other in
            other.id == suggestion.id || (!key.isEmpty && other.parsed.merchantKey == key && other.isIncome == suggestion.isIncome)
        }

        var token = skip(same)

        if let rule = rule {
            token.ruleChanges.append(SMSUndoToken.RuleChange(id: rule.id, before: before))
        }

        return token
    }

    /// Takes back a confirm or a skip. Throws when the created transactions could not be removed;
    /// nothing else is changed then.
    func undo(_ token: SMSUndoToken) throws {
        if !token.transactionIDs.isEmpty {
            try DataController.shared.deleteTransactions(ids: token.transactionIDs, reason: "sms undo")
        }

        for change in token.ruleChanges.reversed() {
            if let before = change.before {
                rules.update(before)
            } else {
                rules.delete(change.id)
            }
        }

        inbox.restore(token.suggestions, removingEntries: token.entryIDs)
        DiagnosticsLog.shared.log("sms", "undo \(token.suggestions.count)")
    }

    // MARK: Editing a suggestion in place

    func setCategory(_ categoryID: UUID?, for suggestionID: UUID) {
        guard var suggestion = inbox.suggestion(withID: suggestionID) else {
            return
        }

        suggestion.suggestedCategoryID = categoryID
        suggestion.categorySource = categoryID == nil ? nil : "manual"
        inbox.update(suggestion)
    }

    /// For a message whose direction could not be read, or was read wrong.
    func setDirection(_ direction: SMSDirection, for suggestionID: UUID) {
        guard var suggestion = inbox.suggestion(withID: suggestionID), suggestion.parsed.direction != direction else {
            return
        }

        suggestion.parsed.direction = direction
        suggestion.suggestedCategoryID = nil
        suggestion.categorySource = nil
        suggestion.matchedRuleID = nil
        suggestion.matchScore = 0
        inbox.update(suggestion)
    }

    /// "It's my own card": the message moves to Transfers. `false` moves it back.
    func setOwnTransfer(_ value: Bool, for suggestionID: UUID) {
        guard var suggestion = inbox.suggestion(withID: suggestionID) else {
            return
        }

        suggestion.flags.removeAll { $0 == .ownTransfer }

        if value {
            suggestion.flags.append(.ownTransfer)
        }

        inbox.update(suggestion)
    }

    // MARK: Full entry screen

    func draftRequest(for suggestion: SMSSuggestion) -> SMSDraftRequest {
        // 45.99 USD is not 45.99 in the app currency: the amount is left empty and typed by hand.
        let amount = suggestion.has(.foreignCurrency) ? 0 : Self.amount(for: suggestion.parsed)

        return SMSDraftRequest(
            id: suggestion.id, note: suggestion.parsed.merchantDisplay, amount: amount,
            date: suggestion.parsed.date, income: suggestion.isIncome, categoryID: suggestion.suggestedCategoryID
        )
    }

    /// Call after the entry screen saved the transaction it opened from `SMSDraftRequest`.
    /// The message leaves the inbox and the rule is learned from what was really saved.
    func completeEdit(suggestionID: UUID, transactionID: UUID?) {
        guard let suggestion = inbox.suggestion(withID: suggestionID) else {
            return
        }

        let parsed = suggestion.parsed
        var ruleID: UUID?
        var income = suggestion.isIncome

        if let transactionID = transactionID, let saved = SMSDataLookup.transaction(withID: transactionID) {
            income = saved.income

            if let categoryID = saved.categoryID, !parsed.merchantKey.isEmpty, !suggestion.isOwnTransfer,
               let category = SMSDataLookup.categories().first(where: { $0.id == categoryID })
            {
                let note = saved.note.isEmpty ? parsed.merchantDisplay : saved.note

                ruleID = rules.learn(
                    key: parsed.merchantKey, isIncome: saved.income, categoryID: categoryID,
                    categoryName: category.name, note: note, autoAdd: nil
                )?.id
            }
        }

        var line = entry(for: parsed, resolution: .added, transactionID: transactionID, ruleID: ruleID, batchID: suggestion.batchID)
        line.isIncome = income

        inbox.resolve([suggestionID], entries: [line])
        DiagnosticsLog.shared.log("sms", "confirmed 1 through the entry screen")
    }

    // MARK: Internals

    private func entry(
        for parsed: ParsedSMS, resolution: SMSLedgerEntry.Resolution, transactionID: UUID?, ruleID: UUID?, batchID: UUID?
    ) -> SMSLedgerEntry {
        SMSLedgerEntry(
            id: UUID(), fingerprint: parsed.fingerprint, resolution: resolution, transactionID: transactionID,
            date: parsed.date, resolvedAt: Date(), amountMinor: parsed.amountMinor, isIncome: parsed.isIncome,
            cardLast4: parsed.cardLast4, merchantKey: parsed.merchantKey, ruleID: ruleID, batchID: batchID
        )
    }

    /// One fetch for the whole batch: every transaction from the day before the oldest message
    /// to the day after the newest one.
    private func existingTransactions(around messages: [ParsedSMS]) -> [SMSTransactionInfo] {
        let dates = messages.filter { $0.amountMinor != nil && $0.direction != nil }.map { $0.date }

        guard let oldest = dates.min(), let newest = dates.max() else {
            return []
        }

        let calendar = Calendar.current

        guard let from = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: oldest)),
              let to = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: newest))
        else {
            return []
        }

        return SMSDataLookup.transactions(from: from, to: to)
    }

    private struct DuplicateMatch {
        let id: UUID
        let strong: Bool
        let seconds: TimeInterval
    }

    /// Strong: the amount differs by less than 1 (42000 typed for 42000.00, 278566 for 835696.80)
    /// on the same day or within 12 hours. Weak: within 1 % on the same day (typed a rounded number).
    private static func duplicate(of parsed: ParsedSMS, in existing: [SMSTransactionInfo], excluding: Set<UUID>) -> DuplicateMatch? {
        guard let amount = parsed.amountValue else {
            return nil
        }

        let value = abs(amount)
        let calendar = Calendar.current
        var best: DuplicateMatch?

        for transaction in existing {
            if transaction.income != parsed.isIncome || excluding.contains(transaction.id) {
                continue
            }

            let difference = abs(transaction.amount - value)
            let seconds = abs(transaction.date.timeIntervalSince(parsed.date))
            let sameDay = calendar.isDate(transaction.date, inSameDayAs: parsed.date)
            var found: DuplicateMatch?

            if difference < 1.0, sameDay || seconds <= 12 * 3600 {
                found = DuplicateMatch(id: transaction.id, strong: true, seconds: seconds)
            } else if value > 0, difference <= value * 0.01, sameDay {
                found = DuplicateMatch(id: transaction.id, strong: false, seconds: seconds)
            }

            guard let match = found else {
                continue
            }

            if let current = best {
                if match.strong != current.strong {
                    if match.strong {
                        best = match
                    }
                } else if match.seconds < current.seconds {
                    best = match
                }
            } else {
                best = match
            }
        }

        return best
    }

    private func pairOwnTransfers(_ candidates: inout [Candidate]) {
        var legs = [Leg]()

        for candidate in candidates {
            if let leg = Self.leg(candidate.suggestion.parsed, pendingID: nil) {
                legs.append(leg)
            }
        }

        for suggestion in inbox.pending {
            if let leg = Self.leg(suggestion.parsed, pendingID: suggestion.id) {
                legs.append(leg)
            }
        }

        for line in inbox.ledger.suffix(200) {
            if let card = line.cardLast4, let amount = line.amountMinor {
                legs.append(Leg(fingerprint: line.fingerprint, card: card, income: line.isIncome, amountMinor: abs(amount), date: line.date, pendingID: nil))
            }
        }

        for index in candidates.indices {
            let suggestion = candidates[index].suggestion

            guard !suggestion.isOwnTransfer, let mine = Self.leg(suggestion.parsed, pendingID: nil), cards.isOwn(mine.card) else {
                continue
            }

            for other in legs {
                if other.fingerprint == mine.fingerprint || other.card == mine.card || other.income == mine.income {
                    continue
                }

                if !cards.isOwn(other.card) || abs(other.date.timeIntervalSince(mine.date)) > 600 {
                    continue
                }

                // The incoming side may be smaller by the commission, up to 3 %.
                let outgoing = mine.income ? other.amountMinor : mine.amountMinor
                let incoming = mine.income ? mine.amountMinor : other.amountMinor

                if incoming > outgoing || Double(incoming) < Double(outgoing) * 0.97 {
                    continue
                }

                candidates[index].suggestion.flags.append(.ownTransfer)

                if let pendingID = other.pendingID, var waiting = inbox.suggestion(withID: pendingID), !waiting.isOwnTransfer {
                    waiting.flags.append(.ownTransfer)
                    inbox.update(waiting)
                }

                break
            }
        }
    }

    private static func leg(_ parsed: ParsedSMS, pendingID: UUID?) -> Leg? {
        guard let card = parsed.cardLast4, let amount = parsed.amountMinor, parsed.direction != nil else {
            return nil
        }

        return Leg(fingerprint: parsed.fingerprint, card: card, income: parsed.isIncome, amountMinor: abs(amount), date: parsed.date, pendingID: pendingID)
    }
}
