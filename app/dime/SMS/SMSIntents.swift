//
//  SMSIntents.swift
//  dime
//
//  App target only. AddBankSMSIntent is the action of the Shortcuts message automation.
//  It is deliberately NOT an App Shortcut: every AppIntent of the app is already listed as an
//  action in the Shortcuts editor, and a Siri phrase makes no sense for an intent whose only
//  input is a message text. Only OpenSMSInboxIntent belongs in DimeShortcuts.
//

import AppIntents
import Foundation

struct AddBankSMSIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Bank SMS"

    static var description = IntentDescription(
        "Reads a bank SMS and adds it as a transaction or as a suggestion to review."
    )

    // Runs in background: an automation that fires on every bank message must stay invisible.
    static var openAppWhenRun: Bool = false

    // Optional on purpose: a missing value must never make Shortcuts stop and ask in the middle
    // of a background automation.
    @Parameter(title: "Message text")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add bank SMS \(\.$text)")
    }

    // Never throws: a text that cannot be read is stored as unrecognised and shown in the inbox.
    // The returned line ("Added 42 000 so'm to Taxi", "To review: 1") can be chained into
    // "Show Notification" or "Speak Text" in Shortcuts.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = SMSIngestor.shared.ingest(
            text: text ?? "", receivedAt: Date(), source: .automation, allowAutoAdd: true, notify: true
        )

        return .result(value: result.summary)
    }
}

struct OpenSMSInboxIntent: AppIntent {
    static var title: LocalizedStringResource = "Review Bank Messages"

    static var description = IntentDescription("Opens the bank messages that wait for review.")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SMSRouter.shared.openInbox()

        return .result()
    }
}
