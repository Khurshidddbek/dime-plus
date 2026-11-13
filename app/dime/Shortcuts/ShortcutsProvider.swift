//
//  ShortcutsProvider.swift
//  dime
//
//  Created by Rafael Soh on 5/8/23.
//

import AppIntents
import Foundation

// Phrases are translated in Localizations/<lang>.lproj/AppShortcuts.strings; keep the keys in sync.
@available(iOS 16.4, *)
struct DimeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewTransactionIntent(),
            phrases: [
                "Log a new transaction in \(.applicationName)",
                "Add a transaction in \(.applicationName)"
            ],
            systemImageName: "books.vertical.fill"
        )
        AppShortcut(
            intent: GetInsightsIntent(),
            phrases: [
                "Get insights in \(.applicationName)",
                "Show insights in \(.applicationName)"
            ],
            systemImageName: "plusminus.circle.fill"
        )
        AppShortcut(
            intent: BudgetIntent(),
            phrases: [
                "Extract leftover amount for your budgets in \(.applicationName)",
                "Check my budget in \(.applicationName)"
            ],
            systemImageName: "circle.grid.2x2.fill"
        )
        AppShortcut(
            intent: OpenSMSInboxIntent(),
            phrases: ["Review bank messages in \(.applicationName)"],
            systemImageName: "text.bubble.fill"
        )
    }
}
