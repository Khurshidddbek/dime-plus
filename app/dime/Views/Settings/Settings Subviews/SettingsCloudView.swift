//
//  SettingsCloudView.swift
//  dime
//
//  Created by Rafael Soh on 5/11/23.
//

import Combine
import CoreData
import Foundation
import SwiftUI

/// What is really known about iCloud sync. The old "Enable Sync" switch changed nothing
/// in the store, so this screen only reports.
enum CloudSyncStatus {
    case error(String)
    case uploaded(Date)
    case waiting
    case unavailable

    static func current(_ dataController: DataController) -> CloudSyncStatus {
        if !AppIdentifiers.cloudSyncEnabled {
            return .unavailable
        }

        if let error = dataController.lastCloudError {
            return .error(error.localizedDescription)
        }

        if let date = dataController.lastCloudExportDate {
            return .uploaded(date)
        }

        // No token: not signed in to iCloud, or the build has no iCloud access.
        if FileManager.default.ubiquityIdentityToken == nil {
            return .unavailable
        }

        return .waiting
    }

    static func dateText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return Fmt.time(date)
        }

        return Fmt.string(.dayMonth, from: date) + ", " + Fmt.time(date)
    }

    /// Value on the right of the Settings row.
    var shortText: String {
        switch self {
        case .error:
            return String(localized: "Error")
        case let .uploaded(date):
            return CloudSyncStatus.dateText(date)
        case .waiting:
            return String(localized: "Waiting")
        case .unavailable:
            return String(localized: "Off")
        }
    }

    var title: String {
        switch self {
        case .error:
            return String(localized: "Sync error")
        case .uploaded:
            return String(localized: "Uploaded to iCloud")
        case .waiting:
            return String(localized: "Waiting for the first upload")
        case .unavailable:
            return String(localized: "iCloud is not available")
        }
    }

    var detail: String {
        switch self {
        case let .error(message):
            return message
        case let .uploaded(date):
            return String(localized: "Last upload: \(CloudSyncStatus.dateText(date))")
        case .waiting:
            return String(localized: "Nothing was uploaded since the app was opened. Uploads start by themselves after a change.")
        case .unavailable:
            return String(localized: "Sign in to iCloud in the iOS Settings. A build signed without iCloud access cannot sync at all.")
        }
    }

    var icon: String {
        switch self {
        case .error:
            return "exclamationmark.icloud.fill"
        case .uploaded:
            return "checkmark.icloud.fill"
        case .waiting:
            return "icloud.fill"
        case .unavailable:
            return "icloud.slash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .error:
            return Color.AlertRed
        case .uploaded:
            return Color.IncomeGreen
        case .waiting, .unavailable:
            return Color.SubtitleText
        }
    }
}

struct SettingsCloudView: View {
    @EnvironmentObject var dataController: DataController

    @State private var status = CloudSyncStatus.waiting
    @State private var events: [String] = []

    var body: some View {
        VStack(spacing: 10) {
            SettingsSubviewHeader(title: "iCloud Sync")
                .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: status.icon)
                            .font(.system(.title2, design: .rounded))
                            .foregroundColor(status.tint)
                            .frame(width: 34)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(status.title)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundColor(Color.PrimaryText)

                            Text(status.detail)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(Color.SubtitleText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .combine)

                    SettingsFootnote(text: "Sync cannot be switched on or off here: the old switch did not change anything. Dime mirrors its data to your private iCloud database whenever iCloud is available.")

                    SettingsFootnote(text: "iCloud is not a backup you can go back to. For that use Settings, Backups.")
                        .padding(.bottom, 8)

                    if !events.isEmpty {
                        SettingsSectionTitle(text: "RECENT SYNC EVENTS")

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(events.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(line.contains("FAILED") ? Color.AlertRed : Color.PrimaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.bottom, 90)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(SettingsSubviewModifier())
        .onAppear {
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification).receive(on: DispatchQueue.main)) { _ in
            // DataController records the event on the main queue too; read it a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                refresh()
            }
        }
    }

    private func refresh() {
        status = CloudSyncStatus.current(dataController)

        DispatchQueue.global(qos: .userInitiated).async {
            let recent = DiagnosticsLog.shared.recentLines(400).filter { $0.contains("cloudkit:") }.suffix(6)
            let newestFirst = Array(recent.reversed())

            DispatchQueue.main.async {
                events = newestFirst
            }
        }
    }
}
