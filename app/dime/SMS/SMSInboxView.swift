//
//  SMSInboxView.swift
//  dime
//
//  Review list of the bank messages: Suggestions, Transfers and cash, Unrecognised.
//  Presented as a full screen cover (see `smsInboxPresenter` in SMSRouter.swift).
//  Needs a managed object context in the environment (for the category list).
//

import CoreData
import SwiftUI

enum SMSInboxGroup {
    case suggestions
    case transfers // between own cards, and cash withdrawals: skipped by default
    case unrecognised
}

extension SMSSuggestion {
    var group: SMSInboxGroup {
        if isUnrecognised {
            return .unrecognised
        }

        if isOwnTransfer || parsed.kind == .atmWithdrawal {
            return .transfers
        }

        return .suggestions
    }

    /// Plain spending or income: the only kind a rule may add without review.
    var isPlainOperation: Bool {
        parsed.kind == .payment || parsed.kind == .topUp || parsed.kind == .refund
    }
}

private enum SMSInboxSheet: Identifiable {
    case paste(String)
    case rules
    case guide

    var id: String {
        switch self {
        case .paste: return "paste"
        case .rules: return "rules"
        case .guide: return "guide"
        }
    }
}

struct SMSInboxView: View {
    private let editScreen: ((SMSDraftRequest) -> AnyView)?

