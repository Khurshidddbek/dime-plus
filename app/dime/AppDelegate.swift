//
//  AppDelegate.swift
//  dime
//
//  Created by Rafael Soh on 24/8/22.
//

import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PersistenceStatus.shared.start()

        let version = "\(UIApplication.appVersion ?? "?") (\(UIApplication.buildNumber ?? "?"))"
        let state = application.applicationState == .background ? "background" : "foreground"
        DiagnosticsLog.shared.log("app", "launch version=\(version) state=\(state) transactions=\(DataController.shared.transactionCountForLog())")

        return true
    }

    func applicationWillTerminate(_: UIApplication) {
        DataController.shared.save("terminate")
        DiagnosticsLog.shared.log("app", "terminate")
        DiagnosticsLog.shared.flush()
    }

    func applicationDidReceiveMemoryWarning(_: UIApplication) {
        DiagnosticsLog.shared.log("app", "memory warning")
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let sceneConfiguration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        sceneConfiguration.delegateClass = SceneDelegate.self
        return sceneConfiguration
    }
}
