//
//  AppLockWindow.swift
//  dime
//
//  App target only. The lock cover lives in a window of its own above every sheet and
//  full screen cover. Inside the HomeView hierarchy it stayed under presented screens,
//  which were left readable and usable while the app was "locked".
//

import Combine
import LocalAuthentication
import SwiftUI
import UIKit

@MainActor
final class AppLockWindowController {
    static let shared = AppLockWindowController()

    private weak var viewModel: AppLockViewModel?
    private var window: UIWindow?
    private var cancellables = Set<AnyCancellable>()

    private var enabled = false
    private var unlocked = false
    private var isActive = true
    private var covering = false
    private var isEvaluating = false

    // Set when the app really goes to the background and cleared when the prompt starts.
    // The system Face ID sheet itself makes the app inactive and active again: asking on
    // every activation would bring the sheet back forever after a cancel.
    private var promptPending = false

    // Control Centre, the app switcher peek and system alerts only make the app inactive.
    // Coming back from those must not ask again.
    private var unlockedSinceBackground = false

    private init() {}

    /// Call once from the root screen. `promptNow` asks for Face ID right away when locked.
    func attach(_ viewModel: AppLockViewModel, promptNow: Bool = false) {
        guard self.viewModel == nil else {
            return
        }

        self.viewModel = viewModel
        enabled = viewModel.isAppLockEnabled
        unlocked = viewModel.isAppUnLocked
        unlockedSinceBackground = unlocked
        isActive = UIApplication.shared.applicationState == .active

        Publishers.CombineLatest(viewModel.$isAppLockEnabled, viewModel.$isAppUnLocked)
            .sink { [weak self] enabled, unlocked in
                self?.stateChanged(enabled: enabled, unlocked: unlocked)
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default

        center.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.willResignActive()
            }
            .store(in: &cancellables)

        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.didEnterBackground()
            }
            .store(in: &cancellables)

        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.didBecomeActive()
            }
            .store(in: &cancellables)

        updateWindow()

        if promptNow {
            authenticate()
        }
    }

    /// Face ID or Touch ID with the device passcode as the fallback.
    func authenticate() {
        guard let viewModel = viewModel, enabled, !unlocked, !isEvaluating else {
            return
        }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error = error, error.code == LAError.passcodeNotSet.rawValue {
                // The device has no passcode at all: there is nothing to check against.
                viewModel.isAppUnLocked = true
            } else {
                viewModel.enrollmentError = true
            }

            return
        }

        viewModel.enrollmentError = false
        isEvaluating = true

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock Dime")) { success, _ in
            Task { @MainActor [weak self] in
                self?.finishAuthentication(success: success)
            }
        }
    }

    private func finishAuthentication(success: Bool) {
        isEvaluating = false

        if success {
            Haptics.tap()
            viewModel?.isAppUnLocked = true
        }
    }

    // MARK: state

    private func stateChanged(enabled: Bool, unlocked: Bool) {
        self.enabled = enabled
        self.unlocked = unlocked

        if unlocked {
            unlockedSinceBackground = true
        }

        // Next turn: turning the lock on sets "enabled" and "unlocked" one after the other,
        // the cover must not flash in between.
        Task { @MainActor [weak self] in
            self?.updateWindow()
        }
    }

    private func willResignActive() {
        isActive = false
        updateWindow()
    }

    private func didEnterBackground() {
        unlockedSinceBackground = false
        promptPending = enabled
    }

    private func didBecomeActive() {
        isActive = true

        if enabled, !unlocked {
            if unlockedSinceBackground {
                viewModel?.isAppUnLocked = true
            } else if promptPending {
                promptPending = false
                authenticate()
            }
        }

        updateWindow()
    }

    // MARK: window

    // Covered while locked, and while the app is inactive so the app switcher shows no amounts.
    private func updateWindow() {
        let shouldCover = enabled && (!unlocked || !isActive)

        if shouldCover {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard !covering else {
            return
        }

        if window == nil {
            makeWindow()
        }

        guard let window = window else {
            return
        }

        covering = true

        // A keyboard would float above the cover.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        let scheme = UserDefaults.appGroup.integer(forKey: "colourScheme")
        window.overrideUserInterfaceStyle = scheme == 1 ? .light : (scheme == 2 ? .dark : .unspecified)
        window.alpha = 1
        window.isHidden = false
    }

    private func hide() {
        guard covering, let window = window else {
            return
        }

        covering = false

        UIView.animate(withDuration: 0.2, animations: {
            window.alpha = 0
        }, completion: { _ in
            // It may have been shown again during the fade.
            if !self.covering {
                window.isHidden = true
            }

            window.alpha = 1
        })
    }

    private func makeWindow() {
        guard let viewModel = viewModel else {
            return
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }

        let host = UIHostingController(rootView: AppLockView().environmentObject(viewModel))
        host.view.backgroundColor = UIColor(Color.PrimaryBackground)

        let created = UIWindow(windowScene: scene)
        created.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        created.rootViewController = host
        created.isHidden = true

        window = created
    }
}
