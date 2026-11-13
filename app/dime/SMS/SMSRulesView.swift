//
//  SMSRulesView.swift
//  dime
//
//  The learned "merchant goes to category" rules and the owner's own cards.
//  Works as a sheet and as a pushed settings screen. Needs a managed object context
//  in the environment (for the category list).
//

import CoreData
import SwiftUI

struct SMSRulesView: View {
    @ObservedObject private var ruleStore = SMSRuleStore.shared
    @ObservedObject private var cardStore = SMSCardStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var moc

    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "order", ascending: false)])
    private var fetchedCategories: FetchedResults<Category>

    @State private var query = ""
    @State private var editingRule: MerchantRule?
    @State private var showAddCard = false
    @State private var newCardDigits = ""
    @State private var renamingCard: SMSCard?
    @State private var cardName = ""
    @State private var showRename = false

    init() {}

    private var categories: [SMSCategoryInfo] {
        fetchedCategories.compactMap { SMSCategoryInfo($0) }
    }

    private var shownRules: [MerchantRule] {
        ruleStore.rules(matching: query).sorted { first, second in
            if first.hits != second.hits {
                return first.hits > second.hits
            }

            return first.key < second.key
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SMSScreenHeader("Rules and cards", onClose: { dismiss() })
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    cardsSection

                    rulesSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.PrimaryBackground.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .toastHost()
        .sheet(item: $editingRule) { rule in
            SMSRuleEditor(rule: rule, categories: categories)
        }
        .alert("Add a card", isPresented: $showAddCard) {
            TextField("Last 4 digits", text: $newCardDigits)
                .keyboardType(.numberPad)

            Button("Add") {
                addCard()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages between two of your own cards are treated as transfers, not spending.")
        }
        .alert("Card name", isPresented: $showRename) {
            TextField("Name", text: $cardName)

            Button("Save") {
                if let card = renamingCard {
                    cardStore.rename(card.last4, to: cardName)
                }
            }

            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Cards

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SMSGroupTitle(title: "My cards", count: cardStore.cards.count)

                Spacer(minLength: 8)

                Button {
                    Haptics.tap()
                    newCardDigits = ""
                    showAddCard = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 11.5, style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if cardStore.cards.isEmpty {
                Text("Cards appear here after the first bank message. A transfer between two of them is not counted as spending.")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .fixedSize(horizontal: false, vertical: true)
                    .smsCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(cardStore.cards) { card in
                        cardRow(card)

                        if card.id != cardStore.cards.last?.id {
                            Divider()
                        }
                    }
                }
                .smsCard(padding: 0)
            }
        }
    }

    private func cardRow(_ card: SMSCard) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayName)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)

                Text(cardCaption(card))
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    renamingCard = card
                    cardName = card.nickname
                    showRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    Haptics.tap()
                    cardStore.setOwn(card.last4, !card.isOwn)
                } label: {
                    if card.isOwn {
                        Label("Not my card", systemImage: "person.crop.circle.badge.xmark")
                    } else {
                        Label("This is my card", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }

                Button(role: .destructive) {
                    cardStore.delete(card.last4)
                    ToastCenter.shared.success(String(localized: "Card removed"))
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(Color.SubtitleText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("More"))
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
    }

    private func cardCaption(_ card: SMSCard) -> String {
        var parts = [String]()

        if !card.nickname.isEmpty {
            parts.append("*\(card.last4)")
        }

        if !card.isOwn {
            parts.append(String(localized: "Not mine"))
        }

        if let minor = card.lastBalanceMinor, let seen = card.lastSeenAt {
            let value = MoneyFormat.number(Double(minor) / 100, fractionDigits: 2)
            let currency = card.lastBalanceCurrency ?? ""

            parts.append(String(localized: "Balance \(value) \(currency) on \(SMSFormat.dateText(seen))"))
        }

        if parts.isEmpty {
            return String(localized: "My card")
        }

        return parts.joined(separator: ", ")
    }

    private func addCard() {
        if cardStore.add(last4: newCardDigits) {
            ToastCenter.shared.success(String(localized: "Card added"))
        } else {
            ToastCenter.shared.error(String(localized: "Enter the last 4 digits of a card that is not in the list"))
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SMSGroupTitle(title: "Rules", count: ruleStore.rules.count)
                .frame(minHeight: 44)
                .padding(.top, 6)

            if ruleStore.rules.isEmpty {
                Text("No rules yet. Pick a category for a bank message and the app remembers it for that merchant.")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .fixedSize(horizontal: false, vertical: true)
                    .smsCard()
            } else {
                if ruleStore.rules.count > 6 {
                    TextField("Search", text: $query)
                        .font(.system(.body, design: .rounded))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                let shown = shownRules
                let all = categories

                if shown.isEmpty {
                    Text("Nothing found")
                        .font(.system(.footnote, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                }

                ForEach(shown) { rule in
                    Button {
                        Haptics.tap()
                        editingRule = rule
                    } label: {
                        ruleRow(rule, category: all.first { $0.id == rule.categoryID })
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func ruleRow(_ rule: MerchantRule, category: SMSCategoryInfo?) -> some View {
        HStack(spacing: 12) {
            if rule.action == .skip {
                EmojiLogView(emoji: ">>", colour: "#8E8E93", future: true)
                    .fixedSize()
            } else if let category = category {
                EmojiLogView(emoji: category.emoji, colour: category.colour, future: false)
                    .fixedSize()
            } else {
                EmojiLogView(emoji: "?", colour: "#8E8E93", future: true)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.note.isEmpty ? rule.key : rule.note)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)

                Text(ruleCaption(rule, category: category))
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if rule.action == .categorize, rule.autoAdd {
                SMSTag(text: "Auto", systemImage: "bolt.fill", color: Color.IncomeGreen)
            }

            if rule.hits > 0 {
                Text(verbatim: "x\(rule.hits)")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(Color.SubtitleText)
            }

            Image(systemName: "chevron.forward")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)
                .accessibilityHidden(true)
        }
        .smsCard(padding: 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func ruleCaption(_ rule: MerchantRule, category: SMSCategoryInfo?) -> String {
        let side = rule.isIncome ? String(localized: "Income") : String(localized: "Expense")

        if rule.action == .skip {
            return rule.key + ", " + String(localized: "always skipped")
        }

        if let category = category {
            return rule.key + ", " + category.name
        }

        if let name = rule.categoryName, !name.isEmpty {
            // The category was deleted: the rule no longer suggests anything.
            return rule.key + ", " + String(localized: "\(name) (deleted)")
        }

        return rule.key + ", " + side
    }
}

// MARK: Editor

struct SMSRuleEditor: View {
    private enum Mode: Int {
        case ask
        case auto
        case skip
    }

    private let original: MerchantRule
    private let categories: [SMSCategoryInfo]

    @Environment(\.dismiss) private var dismiss

    @State private var key: String
    @State private var note: String
    @State private var categoryID: UUID?
    @State private var mode: Mode
    @State private var cardLast4: String?

    init(rule: MerchantRule, categories: [SMSCategoryInfo]) {
        original = rule
        self.categories = categories.filter { $0.income == rule.isIncome }

        _key = State(initialValue: rule.key)
        _note = State(initialValue: rule.note)
        _categoryID = State(initialValue: rule.categoryID)
        _cardLast4 = State(initialValue: rule.cardLast4)

        if rule.action == .skip {
            _mode = State(initialValue: .skip)
        } else {
            _mode = State(initialValue: rule.autoAdd ? .auto : .ask)
        }
    }

    private var cleanKey: String {
        MerchantMatcher.normalizedKey(key)
    }

    private var canSave: Bool {
        !cleanKey.isEmpty && (mode == .skip || categoryID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            SMSScreenHeader("Rule", closeIcon: "xmark", onClose: { dismiss() })
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    field("Words in the message", text: $key, lowercase: true)

                    Text("The rule fires when the merchant in a message starts with these words. Fewer words catch more messages.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                        .fixedSize(horizontal: false, vertical: true)

                    field("Note in the Log", text: $note, lowercase: false)

                    caption("When a message arrives")

                    VStack(spacing: 0) {
                        modeRow("Ask me", "The message waits for review with the category filled in.", .ask)
                        Divider()
                        modeRow("Add automatically", "The transaction is added without review.", .auto)
                        Divider()
                        modeRow("Always skip", "Nothing is added and nothing is shown.", .skip)
                    }
                    .smsCard(padding: 0)

                    if mode != .skip {
                        caption(original.isIncome ? "Income category" : "Expense category")

                        SMSCategoryQuickPicker(categories: categories, selectedID: categoryID) { picked in
                            categoryID = picked.id
                        }
                    }

                    let cards = SMSCardStore.shared.cards

                    if cards.count > 1 {
                        caption("Only for the card")

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                cardChip(String(localized: "Any card"), nil)

                                ForEach(cards) { card in
                                    cardChip(card.displayName, card.last4)
                                }
                            }
                        }
                    }

                    SMSPillButton(title: String(localized: "Delete rule"), systemImage: "trash", prominent: false, destructive: true) {
                        delete()
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)

            Button {
                save()
            } label: {
                Text("Save")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundColor(canSave ? Color.LightIcon : Color.SubtitleText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        canSave ? Color.DarkBackground : Color.SecondaryBackground,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.PrimaryBackground.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .toastHost()
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundColor(Color.SubtitleText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, lowercase: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)

            TextField(title, text: text)
                .font(.system(.body, design: .rounded))
                .foregroundColor(Color.PrimaryText)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(lowercase ? .never : .sentences)
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }

    private func modeRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ value: Mode) -> some View {
        Button {
            Haptics.selection()

            withAnimation(.easeInOut(duration: 0.15)) {
                mode = value
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(Color.PrimaryText)

                    Text(detail)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(Color.PrimaryText)
                    .opacity(mode == value ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    private func cardChip(_ title: String, _ last4: String?) -> some View {
        let selected = cardLast4 == last4

        return Button {
            Haptics.selection()
            cardLast4 = last4
        } label: {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(selected ? Color.LightIcon : Color.PrimaryText)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(
                    selected ? Color.DarkBackground : Color.SecondaryBackground,
                    in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard canSave else {
            Haptics.warning()
            ToastCenter.shared.error(
                cleanKey.isEmpty ? String(localized: "Type at least one word") : String(localized: "Pick a category first")
            )
            return
        }

        var rule = original

        rule.key = cleanKey
        rule.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.cardLast4 = cardLast4

        if mode == .skip {
            rule.action = .skip
            rule.autoAdd = false
        } else {
            rule.action = .categorize
            rule.autoAdd = mode == .auto

            if rule.categoryID != categoryID {
                rule.categoryID = categoryID
                rule.hits = 0
                rule.overrides = 0
            }

            rule.categoryName = categories.first { $0.id == categoryID }?.name ?? rule.categoryName
        }

        SMSRuleStore.shared.update(rule)
        dismiss()

        // Posted after the dismiss starts, so the host under the sheet draws it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ToastCenter.shared.success(String(localized: "Rule saved"))
        }
    }

    private func delete() {
        let removed = original

        SMSRuleStore.shared.delete(removed.id)
        dismiss()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ToastCenter.shared.undo(String(localized: "Rule deleted")) {
                SMSRuleStore.shared.update(removed)
            }
        }
    }
}
