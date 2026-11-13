//
//  SettingsHistoryView.swift
//  dime
//
//  Settings > History of changes: what was added, edited or deleted, when and from where
//  (manual entry, SMS, import, restore, recurring, iCloud). Data comes from ChangeHistory.
//

import SwiftUI

struct SettingsHistoryView: View {
    enum HistoryFilter: CaseIterable {
        case all, added, deleted, sms

        var title: LocalizedStringKey {
            switch self {
            case .all: return "history-filter-all"
            case .added: return "history-filter-added"
            case .deleted: return "history-filter-deleted"
            case .sms: return "history-filter-sms"
            }
        }

        func includes(_ record: ChangeRecord) -> Bool {
            switch self {
            case .all:
                return true
            case .added:
                return record.kind == .added || record.kind == .restored
            case .deleted:
                return record.kind == .deleted || record.kind == .erased
            case .sms:
                return record.isFromSMS
            }
        }
    }

    private struct HistoryDay: Identifiable {
        let id: Date
        let records: [ChangeRecord]
    }

    @ObservedObject private var history = ChangeHistory.shared

    @State private var filter: HistoryFilter = .all
    @State private var selected: ChangeRecord?

    var body: some View {
        let filtered = history.records.filter { filter.includes($0) }

        VStack(spacing: 10) {
            SettingsSubviewHeader(title: "History of changes")
                .padding(.bottom, 10)

            HistoryFilterBar(selection: $filter)

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        summary(filtered)
                            .padding(.bottom, 6)

                        ForEach(sections(filtered)) { day in
                            dayTitle(day.id)

                            VStack(spacing: 0) {
                                ForEach(day.records) { record in
                                    Button {
                                        Haptics.tap()
                                        selected = record
                                    } label: {
                                        HistoryRow(record: record)
                                    }
                                    .buttonStyle(.plain)
                                    .overlay(alignment: .bottom) {
                                        if record.id != day.records.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 15)
                            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                            .padding(.bottom, 6)
                        }

                        SettingsFootnote(text: "Changes are recorded since \(sinceText)")
                    }
                    .padding(.bottom, 90)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(SettingsSubviewModifier())
        .sheet(item: $selected) { record in
            HistoryDetailView(record: record)
        }
    }

    private var sinceText: String {
        Fmt.string(.dayMonthYear, from: history.startedAt)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(.largeTitle, design: .rounded).weight(.light))
                .foregroundColor(Color.SubtitleText)

            if history.records.isEmpty {
                Text("No changes yet")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText.opacity(0.8))

                Text("Every added, edited and deleted transaction will show up here.")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.SubtitleText)
            } else {
                Text("Nothing for this filter")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText.opacity(0.8))
            }

            Text("Changes are recorded since \(sinceText)")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundColor(Color.SubtitleText)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 90)
    }

    private func summary(_ records: [ChangeRecord]) -> some View {
        let net = records.reduce(0.0) { $0 + $1.effect }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Balance change")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.SubtitleText)

                    AmountText(net, role: .headline, sign: .always, fit: .ladder,
                               color: net > 0 ? Color.IncomeGreen : Color.PrimaryText)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("history-count-title")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.SubtitleText)

                    Text(MoneyFormat.number(Double(records.count)))
                        .font(.system(.title2, design: .rounded).weight(.medium))
                        .foregroundColor(Color.PrimaryText)
                        .monospacedDigit()
                }
            }

            Text("Income counts as plus, expenses as minus.")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    private func dayTitle(_ day: Date) -> some View {
        let text = Fmt.dayHeader(day)
        let title = text.prefix(1).uppercased() + text.dropFirst()

        return Text(title)
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundColor(Color.SubtitleText)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func sections(_ records: [ChangeRecord]) -> [HistoryDay] {
        let calendar = Calendar.current
        var days = [HistoryDay]()
        var currentDay: Date?
        var bucket = [ChangeRecord]()

        // Records are newest first, so one pass keeps both days and rows in order.
        for record in records {
            let day = calendar.startOfDay(for: record.at)

            if day != currentDay {
                if let previous = currentDay, !bucket.isEmpty {
                    days.append(HistoryDay(id: previous, records: bucket))
                }

                currentDay = day
                bucket = []
            }

            bucket.append(record)
        }

        if let last = currentDay, !bucket.isEmpty {
            days.append(HistoryDay(id: last, records: bucket))
        }

        return days
    }
}