    @ObservedObject private var inbox = SMSInboxStore.shared
    @ObservedObject private var ruleStore = SMSRuleStore.shared
    @ObservedObject private var cardStore = SMSCardStore.shared
    @ObservedObject private var clipboard = SMSClipboard.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var moc

    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "order", ascending: false)])
    private var fetchedCategories: FetchedResults<Category>

    @State private var expandedID: UUID?
    @State private var autoAddChoice = [UUID: Bool]()
    @State private var editing: SMSDraftRequest?
    @State private var sheet: SMSInboxSheet?

    private let ingestor = SMSIngestor.shared

    /// `editScreen` builds the full entry screen for a message. It must call
    /// `SMSIngestor.shared.completeEdit(suggestionID:transactionID:)` after a save.
    /// Without it the cards have no edit button.
    init(editScreen: ((SMSDraftRequest) -> AnyView)? = nil) {
        self.editScreen = editScreen
    }

    private var categories: [SMSCategoryInfo] {
        fetchedCategories.compactMap { SMSCategoryInfo($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if inbox.pending.isEmpty {
                emptyState
            } else {
                list(pending: inbox.pending, categories: categories)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.PrimaryBackground.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .toastHost()
        .sheet(item: $sheet) { item in
            sheetContent(item)
                .environment(\.managedObjectContext, moc)
        }
        .fullScreenCover(item: $editing) { request in
            if let editScreen = editScreen {
                editScreen(request)
                    .environment(\.managedObjectContext, moc)
            }
        }
        .onAppear {
            inbox.reloadIfNeeded()
            clipboard.check()
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: SMSInboxSheet) -> some View {
        switch item {
        case let .paste(text):
            SMSPasteImportView(initialText: text)
        case .rules:
            SMSRulesView()
        case .guide:
            SMSSetupGuideView()
        }
    }

    // MARK: Header

    private var header: some View {
        SMSScreenHeader("Bank messages", closeIcon: "xmark", onClose: { dismiss() }) {
            Menu {
                Button {
                    sheet = .paste("")
                } label: {
                    Label("Paste messages", systemImage: "doc.on.clipboard")
                }

                Button {
                    sheet = .rules
                } label: {
                    Label("Rules and cards", systemImage: "slider.horizontal.3")
                }

                Button {
                    sheet = .guide
                } label: {
                    Label("Set up automation", systemImage: "wand.and.stars")
                }
            } label: {
                SMSRoundIcon(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("More"))
        }
    }

    // MARK: List

    private func list(pending: [SMSSuggestion], categories: [SMSCategoryInfo]) -> some View {
        var byID = [UUID: SMSCategoryInfo]()

        for category in categories {
            byID[category.id] = category
        }

        let suggestions = pending.filter { $0.group == .suggestions }
        let transfers = pending.filter { $0.group == .transfers }
        let unrecognised = pending.filter { $0.group == .unrecognised }
        let matched = suggestions.filter { isMatched($0, byID) }

        return ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if clipboard.state != .none {
                    clipboardChip
                }

                if !suggestions.isEmpty {
                    groupHeader("Suggestions", count: suggestions.count) {
                        if matched.count > 1 {
                            groupButton(String(localized: "Confirm all matched (\(matched.count))")) {
                                confirmAll(matched, byID)
                            }
                        }
                    }

                    ForEach(suggestions) { suggestion in
                        card(suggestion, byID: byID, categories: categories)
                    }
                }

                if !transfers.isEmpty {
                    groupHeader("Transfers and cash", count: transfers.count) {
                        if transfers.count > 1 {
                            groupButton(String(localized: "Skip all")) {
                                skip(transfers)
                            }
                        }
                    }

                    Text("Money moved between your own cards and cash from an ATM is not spending. Skipped unless you log it.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(transfers) { suggestion in
                        card(suggestion, byID: byID, categories: categories)
                    }
                }

                if !unrecognised.isEmpty {
                    groupHeader("Unrecognised", count: unrecognised.count) {
                        if unrecognised.count > 1 {
                            groupButton(String(localized: "Dismiss all")) {
                                skip(unrecognised)
                            }
                        }
                    }

                    ForEach(unrecognised) { suggestion in
                        card(suggestion, byID: byID, categories: categories)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: pending.map { $0.id })
        }
    }

    private func groupHeader<Trailing: View>(
        _ title: LocalizedStringKey, count: Int, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            SMSGroupTitle(title: title, count: count)

            Spacer(minLength: 8)

            trailing()
        }
        .frame(minHeight: 44)
        .padding(.top, 6)
    }

    private func groupButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(Color.PrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 11.5, style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func card(_ suggestion: SMSSuggestion, byID: [UUID: SMSCategoryInfo], categories: [SMSCategoryInfo]) -> some View {
        let category = suggestion.suggestedCategoryID.flatMap { byID[$0] }
        let ruleAutoAdd = ruleStore.rule(withID: suggestion.matchedRuleID)?.autoAdd ?? false

        return SMSSuggestionCard(
            suggestion: suggestion,
            category: category,
            categories: categories.filter { $0.income == suggestion.isIncome },
            subtitle: SMSFormat.subtitle(suggestion.parsed, cards: cardStore),
            autoAdd: autoAddChoice[suggestion.id] ?? ruleAutoAdd,
            expanded: expandedID == suggestion.id,
            canEdit: editScreen != nil
        ) { action in
            handle(action, for: suggestion, category: category)
        }
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.94))))
    }

    /// Has a category and nothing that asks for a second look.
    private func isMatched(_ suggestion: SMSSuggestion, _ byID: [UUID: SMSCategoryInfo]) -> Bool {
        guard let id = suggestion.suggestedCategoryID, byID[id] != nil else {
            return false
        }

        return suggestion.flags.isEmpty && suggestion.isPlainOperation
    }

    private var clipboardChip: some View {
        HStack(spacing: 4) {
            Button {
                pasteFromClipboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))

                    Text("Paste from clipboard")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundColor(Color.PrimaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                clipboard.markHandled()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundColor(Color.SubtitleText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            Image(systemName: "tray")
                .font(.system(size: 54, weight: .regular, design: .rounded))
                .foregroundColor(Color.SubtitleText)
                .padding(.bottom, 14)
                .accessibilityHidden(true)

            Text("No messages waiting")
                .font(.system(.title2, design: .rounded).weight(.medium))
                .foregroundColor(Color.PrimaryText)
                .multilineTextAlignment(.center)

            Text("New bank messages show up here. Paste some, or let Shortcuts send them as they arrive.")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 18)

            if clipboard.state != .none {
                SMSPillButton(title: String(localized: "Paste from clipboard"), systemImage: "doc.on.clipboard") {
                    pasteFromClipboard()
                }
            } else {
                SMSPillButton(title: String(localized: "Paste messages"), systemImage: "doc.on.clipboard") {
                    Haptics.tap()
                    sheet = .paste("")
                }
            }

            Button {
                Haptics.tap()
                sheet = .guide
            } label: {
                Text("Set up automation")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.SubtitleText)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func handle(_ action: SMSCardAction, for suggestion: SMSSuggestion, category: SMSCategoryInfo?) {
        switch action {
        case .confirm:
            confirm(suggestion, category)

        case .skip:
            skip([suggestion])

        case .edit:
            Haptics.tap()
            editing = ingestor.draftRequest(for: suggestion)

        case .toggleExpanded:
            Haptics.tap()

            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expandedID = expandedID == suggestion.id ? nil : suggestion.id
            }

        case let .pick(picked):
            ingestor.setCategory(picked.id, for: suggestion.id)

        case let .setAutoAdd(value):
            autoAddChoice[suggestion.id] = value

        case let .setDirection(direction):
            Haptics.selection()
            ingestor.setDirection(direction, for: suggestion.id)

        case .alreadyLogged:
            let token = ingestor.skip([suggestion], as: .duplicate)

            ToastCenter.shared.undo(String(localized: "Marked as already logged")) {
                undo(token)
            }

        case let .setOwnTransfer(value):
            Haptics.tap()

            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                ingestor.setOwnTransfer(value, for: suggestion.id)
            }

        case .alwaysSkip:
            let token = ingestor.alwaysSkip(suggestion)
            let name = SMSFormat.title(suggestion.parsed)

            ToastCenter.shared.undo(String(localized: "Will always skip \(name)")) {
                undo(token)
            }

        case .copy:
            clipboard.copy(suggestion.rawText)
            ToastCenter.shared.success(String(localized: "Copied"))
        }
    }

    private func confirm(_ suggestion: SMSSuggestion, _ category: SMSCategoryInfo?) {
        guard let category = category else {
            // Nothing to add to yet: open the picker instead of failing silently.
            Haptics.warning()

            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expandedID = suggestion.id
            }

            return
        }

        let confirmation = SMSConfirmation(suggestion: suggestion, category: category, autoAdd: autoAddChoice[suggestion.id])

        do {
            let token = try ingestor.confirm([confirmation])

            autoAddChoice[suggestion.id] = nil

            if expandedID == suggestion.id {
                expandedID = nil
            }

            ToastCenter.shared.undo(String(localized: "Added to \(category.name)")) {
                undo(token)
            }
        } catch {
            ToastCenter.shared.error(String(localized: "Couldn't add. Try again."))
        }
    }

    private func confirmAll(_ suggestions: [SMSSuggestion], _ byID: [UUID: SMSCategoryInfo]) {
        var confirmations = [SMSConfirmation]()

        for suggestion in suggestions {
            if let id = suggestion.suggestedCategoryID, let category = byID[id] {
                confirmations.append(SMSConfirmation(suggestion: suggestion, category: category, autoAdd: nil))
            }
        }

        guard !confirmations.isEmpty else {
            return
        }

        do {
            let token = try ingestor.confirm(confirmations)

            ToastCenter.shared.undo(String(localized: "Added: \(token.transactionIDs.count)")) {
                undo(token)
            }
        } catch {
            ToastCenter.shared.error(String(localized: "Couldn't add. Try again."))
        }
    }

    private func skip(_ suggestions: [SMSSuggestion]) {
        guard !suggestions.isEmpty else {
            return
        }

        let token = ingestor.skip(suggestions)
        let title = suggestions.count == 1
            ? String(localized: "Skipped")
            : String(localized: "Skipped: \(suggestions.count)")

        ToastCenter.shared.undo(title) {
            undo(token)
        }
    }

    private func undo(_ token: SMSUndoToken) {
        do {
            try ingestor.undo(token)
        } catch {
            ToastCenter.shared.error(String(localized: "Couldn't undo. Try again."))
        }
    }

    // The text is read only here, after a tap: this is the moment iOS may ask about pasting.
    private func pasteFromClipboard() {
        Haptics.tap()

        guard let text = clipboard.read(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastCenter.shared.error(String(localized: "No bank messages found"))
            return
        }

        sheet = .paste(text)
    }
}

