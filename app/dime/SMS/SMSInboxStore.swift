//
//  SMSInboxStore.swift
//  dime
//
//  Bank messages waiting for review (inbox.json) and the ledger of handled ones (ledger.json),
//  both in <app group>/Sms. The ledger is what stops the same SMS from being suggested twice.
//  Main thread only.
//

import Combine
import Foundation

enum SMSSource: String, Codable {
    case automation // Shortcuts message automation
    case paste
    case file
    case test
}

struct SMSSuggestion: Codable, Identifiable, Equatable {
    enum Flag: String, Codable {
        case possibleDuplicate // an existing transaction looks the same
        case ownTransfer // between the owner's own cards
        case foreignCurrency // not the app currency
        case lowConfidence // read by the generic parser or without a date
    }

    var id: UUID
    var receivedAt: Date
    var rawText: String
    var parsed: ParsedSMS
    var suggestedCategoryID: UUID?
    var categorySource: String? // "rule" | "history" | "manual"
    var matchedRuleID: UUID?
    var matchScore: Double
    var duplicateOfTransactionID: UUID?
    var flags: [Flag]
    var source: SMSSource
    var batchID: UUID?

    var isIncome: Bool {
        parsed.direction == .income
    }

    /// No amount could be read: only the text can be shown.
    var isUnrecognised: Bool {
        parsed.amountMinor == nil
    }

    var isOwnTransfer: Bool {
        flags.contains(.ownTransfer)
    }

    func has(_ flag: Flag) -> Bool {
        flags.contains(flag)
    }
}

struct SMSLedgerEntry: Codable, Identifiable, Equatable {
    enum Resolution: String, Codable {
        case added // confirmed by the owner
        case autoAdded // added by a rule without review
        case skipped
        case duplicate // already in the Log, nothing was created
    }

    var id: UUID
    var fingerprint: String
    var resolution: Resolution
    var transactionID: UUID?
    var date: Date // time of the operation
    var resolvedAt: Date
    var amountMinor: Int64?
    var isIncome: Bool
    var cardLast4: String?
    var merchantKey: String
    var ruleID: UUID?
    var batchID: UUID?
}

final class SMSInboxStore: ObservableObject {
    static let shared = SMSInboxStore()

    static let ledgerLimit = 5000
    static let lastAutomationKey = "smsLastAutomationRunAt"

    /// Newest operation first.
    @Published private(set) var pending: [SMSSuggestion] = []
    @Published private(set) var lastAutomationRunAt: Date?
    private(set) var ledger: [SMSLedgerEntry] = []
    private(set) var isUsable = false

    private var fingerprints = Set<String>()
    private let inboxFile: SMSJSONFile<SMSSuggestion>
    private let ledgerFile: SMSJSONFile<SMSLedgerEntry>

    init(
        inboxFile: SMSJSONFile<SMSSuggestion> = SMSJSONFile<SMSSuggestion>(name: "inbox.json"),
        ledgerFile: SMSJSONFile<SMSLedgerEntry> = SMSJSONFile<SMSLedgerEntry>(name: "ledger.json")
    ) {
        self.inboxFile = inboxFile
        self.ledgerFile = ledgerFile
        reload()
    }

    func reload() {
        let inbox = inboxFile.load()
        let handled = ledgerFile.load()

        isUsable = inbox.state == .loaded && handled.state == .loaded
        ledger = handled.items
        pending = Self.sorted(inbox.items)
        rebuildFingerprints()

        let stamp = UserDefaults.appGroup.double(forKey: Self.lastAutomationKey)
        lastAutomationRunAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// A second try for files that were locked when the process started.
    func reloadIfNeeded() {
        if !isUsable {
            reload()
        }
    }

    // MARK: Lookup

    /// True when this message is already waiting or was handled before.
    func contains(fingerprint: String) -> Bool {
        fingerprints.contains(fingerprint)
    }

    func suggestion(withID id: UUID) -> SMSSuggestion? {
        pending.first { $0.id == id }
    }

    /// Transactions this feature created. They are left out of the "already entered by hand" check.
    var createdTransactionIDs: Set<UUID> {
        Set(ledger.compactMap { $0.transactionID })
    }

    func ledgerEntry(fingerprint: String) -> SMSLedgerEntry? {
        ledger.last { $0.fingerprint == fingerprint }
    }

    // MARK: Inbox

    func add(_ suggestions: [SMSSuggestion]) {
        guard !suggestions.isEmpty else {
            return
        }

        pending = Self.sorted(pending + suggestions)

        for suggestion in suggestions {
            fingerprints.insert(suggestion.parsed.fingerprint)
        }

        saveInbox()
    }

    func update(_ suggestion: SMSSuggestion) {
        guard let index = pending.firstIndex(where: { $0.id == suggestion.id }) else {
            return
        }

        pending[index] = suggestion
        saveInbox()
    }

    /// Takes messages out of the inbox and writes how they were handled, in one go.
    func resolve(_ ids: [UUID], entries: [SMSLedgerEntry]) {
        let removed = Set(ids)

        if !removed.isEmpty {
            pending.removeAll { removed.contains($0.id) }
        }

        append(entries)
        saveInbox()
    }

    /// Undo of `resolve`: the ledger lines go away and the messages come back.
    func restore(_ suggestions: [SMSSuggestion], removingEntries entryIDs: [UUID]) {
        let removed = Set(entryIDs)

        if !removed.isEmpty {
            ledger.removeAll { removed.contains($0.id) }
            saveLedger()
        }

        let known = Set(pending.map { $0.id })
        let back = suggestions.filter { !known.contains($0.id) }

        pending = Self.sorted(pending + back)
        rebuildFingerprints()
        saveInbox()
    }

    // MARK: Ledger

    func append(_ entries: [SMSLedgerEntry]) {
        guard !entries.isEmpty else {
            return
        }

        ledger.append(contentsOf: entries)

        if ledger.count > Self.ledgerLimit {
            ledger.removeFirst(ledger.count - Self.ledgerLimit)
            rebuildFingerprints()
        } else {
            for entry in entries {
                fingerprints.insert(entry.fingerprint)
            }
        }

        saveLedger()
    }

    func noteAutomationRun(at date: Date = Date()) {
        lastAutomationRunAt = date
        UserDefaults.appGroup.set(date.timeIntervalSince1970, forKey: Self.lastAutomationKey)
    }

    // MARK: Internals

    private static func sorted(_ items: [SMSSuggestion]) -> [SMSSuggestion] {
        items.sorted { first, second in
            if first.parsed.date != second.parsed.date {
                return first.parsed.date > second.parsed.date
            }

            return first.receivedAt > second.receivedAt
        }
    }

    private func rebuildFingerprints() {
        var all = Set<String>()

        for suggestion in pending {
            all.insert(suggestion.parsed.fingerprint)
        }

        for entry in ledger {
            all.insert(entry.fingerprint)
        }

        fingerprints = all
    }

    private func saveInbox() {
        guard isUsable else {
            return
        }

        inboxFile.save(pending)
    }

    private func saveLedger() {
        guard isUsable else {
            return
        }

        ledgerFile.save(ledger)
    }
}
