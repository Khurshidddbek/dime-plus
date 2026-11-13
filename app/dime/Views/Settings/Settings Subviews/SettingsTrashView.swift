//
//  SettingsTrashView.swift
//  dime
//
//  Settings > Recently deleted: transactions (and categories) deleted in the last 30 days,
//  with restore and delete forever.
//

import SwiftUI

struct SettingsTrashView: View {
    @EnvironmentObject var trash: TrashStore

    @State private var confirmEmpty = false
    @State private var confirmRestore = false

    private var isEmpty: Bool {
        trash.items.isEmpty && trash.categories.isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            SettingsSubviewHeader(title: "Recently deleted")
                .padding(.bottom, 10)

            if isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.system(.largeTitle, design: .rounded).weight(.light))
                        .foregroundColor(Color.SubtitleText)

                    Text("Nothing here")
                        .font(.system(.title3, design: .rounded).weight(.medium))
                        .foregroundColor(Color.PrimaryText.opacity(0.8))

                    Text("Deleted transactions stay here for 30 days and can be restored.")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundColor(Color.SubtitleText)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 90)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            SettingsActionButton(title: "Restore all", systemImage: "arrow.uturn.backward") {
                                confirmRestore = true
                            }

                            SettingsActionButton(title: "Delete all", systemImage: "trash", destructive: true) {
                                confirmEmpty = true
                            }
                        }
                        // Keeps the first buttons clear of the back button, so a tap there is not a restore.
                        .padding(.top, 14)

                        SettingsFootnote(text: "Deleted transactions stay here for 30 days and can be restored.")
                            .padding(.bottom, 8)

                        if !trash.categories.isEmpty {
                            SettingsSectionTitle(text: "CATEGORIES")

                            VStack(spacing: 0) {
                                ForEach(trash.categories) { entry in
                                    categoryRow(entry)
                                        .overlay(alignment: .bottom) {
                                            if entry != trash.categories.last {
                                                Divider()
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, 15)
                            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                            .padding(.bottom, 8)
                        }

                        if !trash.items.isEmpty {
                            SettingsSectionTitle(text: "TRANSACTIONS")

                            LazyVStack(spacing: 0) {
                                ForEach(trash.items) { item in
                                    transactionRow(item)
                                        .overlay(alignment: .bottom) {
                                            if item != trash.items.last {
                                                Divider()
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, 15)
                            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(.bottom, 90)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(SettingsSubviewModifier())
        .onAppear {
            trash.purgeExpired()
        }
        .confirmationDialog(restoreTitle, isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore all") {
                restoreAll()
            }

            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(emptyTitle, isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete forever", role: .destructive) {
                trash.empty()
                Haptics.impact(.heavy)
                ToastCenter.shared.info(String(localized: "Recently deleted is empty"))
            }

            Button("Cancel", role: .cancel) {}
        }
    }

    private var restoreTitle: String {
        let count = trash.items.count

        guard count > 0 else {
            return String(localized: "Restore everything here?")
        }

        return String(localized: "Restore \(count) transactions?")
    }

    private var emptyTitle: String {
        let count = trash.items.count

        guard count > 0 else {
            return String(localized: "Delete everything here forever?")
        }

        return String(localized: "Delete \(count) transactions forever?")
    }

    private func transactionRow(_ item: TrashedTransaction) -> some View {
        let note = item.snapshot.note ?? ""
        let title = note.isEmpty ? (item.category?.name ?? String(localized: "No note")) : note
        let days = trash.daysLeft(for: item)

        return HStack(spacing: 10) {
            Text(item.category?.emoji ?? "")
                .font(.system(.body, design: .rounded))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let date = item.snapshot.date {
                    Text(shortDate(date))
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                }

                Text(deletedInfo(item.deletedAt, daysLeft: days))
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(Color.SubtitleText.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountText(
                item.snapshot.amount, role: .caption, sign: item.snapshot.income ? .plus : .minus, fit: .fullOnly,
                color: item.snapshot.income ? Color.IncomeGreen : Color.PrimaryText
            )
            .layoutPriority(1)

            Menu {
                Button {
                    restore(item)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }

                Button(role: .destructive) {
                    trash.remove(ids: [item.id])
                    Haptics.tap()
                } label: {
                    Label("Delete forever", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.SubtitleText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("More"))
        }
        .padding(.vertical, 4)
    }

    private func categoryRow(_ entry: TrashedCategory) -> some View {
        let count = trash.items.filter { $0.groupID == entry.groupID }.count

        return HStack(spacing: 10) {
            Text(entry.category.emoji ?? "")
                .font(.system(.body, design: .rounded))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.category.name ?? "")
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)

                Text("Transactions: \(count)")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                restore(entry)
            } label: {
                Text("Restore")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.PrimaryText)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(Color.SecondaryBackground, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    /// "12 Nov, 17:04", with the year only when it is not this year.
    private func shortDate(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let day = Fmt.string(sameYear ? .dayMonth : .dayMonthYear, from: date)
        return day + ", " + Fmt.time(date)
    }

    /// "deleted 18:55, 30 days left" (a date instead of the time when it was not today).
    private func deletedInfo(_ deletedAt: Date, daysLeft: Int) -> String {
        let when = Calendar.current.isDateInToday(deletedAt) ? Fmt.time(deletedAt) : Fmt.string(.dayMonth, from: deletedAt)
        return String(localized: "trash-deleted-at \(when)") + ", " + String(localized: "\(daysLeft) days left")
    }

    private func restore(_ item: TrashedTransaction) {
        do {
            try ChangeHistory.shared.withSource(ChangeHistory.Source.trash) {
                try trash.restore(item)
            }
            ToastCenter.shared.success(String(localized: "Restored"))
        } catch {
            // The "Couldn't save" toast is automatic; the copy stays here.
        }
    }

    private func restore(_ entry: TrashedCategory) {
        do {
            try ChangeHistory.shared.withSource(ChangeHistory.Source.trash) {
                try trash.restoreGroup(entry.groupID)
            }
            ToastCenter.shared.success(String(localized: "Restored"))
        } catch {
            // Automatic toast.
        }
    }

    private func restoreAll() {
        do {
            let groups = trash.categories.map { $0.groupID }

            let restored = try ChangeHistory.shared.withSource(ChangeHistory.Source.trash) { () throws -> [UUID] in
                let ids = try trash.restoreAll()

                // Categories that had no rows left in the trash come back through their group.
                for groupID in groups {
                    try trash.restoreGroup(groupID)
                }

                return ids
            }

            ToastCenter.shared.success(String(localized: "Restored transactions: \(restored.count)"))
        } catch {
            // Automatic toast.
        }
    }
}