// MARK: Card

enum SMSCardAction {
    case confirm
    case skip
    case edit
    case toggleExpanded
    case pick(SMSCategoryInfo)
    case setAutoAdd(Bool)
    case setDirection(SMSDirection)
    case alreadyLogged
    case setOwnTransfer(Bool)
    case alwaysSkip
    case copy
}

struct SMSSuggestionCard: View {
    let suggestion: SMSSuggestion
    let category: SMSCategoryInfo?
    let categories: [SMSCategoryInfo]
    let subtitle: String
    let autoAdd: Bool
    let expanded: Bool
    let canEdit: Bool
    let onAction: (SMSCardAction) -> Void

    // The reset transaction makes the card spring back when the finger lifts; while dragging it follows 1:1.
    // SwiftUI. is required: a bare Transaction is the Core Data entity of this module.
    @GestureState(resetTransaction: SwiftUI.Transaction(animation: .spring(response: 0.3, dampingFraction: 0.82)))
    private var dragOffset: CGFloat = 0
    @State private var axis = SMSSwipeAxis()
    @State private var armed = 0
    @State private var showsOriginal = false

    init(
        suggestion: SMSSuggestion, category: SMSCategoryInfo?, categories: [SMSCategoryInfo], subtitle: String,
        autoAdd: Bool, expanded: Bool, canEdit: Bool, onAction: @escaping (SMSCardAction) -> Void
    ) {
        self.suggestion = suggestion
        self.category = category
        self.categories = categories
        self.subtitle = subtitle
        self.autoAdd = autoAdd
        self.expanded = expanded
        self.canEdit = canEdit
        self.onAction = onAction
    }

