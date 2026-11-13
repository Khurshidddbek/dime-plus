//
//  TransactionView.swift
//  xpenz
//
//  Created by Rafael Soh on 14/5/22.
//

import CoreData
import Foundation
import Popovers
import SwiftUI

// What "unsaved input" is compared against.
private struct EntrySnapshot: Equatable {
    var amount: AmountInput
    var note: String
    var categoryID: NSManagedObjectID?
    var income: Bool
    // nil while a new entry still follows the clock.
    var date: Date?
    var repeatType: Int
    var repeatCoefficient: Int
}

struct TransactionView: View {
    @FetchRequest(sortDescriptors: [SortDescriptor(\.order, order: .reverse)], predicate: NSPredicate(format: "income = %d", false))
    private var expenseCategories: FetchedResults<Category>
    @FetchRequest(sortDescriptors: [SortDescriptor(\.order, order: .reverse)], predicate: NSPredicate(format: "income = %d", true))
    private var incomeCategories: FetchedResults<Category>

    @EnvironmentObject var dataController: DataController
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) var systemColorScheme
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    @AppStorage("topEdge", store: UserDefaults.appGroup) var topEdge: Double = 20
    @AppStorage("colourScheme", store: UserDefaults.appGroup) var colourScheme: Int = 0
    @AppStorage("currency", store: UserDefaults.appGroup) var currency: String = MoneyFormat.defaultCurrencyCode
    @AppStorage("showCents", store: UserDefaults.appGroup) private var showCents: Bool = true
    @AppStorage("currencySymbolOverride", store: UserDefaults.appGroup) private var symbolOverride: String = ""
    // New key on purpose: the old Feature Lab flag defaulted to off, suggestions are now on unless switched off.
    @AppStorage("noteSuggestionsEnabled", store: UserDefaults.appGroup) private var suggestionsEnabled: Bool = true

    // The row this screen was opened for. Stays set even after the row is deleted from here.
    let toEdit: Transaction?
    private let onFinish: ((Bool, UUID?) -> Void)?

    @State private var editTarget: Transaction?
    @State private var amount: AmountInput
    @State private var note: String
    @State var category: Category?
    @State var income: Bool
    @State private var date: Date
    // A new entry is stamped with the time of the confirm tap unless the user picked a day or a time.
    @State private var dayEdited: Bool
    @State private var timeEdited: Bool
    @State private var repeatType: Int
    @State private var repeatCoefficient: Int
    @State private var baseline: EntrySnapshot

    @State private var showRecurring = false
    @State var showPicker = false
    @State var showCategoryPicker = false
    @State var showCategorySheet = false
    @State var showingDatePicker = false
    @State private var showingTimePicker = false
    @State private var showDiscardDialog = false

    @State var textFieldFocused: Bool = false
    // True once the category is the user's choice: picked by hand, or the one the screen was opened with.
    @State private var categoryPickedManually: Bool
    @State private var lastExpenseCategory: Category?
    @State private var lastIncomeCategory: Category?

    @State private var amountShake = 0
    @State private var amountError = false
    @State private var categoryShake = 0
    @State private var categoryError = false
    @State private var categoryPulse = false

    @State private var isSubmitting = false
    @State private var editSaveFailed = false
    @State private var finishReported = false

    @StateObject private var suggestions = NoteSuggestionIndex()

    let repeatOverlays = ["D", "W", "M"]

    // MARK: Derived values

    var boldText: Bool {
        UIAccessibility.isBoldTextEnabled
    }

    var darkMode: Bool {
        (colourScheme == 0 && systemColorScheme == .dark) || colourScheme == 2
    }

    var backgroundColor: Color {
        if darkMode {
            return Color("AlwaysDarkBackground")
        } else {
            return Color("AlwaysLightBackground")
        }
    }

    var repeatButtonAccessibility: String {
        if repeatType == 1 {
            return String(localized: "transaction recurs daily, button to edit recurring duration")
        } else if repeatType == 2 {
            return String(localized: "transaction recurs weekly, button to edit recurring duration")
        } else if repeatType == 3 {
            return String(localized: "transaction recurs monthly, button to edit recurring duration")
        } else {
            return String(localized: "button to make transaction recurring")
        }
    }

    var widthOfCategoryButton: CGFloat {
        let fontSize = UIFont.getBodyFontSize(dynamicTypeSize: dynamicTypeSize)
        let widest = max(
            String(localized: "Category").widthOfRoundedString(size: fontSize, weight: .semibold),
            String(localized: "Close").widthOfRoundedString(size: fontSize, weight: .semibold)
        )

        return widest + 50
    }

    var capsuleWidth: CGFloat {
        if dynamicTypeSize > .xLarge {
            return 120
        } else {
            return 100
        }
    }

    private var moneySettings: MoneySettings {
        MoneySettings.resolve(currency: currency, showCents: showCents, symbolOverride: symbolOverride)
    }

    private var sideCategories: [Category] {
        income ? Array(incomeCategories) : Array(expenseCategories)
    }

    // Most used first, topped up with the rest in the picker order.
    private var quickCategories: [Category] {
        let all = sideCategories
        var result: [Category] = []

        for id in suggestions.frequentCategoryIDs(income: income) {
            if let match = all.first(where: { $0.id == id }) {
                result.append(match)
            }

            if result.count == 8 {
                return result
            }
        }

        for item in all where !result.contains(item) {
            result.append(item)

            if result.count == 8 {
                break
            }
        }

        return result
    }

    private var showsCategoryChips: Bool {
        category == nil && !showCategoryPicker && !sideCategories.isEmpty
    }

    private var showsMagnitudeHint: Bool {
        amount.value >= 1_000_000
    }

    private var isFutureDate: Bool {
        date > Date.now
    }

    private var dayLabel: String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return String(localized: "Today")
        }

        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }

        if calendar.component(.year, from: date) != calendar.component(.year, from: Date.now) {
            return Fmt.string(.dayMonthShortYear, from: date)
        }

        return Fmt.string(.shortWeekdayDayMonth, from: date)
    }

    private var cleanedNote: String {
        note.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentSnapshot: EntrySnapshot {
        EntrySnapshot(
            amount: amount,
            note: cleanedNote,
            categoryID: category?.objectID,
            income: income,
            date: TransactionView.snapshotDate(date, isEdit: editTarget != nil, dayEdited: dayEdited, timeEdited: timeEdited),
            repeatType: repeatType,
            repeatCoefficient: repeatCoefficient
        )
    }

    // Only what the user fixed counts: nothing, the day, or the exact moment.
    private static func snapshotDate(_ date: Date, isEdit: Bool, dayEdited: Bool, timeEdited: Bool) -> Date? {
        if isEdit || timeEdited {
            return date
        }

        return dayEdited ? Calendar.current.startOfDay(for: date) : nil
    }

    private static func isUsable(_ category: Category?) -> Category? {
        guard let category, !category.isDeleted, category.managedObjectContext != nil else { return nil }

        return category
    }

    private var isDirty: Bool {
        currentSnapshot != baseline
    }

    // Past notes for the chips. In memory only, nothing is fetched while typing.
    private var visibleSuggestions: [NoteSuggestion] {
        guard suggestionsEnabled, textFieldFocused else { return [] }

        return suggestions.matches(note, income: income)
    }

    // MARK: Body

    var body: some View {
        GeometryReader { proxy in
            content(size: proxy.size)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .ignoresSafeArea(.keyboard, edges: .all)
        .frame(maxHeight: .infinity)
        .background(Color.PrimaryBackground)
        .edgesIgnoringSafeArea(.all)
        .interactiveDismissDisabled(isDirty)
        .onChange(of: textFieldFocused) { _, focused in
            noteFocusChanged(focused)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshUntouchedDate()
            }
        }
        .onChange(of: showCategorySheet) { _, shown in
            // The selected category can be deleted in the category sheet.
            if !shown, category != nil, TransactionView.isUsable(category) == nil {
                category = nil
                categoryPickedManually = false
            }
        }
        .onAppear {
            Haptics.prepare()
            // Once per presentation: the index ignores further calls.
            suggestions.load(from: dataController)
        }
        .sheet(isPresented: $showCategorySheet) {
            CategoryView(mode: .transaction, income: income)
        }
        .sheet(isPresented: $showPicker) {
            CustomRecurringView(
                repeatType: $repeatType, repeatCoefficient: $repeatCoefficient, showPicker: $showPicker
            )
            .presentationDetents([.height(230)])
        }
        .sheet(isPresented: $showingTimePicker) {
            EntryTimePickerSheet(date: timeBinding)
                .presentationDetents([.height(300)])
        }
        .confirmationDialog(discardTitle, isPresented: $showDiscardDialog, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                revertFailedEdit()
                report(saved: false, id: nil)
                dismiss()
            }

            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var discardTitle: Text {
        editTarget == nil ? Text("Discard this entry?") : Text("Discard changes?")
    }

    private func content(size: CGSize) -> some View {
        let matches = visibleSuggestions
        let showingNotePicker = !matches.isEmpty

        return VStack(spacing: 8) {
            header

            amountAndNote

            if showingNotePicker {
                NoteSuggestionChips(
                    suggestions: matches,
                    categoryFor: { resolveCategory(for: $0) },
                    onPick: { applySuggestion($0) }
                )
            } else {
                if showsCategoryChips {
                    CategoryChipsRow(categories: quickCategories) { picked in
                        pickCategory(picked)
                    }
                }

                dateAndCategoryRow
            }

            bottomBlock(showingNotePicker: showingNotePicker)
        }
        .padding(17)
        .frame(width: size.width, height: size.height)
        .background(Color.PrimaryBackground)
        .onTapGesture {
            hideKeyboard()
        }
        .overlay {
            datePickerOverlay
        }
        .overlay(alignment: .top) {
            // The screen ignores the safe area, the header uses the same saved inset.
            ToastHost()
                .padding(.top, topEdge)
        }
    }

    // MARK: Header

    private var header: some View {
        typePicker
            .frame(maxWidth: .infinity)
            .overlay {
                headerButtons
            }
            .padding(.top, topEdge)
    }

    private var typePicker: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.SecondaryBackground)
                .frame(width: capsuleWidth)
                .offset(x: income ? capsuleWidth : 0)

            HStack(spacing: 0) {
                typeLabel("Expense", selected: !income) {
                    setIncome(false)
                }

                typeLabel("transaction-view-income-picker", selected: income) {
                    setIncome(true)
                }
            }
        }
        .padding(3)
        .fixedSize(horizontal: true, vertical: true)
        .overlay(Capsule().stroke(Color.Outline.opacity(0.4), lineWidth: 1.3))
    }

    private func typeLabel(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .foregroundColor(selected ? Color.PrimaryText : Color.SubtitleText)
            .padding(6)
            .frame(width: capsuleWidth)
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func circleIcon(_ name: String, tint: Color, background: Color) -> some View {
        Image(systemName: name)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundColor(tint)
            .padding(7)
            .background(background, in: Circle())
            // Larger hit area without moving the 30 pt circle.
            .padding(7)
            .contentShape(Rectangle())
            .padding(-7)
    }

    private var headerButtons: some View {
        HStack {
            Button {
                close()
            } label: {
                circleIcon("xmark", tint: Color.SubtitleText, background: Color.SecondaryBackground)
            }
            .accessibilityLabel(Text("Close"))

            Spacer()

            if editTarget != nil {
                Button {
                    deleteEdited()
                } label: {
                    circleIcon("trash.fill", tint: Color.AlertRed, background: Color.AlertRed.opacity(0.23))
                }
                .accessibilityLabel("delete transaction")
            }

            repeatButton
        }
        .frame(maxWidth: .infinity)
    }

    private var repeatButton: some View {
        Button {
            hideKeyboard()
            showRecurring = true
        } label: {
            if repeatType > 0 {
                Image(systemName: "repeat")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .overlay(alignment: .topTrailing) {
                        Text(repeatOverlays[min(repeatType, repeatOverlays.count) - 1])
                            .font(.system(size: 6, weight: .black, design: .rounded))
                            .foregroundColor(Color.IncomeGreen)
                            .frame(width: 10, alignment: .leading)
                            .offset(x: 5.7, y: 1.5)
                    }
                    .foregroundColor(Color.IncomeGreen)
                    .padding(7)
                    .background(Color.IncomeGreen.opacity(0.23), in: Circle())
                    .contentShape(Circle())
            } else {
                Image(systemName: "repeat")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.SubtitleText)
                    .padding(7)
                    .background(Color.SecondaryBackground, in: Circle())
                    .contentShape(Circle())
            }
        }
        .accessibilityRemoveTraits(.isButton)
        .accessibilityLabel(repeatButtonAccessibility)
        .popover(
            present: $showRecurring,
            attributes: {
                $0.position = .absolute(
                    originAnchor: .bottom,
                    popoverAnchor: .top
                )
                $0.rubberBandingMode = .none
                $0.sourceFrameInset = UIEdgeInsets(top: 0, left: 0, bottom: -10, right: 0)
                $0.presentation.animation = .easeInOut(duration: 0.2)
                $0.dismissal.animation = .easeInOut(duration: 0.3)
            }
        ) {
            RecurringPickerView(
                repeatType: $repeatType, repeatCoefficient: $repeatCoefficient,
                showMenu: $showRecurring, showPicker: $showPicker)
        } background: {
            backgroundColor.opacity(0.6)
        }
    }

    // MARK: Amount and note

    private var amountAndNote: some View {
        VStack(spacing: 8) {
            EntryAmountDisplay(amount: $amount, shake: amountShake, isError: amountError) {
                rejectInput()
            }

            if showsMagnitudeHint {
                // Second reading of a long number: a wrong count of zeros shows up here.
                Text(MoneyFormat.compact(amount.value, settings: moneySettings))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)
                    .padding(4)
                    .padding(.horizontal, 7)
                    .background(Color.SecondaryBackground, in: Capsule())
                    .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.9)))
            }

            NoteView(note: $note, focused: $textFieldFocused)
        }
        .animation(.easeOut(duration: 0.15), value: showsMagnitudeHint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Date and category row

    private var dateAndCategoryRow: some View {
        HStack(spacing: 8) {
            datePill
            categoryPill
        }
        .padding(.bottom, 5)
    }

    private var datePill: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Group {
                    if isFutureDate {
                        Image(systemName: "rays")
                            // Indefinite form: a value trigger would never change inside this branch.
                            .symbolEffect(
                                .variableColor.iterative.dimInactiveLayers.nonReversing,
                                options: .repeating)
                    } else {
                        Image(systemName: "calendar")
                    }
                }
                .foregroundColor(Color.SubtitleText)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))

                Text(dayLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 8.5)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                hideKeyboard()
                showingDatePicker = true
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)

            Rectangle()
                .fill(Color.Outline)
                .frame(width: 1.5, height: 18)

            Text(Fmt.time(date))
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 8.5)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
                .onTapGesture {
                    hideKeyboard()
                    showingTimePicker = true
                }
                .accessibilityAddTraits(.isButton)
        }
        .font(.system(.body, design: .rounded).weight(.semibold))
        .foregroundColor(Color.PrimaryText)
        .overlay(
            RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                .strokeBorder(Color.Outline, lineWidth: 1.5)
        )
    }

    private var categoryPill: some View {
        Group {
            if sideCategories.isEmpty {
                emptyCategoryLabel(icon: "plus")
            } else if showCategoryPicker {
                closePickerLabel
            } else if let chosen = category {
                chosenCategoryLabel(chosen)
            } else {
                emptyCategoryLabel(icon: "circle.grid.2x2")
                    .frame(width: widthOfCategoryButton)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            categoryPillTapped()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func emptyCategoryLabel(icon: String) -> some View {
        HStack(spacing: 5.5) {
            Image(systemName: icon)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))

            Text("Category")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
        }
        .padding(.vertical, 8.5)
        .padding(.horizontal, 10)
        .frame(minHeight: 40)
        .foregroundColor(categoryError ? Color.AlertRed : Color.SubtitleText)
        .background(
            categoryError ? Color.AlertRed.opacity(0.23) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                .strokeBorder(categoryError ? Color.AlertRed : Color.Outline, lineWidth: 1.5)
        )
        .modifier(EntryShakeEffect(animatableData: CGFloat(categoryShake)))
        .animation(.linear(duration: 0.35), value: categoryShake)
    }

    private var closePickerLabel: some View {
        Text("Close")
            .font(.system(.body, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .padding(.vertical, 8.5)
            .padding(.horizontal, 10)
            .frame(width: widthOfCategoryButton)
            .frame(minHeight: 40)
            .foregroundColor(Color.AlertRed)
            .background(
                Color.AlertRed.opacity(0.23),
                in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
            )
    }

    private func chosenCategoryLabel(_ chosen: Category) -> some View {
        HStack(spacing: 5) {
            Text(chosen.wrappedEmoji)
                .font(.system(.footnote, design: .rounded).weight(.semibold))

            Text(chosen.wrappedName)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
        }
        .padding(.vertical, 8.5)
        .padding(.horizontal, 10)
        .frame(minHeight: 40)
        .foregroundColor(Color(hex: chosen.wrappedColour))
        .background(
            Color(hex: chosen.wrappedColour).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
        )
        .scaleEffect(categoryPulse ? 1.06 : 1)
    }

    // MARK: Pad or category grid

    @ViewBuilder
    private func bottomBlock(showingNotePicker: Bool) -> some View {
        if showCategoryPicker {
            NewCategoryPickerView(
                category: $category, showPicker: $showCategoryPicker,
                showSheet: $showCategorySheet, income: income
            ) {
                categoryPickedManually = true
                rememberCategoryForSide()
            }
            .id(income)
            .transition(AnyTransition.move(edge: .trailing).combined(with: .opacity))
        } else {
            EntryNumberPad(
                amount: $amount,
                isReady: !amount.isZero && category != nil,
                showingNotePicker: showingNotePicker,
                onRejected: {
                    rejectInput()
                },
                submit: {
                    submit(keepOpen: false)
                },
                submitAndContinue: continueAction
            )
            .transition(AnyTransition.move(edge: .leading).combined(with: .opacity))
        }
    }

    // Long press on the confirm key. Only for plain new entries: an edit or an SMS draft is one row.
    private var continueAction: (() -> Void)? {
        guard editTarget == nil, onFinish == nil else { return nil }

        return {
            submit(keepOpen: true)
        }
    }

    // MARK: Date picker

    private var datePickerOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture {
                    showingDatePicker = false
                }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    dayChip("Today", offset: 0)
                    dayChip("Yesterday", offset: -1)

                    Spacer()

                    Button {
                        Haptics.tap()
                        showingDatePicker = false
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundColor(Color.IncomeGreen)
                            .padding(7)
                            .background(Color.IncomeGreen.opacity(0.23), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Done"))
                }

                DatePicker("Date", selection: dayBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .padding(17)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .opacity(showingDatePicker ? 1 : 0)
        .allowsHitTesting(showingDatePicker)
        .animation(.easeOut(duration: 0.25), value: showingDatePicker)
    }

    private func dayChip(_ title: LocalizedStringKey, offset: Int) -> some View {
        let target = Calendar.current.date(byAdding: .day, value: offset, to: Date.now) ?? Date.now
        let selected = Calendar.current.isDate(target, inSameDayAs: date)

        return Button {
            pickDay(target, closeAfter: 0.12)
        } label: {
            Text(title)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .padding(.vertical, 8.5)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .foregroundColor(selected ? Color.PrimaryText : Color.SubtitleText)
                .background(
                    selected ? Color.SecondaryBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                        .strokeBorder(Color.Outline, lineWidth: 1.5)
                )
        }
        .buttonStyle(NumPadButton())
    }

    // The calendar only moves the day, the time of the entry stays.
    private var dayBinding: Binding<Date> {
        Binding<Date>(
            get: {
                date
            },
            set: { picked in
                pickDay(picked, closeAfter: 0.25)
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                date
            },
            set: { picked in
                if picked != date {
                    date = picked
                    timeEdited = true
                }
            }
        )
    }

    private func pickDay(_ day: Date, closeAfter delay: Double) {
        date = TransactionView.merge(day: day, timeFrom: date)
        // Back on today means the entry follows the clock again.
        dayEdited = !Calendar.current.isDateInToday(date)
        Haptics.selection()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            showingDatePicker = false
        }
    }

    private static func merge(day: Date, timeFrom time: Date) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        let clock = calendar.dateComponents([.hour, .minute, .second], from: time)

        components.hour = clock.hour
        components.minute = clock.minute
        components.second = clock.second

        return calendar.date(from: components) ?? day
    }

    // The date a new row gets at the moment of the confirm tap.
    private func stampedDate() -> Date {
        if editTarget != nil || timeEdited {
            return date
        }

        let now = Date.now

        if dayEdited {
            return TransactionView.merge(day: date, timeFrom: now)
        }

        return now
    }

    // The screen can stay open for hours: keep the visible date honest while nothing was picked.
    private func refreshUntouchedDate() {
        guard editTarget == nil, !timeEdited else { return }

        let now = Date.now
        date = dayEdited ? TransactionView.merge(day: date, timeFrom: now) : now
    }

    // MARK: Income and category

    private func setIncome(_ newValue: Bool) {
        guard newValue != income else { return }

        rememberCategoryForSide()

        let remembered = TransactionView.isUsable(newValue ? lastIncomeCategory : lastExpenseCategory)

        withAnimation(.easeIn(duration: 0.15)) {
            income = newValue
            category = remembered
        }

        if remembered == nil {
            categoryPickedManually = false
        }

        Haptics.tap()
    }

    private func rememberCategoryForSide() {
        if income {
            lastIncomeCategory = category
        } else {
            lastExpenseCategory = category
        }
    }

    private func pickCategory(_ picked: Category) {
        Haptics.selection()

        withAnimation(.easeInOut(duration: 0.2)) {
            category = picked
        }

        categoryPickedManually = true
        rememberCategoryForSide()
    }

    private func categoryPillTapped() {
        hideKeyboard()

        if sideCategories.isEmpty {
            showCategorySheet = true
            return
        }

        Haptics.tap()

        withAnimation(.easeInOut(duration: 0.2)) {
            showCategoryPicker.toggle()
        }
    }

    private func resolveCategory(for suggestion: NoteSuggestion) -> Category? {
        guard let id = suggestion.categoryID else { return nil }

        return sideCategories.first { $0.id == id }
    }

    private func pulseCategory() {
        withAnimation(.easeOut(duration: 0.12)) {
            categoryPulse = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.easeIn(duration: 0.18)) {
                categoryPulse = false
            }
        }
    }

    // MARK: Suggestions

    private func applySuggestion(_ suggestion: NoteSuggestion) {
        note = suggestion.note

        // While editing a chip only fixes the text, the row keeps its own category and amount.
        if editTarget == nil {
            if !categoryPickedManually, let match = resolveCategory(for: suggestion), match != category {
                withAnimation(.easeInOut(duration: 0.2)) {
                    category = match
                    showCategoryPicker = false
                }

                rememberCategoryForSide()
                pulseCategory()
            }

            if amount.isZero, suggestion.amountIsStable {
                var filled = amount
                filled.set(value: suggestion.lastAmount)
                amount = filled
            }
        }

        Haptics.tap()
        hideKeyboard()
    }

    private func noteFocusChanged(_ focused: Bool) {
        // Typed a known note without tapping its chip: take the category it was last used with.
        guard !focused, suggestionsEnabled, editTarget == nil, category == nil else { return }
        guard let known = suggestions.exact(note, income: income), let match = resolveCategory(for: known) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            category = match
        }

        rememberCategoryForSide()
        pulseCategory()
    }

    // MARK: Feedback

    private func rejectInput() {
        amountShake += 1
        Haptics.warning()
    }

    private func flashAmountError() {
        amountShake += 1
        amountError = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            amountError = false
        }
    }

    private func flashCategoryError() {
        categoryShake += 1

        withAnimation(.easeOut(duration: 0.2)) {
            categoryError = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.6)) {
                categoryError = false
            }
        }
    }

    // MARK: Closing

    private func report(saved: Bool, id: UUID?) {
        guard !finishReported else { return }

        finishReported = true
        onFinish?(saved, id)
    }

    private func close() {
        hideKeyboard()

        if isDirty, !isSubmitting {
            Haptics.warning()
            showDiscardDialog = true
            return
        }

        revertFailedEdit()
        report(saved: false, id: nil)
        dismiss()
    }

    /// A failed edit save leaves its changes in the context, so the next save anywhere would commit what the user discarded.
    /// The old and new categories are refreshed too, so the inverse to-many relationship stays consistent.
    private func revertFailedEdit() {
        guard editSaveFailed, let edited = editTarget, let context = edited.managedObjectContext,
              !edited.isDeleted, !edited.isInserted else { return }

        editSaveFailed = false

        let committed = edited.committedValues(forKeys: ["category"])["category"]
        var oldCategory = committed as? Category
        if oldCategory == nil, let objectID = committed as? NSManagedObjectID {
            oldCategory = (try? context.existingObject(with: objectID)) as? Category
        }
        let newCategory = edited.category

        context.refresh(edited, mergeChanges: false)
        for category in [oldCategory, newCategory].compactMap({ $0 }) where !category.isInserted && !category.isDeleted {
            context.refresh(category, mergeChanges: false)
        }
    }

    private func deleteEdited() {
        guard let target = editTarget, !isSubmitting else { return }

        isSubmitting = true

        do {
            let trashed = try TrashStore.shared.delete(target)
            let deletedID = trashed.id

            ToastCenter.shared.undo(String(localized: "Log Deleted")) {
                _ = try? TrashStore.shared.restore(ids: [deletedID])
            }

            report(saved: false, id: nil)
            dismiss()
        } catch {
            // The "Couldn't save" toast is already up. Stay open.
            isSubmitting = false
        }
    }

    // MARK: Saving

    private func submit(keepOpen: Bool) {
        guard !isSubmitting else { return }

        hideKeyboard()

        // A category deleted in the category sheet while it was selected here counts as missing.
        let usableCategory = TransactionView.isUsable(category)

        if category != nil, usableCategory == nil {
            category = nil
        }

        let missingAmount = amount.isZero
        let missingCategory = usableCategory == nil

        if missingAmount || missingCategory {
            if missingAmount, missingCategory {
                ToastCenter.shared.error(String(localized: "Incomplete Entry"), icon: "questionmark.app")
            } else if missingAmount {
                ToastCenter.shared.error(String(localized: "Missing Amount"), icon: "centsign.circle")
            } else {
                ToastCenter.shared.error(String(localized: "Missing Category"), icon: "tray")
            }

            if missingAmount {
                flashAmountError()
            }

            if missingCategory {
                flashCategoryError()
                openCategoryChoice()
            }

            return
        }

        guard let chosen = usableCategory else { return }

        isSubmitting = true

        if let edited = editTarget {
            saveEdit(edited, category: chosen)
        } else {
            saveNew(category: chosen, keepOpen: keepOpen)
        }
    }

    // Missing category on confirm: open the grid right away, or the category sheet when there is nothing to pick.
    private func openCategoryChoice() {
        if sideCategories.isEmpty {
            showCategorySheet = true
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            showCategoryPicker = true
        }
    }

    private func saveNew(category chosen: Category, keepOpen: Bool) {
        do {
            let created = try dataController.newTransactionOrThrow(
                note: cleanedNote,
                category: chosen,
                income: income,
                amount: amount.value,
                date: stampedDate(),
                repeatType: repeatType,
                repeatCoefficient: repeatCoefficient
            )

            if keepOpen {
                // The toast plays the success haptic itself.
                ToastCenter.shared.success(String(localized: "Saved"))
                resetForNextEntry()
                isSubmitting = false
            } else {
                Haptics.success()
                report(saved: true, id: created.id)
                dismiss()
            }
        } catch PersistenceError.storeNotLoaded {
            // Thrown before any save was tried, so nothing announced it yet.
            ToastCenter.shared.saveFailed()
            isSubmitting = false
        } catch {
            // Stay open with everything typed. The "Couldn't save" toast is automatic.
            isSubmitting = false
        }
    }

    private func saveEdit(_ edited: Transaction, category chosen: Category) {
        guard let context = edited.managedObjectContext, !edited.isDeleted else {
            // The row went away under the screen (sync, another device).
            ToastCenter.shared.saveFailed()
            isSubmitting = false
            return
        }

        let insertedBefore = context.insertedObjects

        let typedNote = cleanedNote
        // An empty note is still stored as the category name, the lists read the note as is.
        if typedNote.isEmpty {
            edited.note = chosen.wrappedName
        } else if typedNote != baseline.note {
            // An untouched note keeps its stored text: an imported one can be longer than the field shows.
            edited.note = typedNote
        }

        edited.category = chosen
        edited.income = income

        // Rows with more than 2 decimals (imports) keep their exact amount unless it was retyped.
        if AmountInput(value: edited.amount, mode: amount.mode) != amount {
            edited.amount = amount.value
        }

        edited.date = date

        let calendar = Calendar(identifier: .gregorian)
        edited.day = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: date) ?? Date.now
        edited.month = calendar.date(from: calendar.dateComponents([.month, .year], from: date)) ?? Date.now

        edited.onceRecurring = repeatType > 0
        edited.recurringType = Int16(clamping: repeatType)
        edited.recurringCoefficient = Int16(clamping: repeatCoefficient)

        if repeatType > 0 {
            dataController.generateRecurring(for: edited)
        }

        // Everything above goes to disk in one save, before the screen closes.
        if dataController.save("edit transaction").isFailure {
            // A second try would generate the recurring rows once more: drop them and keep the series on this row.
            context.insertedObjects.subtracting(insertedBefore).forEach { context.delete($0) }
            edited.recurringType = Int16(clamping: repeatType)
            editSaveFailed = true
            isSubmitting = false
            return
        }

        Haptics.success()
        report(saved: true, id: edited.id)
        dismiss()
    }

    // After "save and add another": same day and type, empty amount, note and category.
    private func resetForNextEntry() {
        var cleared = amount
        cleared.clear()
        amount = cleared

        note = ""
        category = nil
        categoryPickedManually = false
        lastExpenseCategory = nil
        lastIncomeCategory = nil
        repeatType = 0
        repeatCoefficient = 1
        showCategoryPicker = false

        var nextDate = date

        if !timeEdited {
            let now = Date.now
            nextDate = dayEdited ? TransactionView.merge(day: date, timeFrom: now) : now
            date = nextDate
        }

        // Built from the values just written, not read back from the view state.
        baseline = EntrySnapshot(
            amount: cleared,
            note: "",
            categoryID: nil,
            income: income,
            date: TransactionView.snapshotDate(nextDate, isEdit: false, dayEdited: dayEdited, timeEdited: timeEdited),
            repeatType: 0,
            repeatCoefficient: 1
        )
    }

    // MARK: Init

    private init(
        target: Transaction?,
        amount: AmountInput,
        note: String,
        category: Category?,
        income: Bool,
        date: Date,
        dateIsFixed: Bool,
        repeatType: Int,
        repeatCoefficient: Int,
        onFinish: ((Bool, UUID?) -> Void)?
    ) {
        toEdit = target
        self.onFinish = onFinish

        _editTarget = State(initialValue: target)
        _amount = State(initialValue: amount)
        _note = State(initialValue: note)
        _category = State(initialValue: category)
        _income = State(initialValue: income)
        // A preset category (budget screen, SMS, duplicate) must not be replaced by a note chip.
        _categoryPickedManually = State(initialValue: target == nil && category != nil)
        _date = State(initialValue: date)
        _dayEdited = State(initialValue: dateIsFixed)
        _timeEdited = State(initialValue: dateIsFixed)
        _repeatType = State(initialValue: repeatType)
        _repeatCoefficient = State(initialValue: repeatCoefficient)
        _baseline = State(
            initialValue: EntrySnapshot(
                amount: amount,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                categoryID: category?.objectID,
                income: income,
                date: TransactionView.snapshotDate(date, isEdit: target != nil, dayEdited: dateIsFixed, timeEdited: dateIsFixed),
                repeatType: repeatType,
                repeatCoefficient: repeatCoefficient
            )
        )
    }

    /// New entry (nil) or editing an existing row.
    init(toEdit: Transaction? = nil) {
        if let transaction = toEdit {
            var storedNote = transaction.wrappedNote

            // Old rows carry the category name as the note when none was typed.
            if let name = transaction.category?.name, storedNote == name {
                storedNote = ""
            }

            self.init(
                target: transaction,
                amount: AmountInput(value: transaction.wrappedAmount, mode: AmountInput.Mode.current),
                note: TransactionView.singleLine(storedNote),
                category: transaction.category,
                income: transaction.income,
                date: transaction.date ?? Date.now,
                dateIsFixed: true,
                repeatType: Int(transaction.recurringType),
                repeatCoefficient: max(1, Int(transaction.recurringCoefficient)),
                onFinish: nil
            )
        } else {
            self.init(draft: TransactionEntryDraft(amount: 0, income: false), onFinish: nil)
        }
    }

    /// New entry with the category already chosen (from a budget).
    init(category: Category? = nil) {
        self.init(
            draft: TransactionEntryDraft(amount: 0, income: category?.income ?? false, category: category),
            onFinish: nil
        )
    }

    /// New entry prefilled from an existing row, dated now. Nothing is saved until the user confirms.
    init(duplicating transaction: Transaction, onFinish: ((_ saved: Bool, _ id: UUID?) -> Void)? = nil) {
        self.init(draft: TransactionEntryDraft(duplicating: transaction), onFinish: onFinish)
    }

    /// New entry prefilled from a draft (SMS, deep link). onFinish runs once: (true, id of the new row)
    /// after a successful save, (false, nil) when the screen was closed without saving.
    init(draft: TransactionEntryDraft, onFinish: ((_ saved: Bool, _ id: UUID?) -> Void)? = nil) {
        var category = draft.category

        // A category of the other type cannot be shown in this side's picker.
        if let chosen = category, chosen.income != draft.income {
            category = nil
        }

        self.init(
            target: nil,
            amount: AmountInput(value: draft.amount, mode: AmountInput.Mode.current),
            note: TransactionView.singleLine(draft.note),
            category: category,
            income: draft.income,
            date: draft.date ?? Date.now,
            dateIsFixed: draft.date != nil,
            repeatType: 0,
            repeatCoefficient: 1,
            onFinish: onFinish
        )
    }

    private static func singleLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(NoteView.softLimit))
    }
}