// MARK: filter bar

private struct HistoryFilterBar: View {
    @Binding var selection: SettingsHistoryView.HistoryFilter

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsHistoryView.HistoryFilter.allCases, id: \.self) { item in
                Button {
                    guard item != selection else {
                        return
                    }

                    Haptics.selection()

                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = item
                    }
                } label: {
                    Text(item.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(selection == item ? Color.LightIcon : Color.SubtitleText)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.DarkBackground)
                                    .matchedGeometryEffect(id: "historyFilter", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: shared presentation

enum HistoryText {
    static func kindIcon(_ kind: ChangeRecord.Kind) -> String {
        switch kind {
        case .added: return "plus.circle.fill"
        case .edited: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .restored: return "arrow.uturn.backward.circle.fill"
        case .bulk: return "square.stack.3d.up.fill"
        case .erased: return "xmark.bin.fill"
        }
    }

    static func kindColor(_ kind: ChangeRecord.Kind) -> Color {
        switch kind {
        case .added: return Color.IncomeGreen
        case .edited: return Color.orange
        case .deleted, .erased: return Color.AlertRed
        case .restored: return Color.blue
        case .bulk: return Color.purple
        }
    }

    static func kindTitle(_ kind: ChangeRecord.Kind) -> String {
        switch kind {
        case .added: return String(localized: "history-kind-added")
        case .edited: return String(localized: "history-kind-edited")
        case .deleted: return String(localized: "history-kind-deleted")
        case .restored: return String(localized: "history-kind-restored")
        case .bulk: return String(localized: "history-kind-bulk")
        case .erased: return String(localized: "history-kind-erased")
        }
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case ChangeHistory.Source.manual: return String(localized: "history-source-manual")
        case ChangeHistory.Source.shortcut: return String(localized: "history-source-shortcut")
        case ChangeHistory.Source.recurring: return String(localized: "history-source-recurring")
        case ChangeHistory.Source.trash: return String(localized: "history-source-trash")
        case ChangeHistory.Source.history: return String(localized: "history-source-history")
        case ChangeHistory.Source.sms: return String(localized: "history-source-sms")
        case ChangeHistory.Source.smsAuto: return String(localized: "history-source-sms-auto")
        case ChangeHistory.Source.importing: return String(localized: "history-source-import")
        case ChangeHistory.Source.restore: return String(localized: "history-source-restore")
        case ChangeHistory.Source.icloud: return String(localized: "history-source-icloud")
        default: return String(localized: "history-source-system")
        }
    }

    static func fieldTitle(_ field: ChangeField.Field) -> String {
        switch field {
        case .amount: return String(localized: "history-field-amount")
        case .income: return String(localized: "history-field-type")
        case .note: return String(localized: "history-field-note")
        case .category: return String(localized: "history-field-category")
        case .date: return String(localized: "history-field-date")
        }
    }

    static func title(_ record: ChangeRecord) -> String {
        switch record.kind {
        case .bulk, .erased:
            return kindTitle(record.kind)
        default:
            let main: String

            if !record.note.isEmpty {
                main = record.note
            } else if !record.categoryName.isEmpty {
                main = record.categoryName
            } else {
                main = String(localized: "No note")
            }

            return record.categoryEmoji.isEmpty ? main : record.categoryEmoji + " " + main
        }
    }

    static func dateTime(_ date: Date) -> String {
        Fmt.string(.dayMonthYear, from: date) + ", " + Fmt.time(date)
    }

    static func typeText(_ income: Bool) -> String {
        income ? String(localized: "history-income") : String(localized: "Expense")
    }
}

/// Small grey capsule with the source of a change.
struct HistorySourceTag: View {
    let source: String

    var body: some View {
        Text(HistoryText.sourceLabel(source))
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundColor(Color.SubtitleText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.SecondaryBackground, in: Capsule())
    }
}

// MARK: row

private struct HistoryRow: View {
    let record: ChangeRecord

    private var subtitle: String {
        var parts = [Fmt.time(record.at)]

        if record.kind == .edited, let changes = record.changes, !changes.isEmpty {
            parts.append(changes.map { HistoryText.fieldTitle($0.field).lowercased() }.joined(separator: ", "))
        } else if let date = record.date, !Calendar.current.isDate(date, inSameDayAs: record.at) {
            parts.append(String(localized: "dated \(Fmt.string(.dayMonth, from: date))"))
        }

        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: HistoryText.kindIcon(record.kind))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(HistoryText.kindColor(record.kind))
                .frame(width: 28)
                .accessibilityLabel(Text(HistoryText.kindTitle(record.kind)))

            VStack(alignment: .leading, spacing: 3) {
                Text(HistoryText.title(record))
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(record.kind == .deleted ? Color.SubtitleText : Color.PrimaryText)
                    .strikethrough(record.kind == .deleted, color: Color.SubtitleText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    HistorySourceTag(source: record.source)

                    Text(subtitle)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer(minLength: 4)

            amount
                .layoutPriority(1)
        }
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var amount: some View {
        switch record.kind {
        case .erased:
            EmptyView()
        case .bulk:
            AmountText(record.effect, role: .caption, sign: .always, fit: .fullOnly,
                       color: record.effect > 0 ? Color.IncomeGreen : Color.PrimaryText)
        default:
            AmountText(record.amount, role: .caption, sign: record.income ? .plus : .minus, fit: .fullOnly,
                       color: record.kind == .deleted ? Color.SubtitleText : (record.income ? Color.IncomeGreen : Color.PrimaryText))
        }
    }
}

// MARK: detail sheet

private struct HistoryDetailView: View {
    let record: ChangeRecord

    @ObservedObject private var trash = TrashStore.shared

    @State private var existing: Transaction?
    @State private var editing: Transaction?

    private var isInTrash: Bool {
        guard let id = record.transactionID else {
            return false
        }

        return trash.items.contains { $0.id == id }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                header

                if record.kind != .erased {
                    amountBlock
                }

                detailsCard

                if let changes = record.changes, !changes.isEmpty {
                    VStack(spacing: 6) {
                        SettingsSectionTitle(text: "WHAT CHANGED")

                        VStack(spacing: 0) {
                            ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                                changeRow(change)
                                    .overlay(alignment: .bottom) {
                                        if index < changes.count - 1 {
                                            Divider()
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 15)
                        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                    }
                }

                actions
            }
            .padding(20)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.PrimaryBackground)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: refresh)
        .onChange(of: trash.items) {
            refresh()
        }
        .fullScreenCover(item: $editing, onDismiss: refresh) { transaction in
            TransactionView(toEdit: transaction)
                .environmentObject(DataController.shared)
                .environment(\.managedObjectContext, DataController.shared.container.viewContext)
                .toastHost()
        }
        .toastHost()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: HistoryText.kindIcon(record.kind))
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundColor(HistoryText.kindColor(record.kind))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(HistoryText.kindTitle(record.kind))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.PrimaryText)

                HStack(spacing: 6) {
                    HistorySourceTag(source: record.source)

                    Text(HistoryText.dateTime(record.at))
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var amountBlock: some View {
        VStack(spacing: 4) {
            if record.kind == .bulk {
                AmountText(record.effect, role: .title, sign: .always, fit: .ladder,
                           color: record.effect > 0 ? Color.IncomeGreen : Color.PrimaryText)
                    .amountReveal(record.effect, sign: .always)
            } else {
                AmountText(record.amount, role: .title, sign: record.income ? .plus : .minus, fit: .ladder,
                           color: record.income ? Color.IncomeGreen : Color.PrimaryText)
                    .amountReveal(record.amount, sign: record.income ? .plus : .minus)

                Text(HistoryText.title(record))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var detailsCard: some View {
        VStack(spacing: 0) {
            switch record.kind {
            case .bulk:
                SettingsValueRow(title: "history-bulk-added", value: MoneyFormat.number(Double(record.addedCount ?? 0)))
                Divider()
                SettingsValueRow(title: "history-bulk-deleted", value: MoneyFormat.number(Double(record.deletedCount ?? 0)))
                Divider()
                SettingsValueRow(title: "history-bulk-edited", value: MoneyFormat.number(Double(record.editedCount ?? 0)))
            case .erased:
                SettingsValueRow(title: "history-field-date", value: HistoryText.dateTime(record.at))
            default:
                SettingsValueRow(title: "history-field-type", value: HistoryText.typeText(record.income))

                if !record.categoryName.isEmpty {
                    Divider()
                    SettingsValueRow(title: "history-field-category", value: [record.categoryEmoji, record.categoryName].filter { !$0.isEmpty }.joined(separator: " "))
                }

                if !record.note.isEmpty {
                    Divider()
                    SettingsValueRow(title: "history-field-note", value: record.note)
                }

                if let date = record.date {
                    Divider()
                    SettingsValueRow(title: "history-field-date", value: HistoryText.dateTime(date))
                }
            }
        }
        .padding(.horizontal, 15)
        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    private func changeRow(_ change: ChangeField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HistoryText.fieldTitle(change.field))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)

            Text("was \(oldValue(change))")
                .font(.system(.body, design: .rounded))
                .foregroundColor(Color.SubtitleText)
                .fixedSize(horizontal: false, vertical: true)

            Text("now \(newValue(change))")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Color.PrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func oldValue(_ change: ChangeField) -> String {
        value(change.field, text: change.oldText, number: change.oldNumber, date: change.oldDate, flag: change.oldFlag)
    }

    private func newValue(_ change: ChangeField) -> String {
        value(change.field, text: change.newText, number: change.newNumber, date: change.newDate, flag: change.newFlag)
    }

    private func value(_ field: ChangeField.Field, text: String?, number: Double?, date: Date?, flag: Bool?) -> String {
        let empty = String(localized: "history-empty-value")

        switch field {
        case .amount:
            return number.map { MoneyFormat.string($0) } ?? empty
        case .income:
            return flag.map { HistoryText.typeText($0) } ?? empty
        case .date:
            return date.map { HistoryText.dateTime($0) } ?? empty
        case .note, .category:
            guard let text = text, !text.isEmpty else {
                return empty
            }

            return text
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let transaction = existing {
            VStack(spacing: 10) {
                SettingsActionButton(title: "Open transaction", systemImage: "square.and.pencil", prominent: true) {
                    Haptics.tap()
                    editing = transaction
                }

                if record.kind == .added || record.kind == .restored {
                    SettingsActionButton(title: "Delete", systemImage: "trash", destructive: true) {
                        delete(transaction)
                    }
                }
            }
            .padding(.top, 4)
        } else if isInTrash, let id = record.transactionID {
            SettingsActionButton(title: "Restore", systemImage: "arrow.uturn.backward", prominent: true) {
                restore(id)
            }
            .padding(.top, 4)
        } else if record.transactionID != nil {
            SettingsFootnote(text: "This transaction no longer exists.")
                .padding(.top, 4)
        }
    }

    private func refresh() {
        guard let id = record.transactionID else {
            existing = nil
            return
        }

        let found = DataController.shared.findTransaction(withId: id)
        existing = (found?.isDeleted ?? true) ? nil : found
    }

    private func delete(_ transaction: Transaction) {
        do {
            let trashed = try ChangeHistory.shared.withSource(ChangeHistory.Source.history) {
                try TrashStore.shared.delete(transaction)
            }
            existing = nil

            ToastCenter.shared.undo(String(localized: "Log Deleted")) {
                _ = try? ChangeHistory.shared.withSource(ChangeHistory.Source.history) {
                    try TrashStore.shared.restore(ids: [trashed.id])
                }
            }
        } catch {
            // The "Couldn't save" toast is automatic.
        }
    }

    private func restore(_ id: UUID) {
        do {
            try ChangeHistory.shared.withSource(ChangeHistory.Source.history) {
                try TrashStore.shared.restore(ids: [id])
            }
            ToastCenter.shared.success(String(localized: "Restored"))
            refresh()
        } catch {
            // Automatic toast.
        }
    }
}
