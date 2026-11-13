//
//  LogSearchView.swift
//  dime
//
//  App target only. Search runs over the rows the Log already holds in memory:
//  no fetch per keystroke.
//

import SwiftUI

struct LogSearchResults: Equatable {
    var sections = [LogDaySection]()
    var count = 0
    /// Income minus expenses of the matches.
    var total = 0.0
}

enum LogSearch {
    /// Matches the note, the category name and the amount. An amount query may be
    /// grouped ("35 880 000") or partial ("3588" finds 35 880 000).
    static func run(_ query: String, in rows: [LogRowModel]) -> LogSearchResults {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return LogSearchResults()
        }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var amount: Double?
        var amountPrefix: String?

        if looksLikeAmount(text), let parsed = MoneyFormat.parse(text) {
            let magnitude = abs(parsed)
            amount = magnitude

            if magnitude >= 1, magnitude == magnitude.rounded(), magnitude <= MoneyFormat.maxAmount {
                amountPrefix = String(Int64(magnitude))
            }
        }

        var matches = [LogRowModel]()
        var total = 0.0

        for row in rows {
            var hit = row.note.range(of: text, options: options) != nil
                || row.categoryName.range(of: text, options: options) != nil

            if !hit, let amount = amount {
                if abs(row.amount - amount) < 0.005 {
                    hit = true
                } else if let prefix = amountPrefix, row.amount.isFinite, abs(row.amount) < 9e15 {
                    hit = String(Int64(row.amount)).hasPrefix(prefix)
                }
            }

            if hit {
                matches.append(row)
                total += row.signedAmount
            }
        }

        return LogSearchResults(sections: LogSections.group(matches), count: matches.count, total: total)
    }

    private static func looksLikeAmount(_ text: String) -> Bool {
        var digits = 0

        for character in text {
            if character.isNumber {
                digits += 1
            } else if !(character.isWhitespace || ".,'".contains(character)) {
                return false
            }
        }

        return digits > 0
    }
}

struct SearchView: View {
    @Environment(\.dismiss) var dismiss

    @ObservedObject var feed = LogFeed.shared

    @State var searchQuery = ""
    @State var results = LogSearchResults()
    /// The query the results on screen belong to.
    @State var searchedQuery = ""
    @FocusState var searchFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(.body, design: .rounded).weight(.regular))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundColor(Color.DarkIcon.opacity(0.8))
                        .accessibility(hidden: true)

                    TextField("Search note, category or amount", text: $searchQuery)
                        .focused($searchFocused)
                        .font(.system(.body, design: .rounded).weight(.regular))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundColor(Color.PrimaryText)
                        .autocorrectionDisabled()
                        .submitLabel(.search)

                    if searchQuery != "" {
                        Button {
                            searchQuery = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(.subheadline, design: .rounded).weight(.regular))
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .foregroundColor(Color.SubtitleText)
                                .frame(minWidth: 30, minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .foregroundColor(Color.PrimaryText)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }

            if !searchedQuery.isEmpty && results.count > 0 {
                HStack {
                    Text("\(results.count) entries")
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    AmountText(results.total, role: .caption, sign: .always, fit: .fullOnly, color: Color.SubtitleText)
                        .layoutPriority(1)
                }
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundColor(Color.SubtitleText)
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
            }

            ScrollView(showsIndicators: false) {
                if !searchedQuery.isEmpty && results.count == 0 {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.fill")
                            .font(.system(.largeTitle, design: .rounded))
                            .foregroundColor(Color.SubtitleText)
                            .padding(.bottom, 10)
                            .accessibilityHidden(true)

                        Text("No entries found.")
                            .font(.system(.title3, design: .rounded).weight(.medium))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundColor(Color.PrimaryText)

                        Text("Try a different search query!")
                            .font(.system(.subheadline, design: .rounded).weight(.regular))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundColor(Color.SubtitleText)
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(0.8)
                    .padding(.top, 80)
                } else {
                    LogSectionsView(sections: results.sections)
                        .padding(.bottom, 30)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(15)
        .background(Color.PrimaryBackground)
        .background(TransactionCoverHost(inSearch: true))
        .toastHost()
        .task(id: searchQuery) {
            // Wait for a pause in typing; the previous results stay on screen meanwhile.
            if !searchQuery.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            if !Task.isCancelled {
                runSearch()
            }
        }
        .onChange(of: feed.revision) { _, _ in
            // A row was edited or deleted from the results.
            runSearch()
        }
        .onAppear {
            OverallTransactionManager.shared.searchActive = true
            searchFocused = true

            // A cover that is still animating in can drop the first focus request.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !searchFocused {
                    searchFocused = true
                }
            }
        }
        .onDisappear {
            OverallTransactionManager.shared.searchActive = false
        }
    }

    func runSearch() {
        results = LogSearch.run(searchQuery, in: feed.rows)
        searchedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