struct NumPadButton: ButtonStyle {
    public func makeBody(configuration: Self.Configuration) -> some View {
        return configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

func getDollarOffset(big: CGFloat, small: CGFloat) -> CGFloat {
    let bigFont = UIFont.rounded(ofSize: big, weight: .regular)
    let smallFont = UIFont.rounded(ofSize: small, weight: .light)

    return bigFont.capHeight - smallFont.capHeight - 1
}

// Note pill: hugs short text, wraps up to 4 lines, then scrolls inside. No hard newlines.
struct NoteView: View {
    @Binding var note: String
    @Binding var focused: Bool

    @FocusState private var textFocused: Bool
    @State private var limitShake = 0

    static let softLimit = 300
    // The counter stays out of the way until the end is close.
    static let counterThreshold = 240

    init(note: Binding<String>, focused: Binding<Bool>) {
        _note = note
        _focused = focused
    }

    private var showsCounter: Bool {
        note.count >= NoteView.counterThreshold
    }

    var body: some View {
        VStack(spacing: 4) {
            pill

            if showsCounter {
                Text(verbatim: "\(note.count)/\(NoteView.softLimit)")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(note.count >= NoteView.softLimit ? Color.AlertRed : Color.SubtitleText)
                    .transition(.opacity)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(.easeOut(duration: 0.15), value: showsCounter)
        .onChange(of: textFocused) { _, newValue in
            focused = newValue
        }
        .onChange(of: note) { oldValue, newValue in
            sanitize(newValue, previous: oldValue)
        }
    }

    private var pill: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "text.alignleft")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)

            // The hidden Text alone decides the size, so the pill hugs short notes and grows by lines.
            // The field sits on top of it: a vertical TextField on its own takes all the width it is offered.
            Text(note.isEmpty ? String(localized: "Add Note") : note + " ")
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 6)
                .foregroundColor(Color.SubtitleText)
                .opacity(note.isEmpty ? 1 : 0)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    TextField("", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .submitLabel(.done)
                        .focused($textFocused)
                        .foregroundColor(Color.PrimaryText)
                        .accessibilityLabel(Text("Add Note"))
                }
        }
        .font(.system(.body, design: .rounded).weight(.semibold))
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .overlay(
            RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                .stroke(Color.Outline, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            textFocused = true
        }
        .modifier(EntryShakeEffect(animatableData: CGFloat(limitShake)))
        .animation(.linear(duration: 0.35), value: limitShake)
    }

