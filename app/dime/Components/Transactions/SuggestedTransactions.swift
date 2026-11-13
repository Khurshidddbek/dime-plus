//
//  SuggestedTransactions.swift
//  dime
//
//  Created by Yumi on 2023-10-28.
//

import SwiftUI

// Chips with past notes, shown in place of the date and category row while the note field has focus.
struct NoteSuggestionChips: View {
    let suggestions: [NoteSuggestion]
    let categoryFor: (NoteSuggestion) -> Category?
    let onPick: (NoteSuggestion) -> Void

    @AppStorage("currency", store: UserDefaults.appGroup) private var currency: String = MoneyFormat.defaultCurrencyCode
    @AppStorage("showCents", store: UserDefaults.appGroup) private var showCents: Bool = true

    init(
        suggestions: [NoteSuggestion],
        categoryFor: @escaping (NoteSuggestion) -> Category?,
        onPick: @escaping (NoteSuggestion) -> Void
    ) {
        self.suggestions = suggestions
        self.categoryFor = categoryFor
        self.onPick = onPick
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onPick(suggestion)
                    } label: {
                        chip(suggestion, category: categoryFor(suggestion))
                    }
                    .buttonStyle(NumPadButton())
                }
            }
        }
        .edgeToEdgeChips()
        .padding(.bottom, 5)
    }

    private func chip(_ suggestion: NoteSuggestion, category: Category?) -> some View {
        HStack(spacing: 3) {
            if let category {
                Text(category.wrappedEmoji)
                    .font(.system(.footnote, design: .rounded))
                    .padding(.vertical, 3.5)
                    .padding(.horizontal, 5)
                    .background(
                        Color(hex: category.wrappedColour).opacity(0.23),
                        in: RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    )
            }

            Text(shortened(suggestion.note))
                .foregroundStyle(Color.PrimaryText)
                .lineLimit(1)
                .padding(.vertical, 3.5)
                .padding(.horizontal, 7)

            if suggestion.amountIsStable {
                Text(amountLabel(suggestion.lastAmount))
                    .lineLimit(1)
                    .foregroundStyle(Color.SubtitleText)
                    .padding(.vertical, 3.5)
                    .padding(.trailing, 5)
            }
        }
        .font(.system(.body, design: .rounded).weight(.semibold))
        .padding(5)
        .frame(minHeight: 44)
        .background(
            Color.SecondaryBackground,
            in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
        )
    }

    // Notes can be 300 characters long now, a chip shows the start only.
    private func shortened(_ note: String) -> String {
        note.count > 28 ? String(note.prefix(27)) + "..." : note
    }

    // Number only, compact from 100 000 up: the chip stays short for large amounts.
    private func amountLabel(_ value: Double) -> String {
        let settings = MoneySettings.resolve(currency: currency, showCents: showCents)
        return MoneyFormat.compactParts(value, settings: settings).withoutSymbol().text
    }
}
