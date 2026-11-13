//
//  SMSRouter.swift
//  dime
//
//  Glue between the SMS feature and the rest of the app: opening the inbox (deep link, intent,
//  entry card), the local notification and the clipboard chip. Nothing here needs AppDelegate.
//

import Combine
import SwiftUI
import UserNotifications

final class SMSRouter: ObservableObject {
    static let shared = SMSRouter()

    /// dimefork://smsinbox
    static let inboxHost = "smsinbox"

    static var inboxURL: URL? {
        URL(string: "\(AppIdentifiers.urlScheme)://\(inboxHost)")
    }

    /// The inbox cover is bound to this (see `smsInboxPresenter`).
    @Published var showInbox = false

    func openInbox() {
        showInbox = true
    }

    /// For `.onOpenURL`. Returns true when the link was for the SMS inbox.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.host == Self.inboxHost else {
            return false
        }

        showInbox = true

        return true
    }

    /// Call when the scene becomes active: picks up what an automation stored while the app
    /// was in background, looks at the clipboard and clears the delivered notification.
    func sceneBecameActive() {
        SMSInboxStore.shared.reloadIfNeeded()
        SMSRuleStore.shared.reloadIfNeeded()
        SMSCardStore.shared.reloadIfNeeded()
        SMSClipboard.shared.check()
        SMSNotifier.clearDelivered()
    }
}

private struct SMSInboxPresenter: ViewModifier {
    @ObservedObject private var router = SMSRouter.shared
    @Environment(\.managedObjectContext) private var moc

    let editScreen: ((SMSDraftRequest) -> AnyView)?

    init(editScreen: ((SMSDraftRequest) -> AnyView)?) {
        self.editScreen = editScreen
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $router.showInbox) {
                SMSInboxView(editScreen: editScreen)
                    .environment(\.managedObjectContext, moc)
            }
    }
}

extension View {
    /// Mount once on the root screen (HomeView). `editScreen` builds the full entry screen for
    /// a suggestion; it must call `SMSIngestor.shared.completeEdit` after it saved.
    func smsInboxPresenter(editScreen: ((SMSDraftRequest) -> AnyView)? = nil) -> some View {
        modifier(SMSInboxPresenter(editScreen: editScreen))
    }
}

/// A quiet local notification about new suggestions. It only posts when the owner already allowed
/// notifications for the app; it never asks. Tapping it opens the app (routing a tap straight to
/// the inbox needs a UNUserNotificationCenterDelegate, see the handoff notes).
enum SMSNotifier {
    static let settingKey = "smsNotifications"
    static let identifier = "sms-inbox"

    static var isEnabled: Bool {
        // object(forKey:) on purpose: bool(forKey:) gives false for a key that was never set.
        UserDefaults.appGroup.object(forKey: settingKey) as? Bool ?? true
    }

    /// Main thread only.
    static func postNewSuggestions(total: Int) {
        guard isEnabled, total > 0, UIApplication.shared.applicationState != .active else {
            return
        }

        let title = String(localized: "Bank messages")
        let body = String(localized: "To review: \(total)")
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // The bank SMS has just made the phone buzz: ours stays silent.
            content.sound = nil
            content.threadIdentifier = identifier

            // The same identifier every time: a new one replaces the old one instead of stacking.
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    static func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// Decides whether to offer "Paste from clipboard". It never reads the clipboard by itself:
/// hasStrings and detectPatterns do not show the system paste prompt, reading the text does.
final class SMSClipboard: ObservableObject {
    static let shared = SMSClipboard()

    enum Hint {
        case none
        case possible // there is some text
        case likely // the text has a money amount in it
    }

    @Published private(set) var state: Hint = .none

    private var handledChangeCount = -1

    /// Main thread only.
    func check() {
        let pasteboard = UIPasteboard.general

        guard pasteboard.hasStrings, pasteboard.changeCount != handledChangeCount else {
            state = .none
            return
        }

        if state == .none {
            state = .possible
        }

        let checkedCount = pasteboard.changeCount
        // The key path form: the DetectionPattern constant for money amounts is hidden from Swift.
        let moneyAmounts: PartialKeyPath<UIPasteboard.DetectedValues> = \UIPasteboard.DetectedValues.moneyAmounts
        let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [moneyAmounts]

        pasteboard.detectPatterns(for: patterns) { [weak self] result in
            var likely = false

            if case let .success(found) = result {
                likely = found.contains(moneyAmounts)
            }

            DispatchQueue.main.async {
                guard let self = self, self.state != .none, UIPasteboard.general.changeCount == checkedCount else {
                    return
                }

                self.state = likely ? .likely : .possible
            }
        }
    }

    /// Reads the text (this is the moment iOS may ask for the paste permission) and hides the chip
    /// until the clipboard changes again.
    func read() -> String? {
        let text = UIPasteboard.general.string

        markHandled()

        return text
    }

    /// Hides the chip for the current clipboard content (dismissed, or we copied something ourselves).
    func markHandled() {
        handledChangeCount = UIPasteboard.general.changeCount
        state = .none
    }

    /// Copies text without making our own chip light up.
    func copy(_ text: String) {
        UIPasteboard.general.string = text
        markHandled()
    }
}