    private func sanitize(_ newValue: String, previous: String) {
        var cleaned = newValue

        if cleaned.contains("\n") {
            // Return on the keyboard means done, wherever the cursor is.
            // A pasted text with line breaks keeps the focus.
            let breaks = cleaned.components(separatedBy: "\n").count - 1
            let typedReturn = breaks == 1 && (cleaned.hasSuffix("\n") || cleaned.count == previous.count + 1)

            if typedReturn {
                cleaned = cleaned.replacingOccurrences(of: "\n", with: "")
                textFocused = false
            } else {
                cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
            }
        }

        if cleaned.count > NoteView.softLimit {
            cleaned = String(cleaned.prefix(NoteView.softLimit))
            limitShake += 1
            Haptics.warning()
        }

        if cleaned != newValue {
            note = cleaned
        }
    }
}

struct RecurringPickerView: View {
    @Namespace var animation
    @Binding var repeatType: Int
    @Binding var repeatCoefficient: Int
    @Binding var showMenu: Bool

    @Binding var showPicker: Bool

    let stringArray = ["none", "daily", "weekly", "monthly"]
    let stringArray2 = ["", "days", "weeks", "months"]

    @AppStorage("bottomEdge", store: UserDefaults.appGroup)
    var bottomEdge: Double = 15

