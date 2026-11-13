//
//  SettingsBackupsView.swift
//  dime
//
//  Settings > Backups: when the last backup was made, "Back up now", the list of backup
//  files with share / restore / delete, and restore from a file picked in Files.
//

import SwiftUI
import UniformTypeIdentifiers

enum BackupText {
    static func date(_ date: Date) -> String {
        if date == Date.distantPast {
            return String(localized: "Unknown date")
        }

        return Fmt.string(.dayMonthYear, from: date) + ", " + Fmt.time(date)
    }

    static func tag(_ tag: String) -> String {
        switch tag {
        case BackupStore.automaticTag:
            return String(localized: "Automatic")
        case BackupStore.manualTag:
            return String(localized: "Manual")
        case BackupStore.safetyTag:
            return String(localized: "Before restore")
        case "pre-import":
            return String(localized: "Before import")
        case "pre-erase":
            return String(localized: "Before erase")
        case "export":
            return String(localized: "Export")
        case "file":
            return String(localized: "File")
        default:
            return tag
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// What the restore card works on: a backup from the list or a file picked in Files.
struct BackupRestoreTarget: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct SettingsBackupsView: View {
    @State private var backups: [BackupInfo] = []
    @State private var working = false
    @State private var restoreTarget: BackupRestoreTarget?
    @State private var shareFile: ShareFile?
    @State private var pickingFile = false
    @State private var toDelete: BackupInfo?

    private var lastBackupText: String {
        guard let newest = backups.first else {
            return String(localized: "Never")
        }

        return BackupText.date(newest.createdAt)
    }

    var body: some View {
        VStack(spacing: 10) {
            SettingsSubviewHeader(title: "Backups")
                .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    VStack(spacing: 0) {
                        SettingsValueRow(title: "Last backup", value: lastBackupText)
                    }
                    .padding(.horizontal, 15)
                    .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))

                    SettingsFootnote(text: "A backup is made automatically once a day and the last 14 are kept. The files are also visible in the Files app, in the Dime folder.")
                        .padding(.bottom, 8)

                    SettingsActionButton(title: "Back up now", systemImage: "externaldrive.fill.badge.plus", prominent: true, busy: working) {
                        backUpNow()
                    }

                    SettingsActionButton(title: "Restore from a file...", systemImage: "folder") {
                        pickingFile = true
                    }
                    .padding(.bottom, 14)

                    if backups.isEmpty {
                        Text("No backups yet")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundColor(Color.SubtitleText)
                            .padding(.vertical, 30)
                    } else {
                        SettingsSectionTitle(text: "SAVED BACKUPS")

                        LazyVStack(spacing: 0) {
                            ForEach(backups) { backup in
                                row(backup)
                                    .overlay(alignment: .bottom) {
                                        if backup != backups.last {
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
        .modifier(SettingsSubviewModifier())
        .onAppear {
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: BackupStore.didChangeNotification)) { _ in
            reload()
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                restoreTarget = BackupRestoreTarget(url: url, title: url.lastPathComponent)
            case let .failure(error):
                DiagnosticsLog.shared.log("backup", "file picker failed: \(error.localizedDescription)")
                ToastCenter.shared.error(String(localized: "Couldn't open the file"))
            }
        }
        .fullScreenCover(item: $restoreTarget) { target in
            BackupRestoreCard(target: target)
        }
        .sheet(item: $shareFile) { file in
            ActivityViewController(activityItems: [file.url])
        }
        .confirmationDialog("Delete this backup?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let backup = toDelete {
                    BackupStore.shared.delete(backup)
                    Haptics.tap()
                }

                toDelete = nil
            }

            Button("Cancel", role: .cancel) {
                toDelete = nil
            }
        }
    }

    private func row(_ backup: BackupInfo) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                restoreTarget = BackupRestoreTarget(url: backup.url, title: BackupText.date(backup.createdAt))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BackupText.date(backup.createdAt))
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(BackupText.tag(backup.tag) + ", " + BackupText.size(backup.size))
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the restore options"))

            Menu {
                Button {
                    restoreTarget = BackupRestoreTarget(url: backup.url, title: BackupText.date(backup.createdAt))
                } label: {
                    Label("Restore", systemImage: "arrow.counterclockwise")
                }

                Button {
                    shareFile = ShareFile(url: BackupStore.shared.shareURL(for: backup))
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    toDelete = backup
                } label: {
                    Label("Delete", systemImage: "trash")
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
        .padding(.vertical, 5)
    }

    private func reload() {
        backups = BackupStore.shared.list()
    }

    private func backUpNow() {
        guard !working else {
            return
        }

        working = true

        BackupStore.shared.backupNowAsync { result in
            working = false

            switch result {
            case .success:
                ToastCenter.shared.success(String(localized: "Backup saved"))
            case let .failure(error):
                ToastCenter.shared.error(error.localizedDescription)
            }

            reload()
        }
    }
}

/// Bottom card with what a backup holds and the two ways to restore it.
struct BackupRestoreCard: View {
    let target: BackupRestoreTarget

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var systemColorScheme

    @AppStorage("bottomEdge", store: UserDefaults.appGroup) var bottomEdge: Double = 15

    private enum Phase {
        case reading
        case ready(created: Date, transactions: Int, missing: Int)
        case unreadable(String)
        case restoring
    }

    @State private var phase = Phase.reading
    @State private var confirmReplace = false
    @State private var offset: CGFloat = 0

    private var isBusy: Bool {
        if case .restoring = phase {
            return true
        }

        return false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isBusy {
                        dismiss()
                    }
                }

            VStack(alignment: .leading, spacing: 1.5) {
                Text("Restore backup")
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .foregroundColor(.PrimaryText)

                Text(target.title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(.SubtitleText)
                    .lineLimit(2)
                    .padding(.bottom, 12)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.PrimaryBackground).shadow(color: systemColorScheme == .dark ? Color.clear : Color.gray.opacity(0.25), radius: 6))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(systemColorScheme == .dark ? Color.gray.opacity(0.1) : Color.clear, lineWidth: 1.3))
            .offset(y: offset)
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        if gesture.translation.height < 0 {
                            offset = gesture.translation.height / 3
                        } else {
                            offset = gesture.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 20, !isBusy {
                            dismiss()
                        } else {
                            withAnimation {
                                offset = 0
                            }
                        }
                    }
            )
            .padding(.horizontal, 17)
            .padding(.bottom, bottomEdge == 0 ? 13 : bottomEdge)
        }
        .edgesIgnoringSafeArea(.all)
        .background(BackgroundBlurView())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            read()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 25)

            cancelButton
        case let .ready(created, transactions, missing):
            VStack(spacing: 0) {
                SettingsValueRow(title: "Made", value: BackupText.date(created))
                Divider()
                SettingsValueRow(title: "Transactions in the backup", value: MoneyFormat.number(Double(transactions)))
                Divider()
                SettingsValueRow(title: "Not in the app now", value: MoneyFormat.number(Double(missing)), valueColor: missing > 0 ? Color.PrimaryText : Color.SubtitleText)
            }
            .padding(.horizontal, 12)
            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
            .padding(.bottom, 12)

            Button {
                restore(.mergeMissing)
            } label: {
                Text("Add what is missing")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.LightIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
                    .frame(height: 45)
                    .frame(maxWidth: .infinity)
                    .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.bottom, 8)

            Button {
                if confirmReplace {
                    restore(.replaceAll)
                } else {
                    Haptics.warning()

                    withAnimation(.easeOut(duration: 0.15)) {
                        confirmReplace = true
                    }
                }
            } label: {
                DeleteButton(text: confirmReplace ? String(localized: "Tap again to replace everything") : String(localized: "Replace everything"), red: true)
            }
            .padding(.bottom, confirmReplace ? 4 : 8)

            if confirmReplace {
                Text("Everything in the app is replaced with this backup. A safety backup of the current data is made first.")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(.SubtitleText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }

            cancelButton
        case let .unreadable(message):
            Text(message)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Color.AlertRed)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 15)

            cancelButton
        case .restoring:
            HStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Restoring...")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                Spacer()
            }
            .padding(.vertical, 25)
        }
    }

    private var cancelButton: some View {
        Button {
            dismiss()
        } label: {
            DeleteButton(text: String(localized: "Cancel"), red: false)
        }
    }

    private func read() {
        let url = target.url

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Phase

            do {
                let document = try BackupStore.shared.readDocument(at: url)
                let missing = BackupStore.shared.missingTransactionCount(in: document)
                outcome = .ready(created: document.meta.createdAt, transactions: document.transactions.count, missing: missing)
            } catch {
                outcome = .unreadable(error.localizedDescription)
            }

            DispatchQueue.main.async {
                phase = outcome
            }
        }
    }

    private func restore(_ mode: BackupStore.RestoreMode) {
        guard !isBusy else {
            return
        }

        phase = .restoring

        // A file from Files stays readable only while the scope is open.
        let url = target.url
        let scoped = url.startAccessingSecurityScopedResource()

        BackupStore.shared.restoreAsync(from: url, mode: mode) { result in
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }

            switch result {
            case let .success(restored):
                ToastCenter.shared.success(String(localized: "Restored transactions: \(restored.transactions)"))
            case let .failure(error):
                ToastCenter.shared.error(error.localizedDescription)
            }

            dismiss()
        }
    }
}
