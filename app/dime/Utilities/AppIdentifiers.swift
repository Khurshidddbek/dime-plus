//
//  AppIdentifiers.swift
//  dime
//

import Foundation

// Compiled into all 4 targets. Must match the entitlements files, the bundle ids
// in the project and the URL scheme in dime/Info.plist.
enum AppIdentifiers {
    static let bundleID = "uz.khurshidbek.dime"
    static let appGroup = "group.uz.khurshidbek.dime"
    static let cloudContainer = "iCloud.uz.khurshidbek.dime"
    static let urlScheme = "dimefork"

    // Set to false when the app is signed with a free Apple ID: such a team cannot have the
    // iCloud capability, and CloudKit mirroring without the entitlement fails at launch.
    // The data then stays on the device only (backups in Files still work).
    static let cloudSyncEnabled = true

    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
}

extension UserDefaults {
    // Falls back to .standard so a signing mistake never crashes the app or an extension.
    static let appGroup: UserDefaults = UserDefaults(suiteName: AppIdentifiers.appGroup) ?? .standard
}