    @State private var offset: CGFloat = 0

    @State var holdingType = 0
    @State var holdingCoefficient = 0

    @AppStorage("colourScheme", store: UserDefaults.appGroup)
    var colourScheme: Int = 0

    @Environment(\.colorScheme) var systemColorScheme

    var darkMode: Bool {
        (colourScheme == 0 && systemColorScheme == .dark) || colourScheme == 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(stringArray, id: \.self) { string in
                HStack {
                    Text(LocalizedStringKey(string))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .lineLimit(1)
                    Spacer()

                    if repeatType == (stringArray.firstIndex(of: string) ?? 0) && repeatCoefficient == 1 {
                        Image(systemName: "checkmark")
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        //                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                //                .font(.system(size: 18, weight: .medium, design: .rounded))
                .padding(5)
                .background {
                    if repeatType == (stringArray.firstIndex(of: string) ?? 0) && repeatCoefficient == 1 {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                darkMode
                                ? Color("AlwaysDarkSecondaryBackground") : Color("AlwaysLightSecondaryBackground")
                            )
                            .matchedGeometryEffect(id: "TAB", in: animation)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if repeatType == (stringArray.firstIndex(of: string) ?? 0) && repeatCoefficient == 1 {
                        showMenu = false
                    } else {
                        withAnimation(.easeIn(duration: 0.15)) {
                            repeatType = (stringArray.firstIndex(of: string) ?? 0)
                            repeatCoefficient = 1
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            showMenu = false
                        }
                    }
                }
            }

            HStack {
                if repeatCoefficient == 1 {
                    Text("custom")
                } else {
                    if repeatType == 1 {
                        Text(String(repeatCoefficient) + " " + String(localized: "\(repeatCoefficient) days"))
                    } else if repeatType == 2 {
                        Text(String(repeatCoefficient) + " " + String(localized: "\(repeatCoefficient) weeks"))
                    } else if repeatType == 3 {
                        Text(String(repeatCoefficient) + " " + String(localized: "\(repeatCoefficient) months"))
                    }
                }

                Spacer()

                if repeatCoefficient > 1 {
                    Image(systemName: "checkmark")
                        .font(.system(.footnote, design: .rounded).weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    //                        .font(.system(size: 14, weight: .medium))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(.body, design: .rounded).weight(.medium))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            //            .font(.system(size: 18, weight: .medium, design: .rounded))
            .padding(5)
            .background {
                if repeatCoefficient > 1 {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            darkMode
                            ? Color("AlwaysDarkSecondaryBackground") : Color("AlwaysLightSecondaryBackground")
                        )
                        .matchedGeometryEffect(id: "TAB", in: animation)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if repeatCoefficient == 1 {
                    repeatCoefficient = 2
                    repeatType = 2

                    holdingType = repeatType
                    holdingCoefficient = repeatCoefficient
                }

                withAnimation {
                    showPicker = true
                }
            }
            .onChange(of: showPicker) { newValue in
                // holdingType != repeatType || holdingCoefficient != repeatCoefficient
                if !newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showMenu = false
                    }
                }
            }
        }
        .foregroundColor(darkMode ? Color("AlwaysLightBackground") : Color("AlwaysDarkBackground"))
        .padding(4)
        .frame(width: 150)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(
                darkMode ? Color("AlwaysDarkBackground") : Color("AlwaysLightBackground")
            ).shadow(color: darkMode ? Color.clear : Color.gray.opacity(0.25), radius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(
                darkMode ? Color.gray.opacity(0.1) : Color.clear, lineWidth: 1.3))
    }
}

struct CustomRecurringView: View {
    @Binding var repeatType: Int
    @Binding var repeatCoefficient: Int
    @Binding var showPicker: Bool

    @Environment(\.colorScheme) var systemColorScheme
    var stringArray: [String] {
        return [
            "", "\(holdingCoefficient) days", "\(holdingCoefficient) weeks",
            "\(holdingCoefficient) months"
        ]
    }

    @Environment(\.dismiss) var dismiss

    @State var holdingType = 0
    @State var holdingCoefficient = 0

    var body: some View {
        VStack(spacing: 35) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    //                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.SubtitleText)
                        .padding(7)
                        .background(Color.SecondaryBackground, in: Circle())
                        .contentShape(Circle())
                }

                Spacer()

                Text("Custom Interval")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                //                    .font(.system(size: 18, weight: .semibold, design: .rounded))

                Spacer()

                Button {
                    repeatType = holdingType
                    repeatCoefficient = holdingCoefficient

                    Haptics.tap()

                    dismiss()

                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    //                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.IncomeGreen)
                        .padding(7)
                        .background(Color.IncomeGreen.opacity(0.23), in: Circle())
                        .contentShape(Circle())
                }
            }

            HStack(spacing: 10) {
                Text("Repeats every")
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .foregroundColor(Color.PrimaryText)
                    .padding(.trailing, 3)

                VStack {
                    Button {
                        holdingCoefficient += 1
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.SubtitleText)
                            .padding(7)
                            .background(
                                Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .contentShape(Circle())
                            .opacity(holdingCoefficient == 30 ? 0.25 : 1)
                    }
                    .disabled(holdingCoefficient == 30)

                    Text("\(holdingCoefficient)")
                        .font(.system(size: 23, weight: .medium, design: .rounded))
                        .padding(7)
                        .background {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.SecondaryBackground)
                                .frame(width: 40, height: 40)
                        }

                    Button {
                        holdingCoefficient -= 1
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.SubtitleText)
                            .padding(7)
                            .background(
                                Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .contentShape(Circle())
                            .opacity(holdingCoefficient == 2 ? 0.25 : 1)
                    }
                    .disabled(holdingCoefficient == 2)
                }

                VStack {
                    Button {
                        holdingType -= 1
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.SubtitleText)
                            .padding(7)
                            .background(
                                Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .contentShape(Circle())
                            .opacity(holdingType == 1 ? 0.25 : 1)
                    }
                    .disabled(holdingType == 1)

                    Group {
                        if holdingType == 1 {
                            Text("\(holdingCoefficient) days")
                        } else if holdingType == 2 {
                            Text("\(holdingCoefficient) weeks")
                        } else if holdingType == 3 {
                            Text("\(holdingCoefficient) months")
                        }
                    }
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .padding(7)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.SecondaryBackground)
                            .frame(height: 40)
                    }

                    Button {
                        holdingType += 1
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.SubtitleText)
                            .padding(7)
                            .background(
                                Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .contentShape(Circle())
                            .opacity(holdingType == 3 ? 0.25 : 1)
                    }
                    .disabled(holdingType == 3)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(13)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            holdingType = repeatType
            holdingCoefficient = repeatCoefficient
        }
    }
}
