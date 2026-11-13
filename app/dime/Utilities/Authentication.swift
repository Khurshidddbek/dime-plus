//
//  Authentication.swift
//  Bonsai
//
//  Created by Rafael Soh on 7/7/22.
//

import Foundation
import LocalAuthentication
import SwiftUI
// All App Lock related methods will be handled here

class AppLockViewModel: ObservableObject {
    // Publishing the applock state from user defaults
    @Published var isAppLockEnabled: Bool = false
    // Publishing if the app is curretly unlocked or not
    @Published var isAppUnLocked: Bool = false

    @Published var enrollmentError: Bool = false

    init() {
        getAppLockState()
    }

    // To enable the AppLock in UserDefaults
    func enableAppLock() {
        UserDefaults.standard.set(true, forKey: "appLockEnabled")
        isAppLockEnabled = true
    }

    // To disable the AppLock in UserDefaults
    func disableAppLock() {
        UserDefaults.standard.set(false, forKey: "appLockEnabled")
        isAppLockEnabled = false
    }

    // To Publish the AppLock state
    func getAppLockState() {
        isAppLockEnabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
    }

    // True when the device can check its owner: Face ID / Touch ID, or the passcode alone.
    func checkIfBioMetricAvailable() -> Bool {
        var error: NSError?
        let laContext = LAContext()

        let isAvailable = laContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)

        if let error = error {
            DiagnosticsLog.shared.log("lock", "cannot authenticate: \(error.code)")
        }

        enrollmentError = !isAvailable

        return isAvailable
    }

    // This method used to change the AppLock state.
    // If user is going to enable the AppLock then 'appLockState' should be 'true' and vice versa
    func appLockStateChange(appLockState: Bool) {
        guard checkIfBioMetricAvailable() else {
            if !appLockState {
                // The passcode was removed after the lock was turned on: nothing can confirm
                // the owner any more, so the switch must not get stuck in the on position.
                disableAppLock()
                isAppUnLocked = true
                return
            }

            // Without a passcode there is nothing to lock with. Never leave the app for Settings.
            ToastCenter.shared.error(String(localized: "Set a device passcode first"))
            return
        }

        let laContext = LAContext()
        let reason = appLockState
            ? String(localized: "Turn on App Lock")
            : String(localized: "Turn off App Lock")

        laContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            guard success else {
                return
            }

            DispatchQueue.main.async {
                if appLockState {
                    self.enableAppLock()
                } else {
                    self.disableAppLock()
                }

                self.isAppUnLocked = true
            }
        }
    }

    // Kept for old call sites. The launch prompt is started by AppLockWindowController.
    func appLockValidation() {
        guard checkIfBioMetricAvailable() else {
            return
        }

        let laContext = LAContext()

        laContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock Dime")) { success, _ in
            guard success else {
                return
            }

            DispatchQueue.main.async {
                self.isAppUnLocked = true
            }
        }
    }
}