    private static let swipeThreshold: CGFloat = 96

    private struct TagInfo: Identifiable {
        let id: String
        let text: LocalizedStringKey
        var icon: String?
        var color: Color = Color.SubtitleText
    }

    private var parsed: ParsedSMS {
        suggestion.parsed
    }

    private var group: SMSInboxGroup {
        suggestion.group
    }

    private var isDuplicate: Bool {
        suggestion.has(.possibleDuplicate)
    }

    private var canLearn: Bool {
        !parsed.merchantKey.isEmpty && parsed.direction != nil && !suggestion.isOwnTransfer && suggestion.isPlainOperation
    }

    private var tags: [TagInfo] {
        var result = [TagInfo]()

        if isDuplicate {
            result.append(TagInfo(id: "duplicate", text: "Possible duplicate", icon: "doc.on.doc", color: Color.AlertRed))
        }

        if suggestion.isOwnTransfer {
            result.append(TagInfo(id: "own", text: "Between own cards", icon: "arrow.left.arrow.right"))
        } else if parsed.kind == .transfer {
            result.append(TagInfo(id: "transfer", text: "Transfer?", icon: "arrow.left.arrow.right"))
        }

        if parsed.kind == .atmWithdrawal {
            result.append(TagInfo(id: "cash", text: "Cash withdrawal", icon: "banknote"))
        }

        if parsed.kind == .refund {
            result.append(TagInfo(id: "refund", text: "Refund"))
        }

        if suggestion.has(.foreignCurrency) {
            result.append(TagInfo(id: "currency", text: "Other currency", color: Color.AlertRed))
        }

        if suggestion.has(.lowConfidence) || (parsed.direction == nil && parsed.amountMinor != nil) {
            result.append(TagInfo(id: "check", text: "Check the details"))
        }

        if suggestion.categorySource == "history", category != nil {
            result.append(TagInfo(id: "history", text: "From your history"))
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow

            if group == .unrecognised {
                originalText
            } else {
                let shown = tags

                if !shown.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shown) { tag in
                                SMSTag(text: tag.text, systemImage: tag.icon, color: tag.color)
                            }
                        }
                    }
                }

                chipRow

                if expanded {
                    pickerBlock
                }

                if showsOriginal {
                    originalText
                }
            }

            actions
        }
        .smsCard()
        .offset(x: dragOffset)
        .background(swipeBackground)
        .simultaneousGesture(swipe)
        .accessibilityAction(named: Text("Skip")) {
            onAction(.skip)
        }
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: 12) {
            if let category = category, group != .unrecognised {
                EmojiLogView(emoji: category.emoji, colour: category.colour, future: false)
                    .fixedSize()
            } else {
                EmojiLogView(emoji: "?", colour: "#8E8E93", future: true)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(group == .unrecognised ? String(localized: "Unrecognised message") : SMSFormat.title(parsed))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)

                Text(group == .unrecognised ? SMSFormat.dateText(suggestion.receivedAt) : subtitle)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if group != .unrecognised {
                amount
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var amount: some View {
        if SMSFormat.isForeign(parsed) || parsed.direction == nil {
            // Not the app currency, or the direction is unknown: plain text, no app symbol or sign.
            Text(SMSFormat.amountText(parsed))
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundColor(Color.PrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            AmountText(
                SMSIngestor.amount(for: parsed), role: .row, sign: suggestion.isIncome ? .plus : .minus, fit: .fullOnly,
                color: suggestion.isIncome ? Color.IncomeGreen : Color.PrimaryText
            )
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            Button {
                onAction(.toggleExpanded)
            } label: {
                SMSCategoryChip(category: category, showsChevron: true)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose category"))
            .accessibilityValue(Text(category?.name ?? String(localized: "Not chosen")))

            Spacer(minLength: 8)

            Menu {
                if suggestion.isOwnTransfer {
                    Button {
                        onAction(.setOwnTransfer(false))
                    } label: {
                        Label("Not between my cards", systemImage: "arrow.uturn.backward")
                    }
                } else if parsed.direction != nil {
                    Button {
                        onAction(.setOwnTransfer(true))
                    } label: {
                        Label("It's my own card", systemImage: "arrow.left.arrow.right")
                    }
                }

                if !parsed.merchantKey.isEmpty {
                    Button {
                        onAction(.alwaysSkip)
                    } label: {
                        Label("Always skip this merchant", systemImage: "forward.end")
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsOriginal.toggle()
                    }
                } label: {
                    Label(
                        showsOriginal ? LocalizedStringKey("Hide original message") : LocalizedStringKey("Show original message"),
                        systemImage: "text.bubble"
                    )
                }

                Button {
                    onAction(.copy)
                } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
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
    }

    private var pickerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if parsed.direction == nil || parsed.kind == .unknown {
                HStack(spacing: 8) {
                    directionButton("Expense", .expense)
                    directionButton("Income", .income)
                }
            }

            SMSCategoryQuickPicker(categories: categories, selectedID: category?.id) { picked in
                onAction(.pick(picked))
            }

            if canLearn, category != nil {
                SMSToggleRow(
                    title: "Always for this merchant",
                    caption: "Next time it is added without review",
                    isOn: autoAdd
                ) { value in
                    onAction(.setAutoAdd(value))
                }
            }
        }
        .transition(.opacity)
    }

    private func directionButton(_ title: LocalizedStringKey, _ direction: SMSDirection) -> some View {
        let selected = parsed.direction == direction

        return Button {
            onAction(.setDirection(direction))
        } label: {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(selected ? Color.LightIcon : Color.PrimaryText)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(
                    selected ? Color.DarkBackground : Color.PrimaryBackground,
                    in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var originalText: some View {
        Text(suggestion.rawText)
            .font(.system(.footnote, design: .rounded))
            .foregroundColor(Color.SubtitleText)
            .lineLimit(group == .unrecognised ? 4 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var actions: some View {
        switch group {
        case .suggestions:
            HStack(spacing: 8) {
                if !isDuplicate {
                    SMSIconButton(systemName: "xmark", label: "Skip") {
                        onAction(.skip)
                    }
                }

                if canEdit {
                    SMSIconButton(systemName: "pencil", label: "Edit") {
                        onAction(.edit)
                    }
                }

                Spacer(minLength: 0)

                if isDuplicate {
                    SMSPillButton(title: String(localized: "Add anyway"), prominent: false) {
                        onAction(.confirm)
                    }

                    SMSPillButton(title: String(localized: "Already logged"), systemImage: "checkmark") {
                        onAction(.alreadyLogged)
                    }
                } else {
                    SMSPillButton(
                        title: category == nil ? String(localized: "Choose category") : String(localized: "Add"),
                        systemImage: category == nil ? nil : "checkmark"
                    ) {
                        onAction(.confirm)
                    }
                }
            }

        case .transfers:
            HStack(spacing: 8) {
                if canEdit {
                    SMSIconButton(systemName: "pencil", label: "Edit") {
                        onAction(.edit)
                    }
                }

                Spacer(minLength: 0)

                SMSPillButton(title: logTitle, prominent: false) {
                    onAction(.confirm)
                }

                SMSPillButton(title: String(localized: "Skip"), systemImage: "xmark") {
                    onAction(.skip)
                }
            }

        case .unrecognised:
            HStack(spacing: 8) {
                SMSIconButton(systemName: "doc.on.doc", label: "Copy text") {
                    onAction(.copy)
                }

                Spacer(minLength: 0)

                if canEdit {
                    SMSPillButton(title: String(localized: "Add manually"), prominent: false) {
                        onAction(.edit)
                    }
                }

                SMSPillButton(title: String(localized: "Dismiss"), systemImage: "xmark") {
                    onAction(.skip)
                }
            }
        }
    }

    private var logTitle: String {
        if parsed.kind == .atmWithdrawal {
            return String(localized: "Log as cash")
        }

        return suggestion.isIncome ? String(localized: "Log as income") : String(localized: "Log as expense")
    }

    // MARK: Swipe

    private static func side(of width: CGFloat) -> Int {
        if width > swipeThreshold {
            return 1
        }

        return width < -swipeThreshold ? -1 : 0
    }

    private var swipeBackground: some View {
        let progress = min(1, abs(dragOffset) / Self.swipeThreshold)
        let adding = dragOffset > 0

        return RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill((adding ? Color.IncomeGreen : Color.AlertRed).opacity(0.23))
            .overlay(alignment: adding ? .leading : .trailing) {
                Image(systemName: adding ? "checkmark" : "xmark")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundColor(adding ? Color.IncomeGreen : Color.AlertRed)
                    .scaleEffect(progress >= 1 ? 1.15 : 0.9)
                    .padding(.horizontal, 22)
            }
            .opacity(dragOffset == 0 ? 0 : Double(progress))
            .accessibilityHidden(true)
    }

    // Right: add (or open the picker when there is no category yet). Left: skip.
    // An unrecognised message has nothing to add, so it only swipes left.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                guard axis.isHorizontal(value) else {
                    return
                }

                let width = value.translation.width

                state = group == .unrecognised ? min(0, width) : width
            }
            .onChanged { value in
                guard axis.isHorizontal(value) else {
                    return
                }

                var now = Self.side(of: value.translation.width)

                if group == .unrecognised, now > 0 {
                    now = 0
                }

                if now != armed {
                    armed = now

                    if now != 0 {
                        Haptics.tap()
                    }
                }
            }
            .onEnded { value in
                let horizontal = axis.isHorizontal(value)

                axis.reset()
                armed = 0

                guard horizontal else {
                    return
                }

                let side = Self.side(of: value.translation.width)

                if side > 0, group != .unrecognised {
                    onAction(isDuplicate ? .alreadyLogged : .confirm)
                } else if side < 0 {
                    onAction(.skip)
                }
            }
    }
}
