//
//  SMSSettingsView.swift
//  dime
//
//  "Bank SMS" screen for Settings: the way into the inbox, the paste import, the rules
//  and the setup guide. Push it from the settings list with a NavigationLink.
//

import SwiftUI
import UserNotifications

struct SMSSettingsView: View {
    private enum Screen: Identifiable {
        case paste
        case rules
        case guide

        var id: Int {
            switch self {
            case .paste: return 0
            case .rules: return 1
            case .guide: return 2
            }
        }
    }

    @ObservedObject private var inbox = SMSInboxStore.shared
    @ObservedObject private var ruleStore = SMSRuleStore.shared
    @ObservedObject private var cardStore = SMSCardStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var moc

    @AppStorage(SMSNotifier.settingKey, store: UserDefaults.appGroup) private var notifications: Bool = true

    @State private var screen: Screen?
    @State private var selfCheck: String?

    init() {}

    var body: some View {
        VStack(spacing: 10) {
            SMSScreenHeader("Bank SMS", onClose: { dismiss() })
                .padding(.bottom, 12)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) {
                        row("Messages to review", value: inbox.pending.isEmpty ? "" : "\(inbox.pending.count)") {
                            SMSRouter.shared.openInbox()
                        }

                        Divider()

                        row("Paste messages", value: "") {
                            screen = .paste
                        }

                        Divider()

                        row("Rules and cards", value: ruleStore.rules.isEmpty ? "" : "\(ruleStore.rules.count)") {
                            screen = .rules
                        }

                        Divider()

                        row("Set up automation", value: "") {
                            screen = .guide
                        }
                    }
                    .padding(.horizontal, 15)
                    .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    footnote(automationLine)

                    SMSToggleRow(
                        title: "Notify about new messages",
                        caption: "A quiet notification when a message waits for review.",
                        isOn: notifications
                    ) { value in
                        setNotifications(value)
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 4)
                    .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.top, 8)

                    footnote(String(localized: "Messages are read on this phone only. Each one waits for your review unless a rule for its merchant is set to add automatically."))

                    #if DEBUG
                        Button {
                            runSelfCheck()
                        } label: {
                            Text(verbatim: selfCheck ?? "Debug: run the parser self-check")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(Color.SubtitleText)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 15)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    #endif
                }
            }
        }
        .modifier(SettingsSubviewModifier())
        .sheet(item: $screen) { item in
            sheetContent(item)
                .environment(\.managedObjectContext, moc)
        }
        .onAppear {
            inbox.reloadIfNeeded()
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: Screen) -> some View {
        switch item {
        case .paste:
            SMSPasteImportView()
        case .rules:
            SMSRulesView()
        case .guide:
            SMSSetupGuideView()
        }
    }

    private var automationLine: String {
        if let last = inbox.lastAutomationRunAt {
            return String(localized: "Last message from Shortcuts: \(Fmt.relative(last))")
        }

        return String(localized: "No message has come from Shortcuts yet. Set up the automation to get them as they arrive.")
    }

    private func row(_ title: LocalizedStringKey, value: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                if !value.isEmpty {
                    Text(verbatim: value)
                        .font(.system(.body, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Color.SubtitleText)
                }

                Image(systemName: "chevron.forward")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(Color.SubtitleText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footnote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundColor(Color.SubtitleText)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func setNotifications(_ value: Bool) {
        notifications = value

        guard value else {
            return
        }

        // Asked only here, after the owner switched it on himself.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { granted, _ in
            if !granted {
                ToastCenter.shared.info(String(localized: "Allow notifications for the app in iOS Settings"))
            }
        }
    }

    #if DEBUG
        private func runSelfCheck() {
            let failures = SMSParserSelfCheck.run()

            if failures.isEmpty {
                selfCheck = "Parser self-check: all samples are read as expected"
                Haptics.success()
            } else {
                selfCheck = failures.joined(separator: "\n")
                Haptics.error()
            }

            DiagnosticsLog.shared.log("sms", "self-check failures: \(failures.count)")
        }
    #endif
}
