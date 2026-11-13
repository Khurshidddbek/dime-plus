//
//  ContentView.swift
//
//  Created by Rafael Soh on 3/6/22.
//

import SwiftUI
import WidgetKit

struct ContentView: View {
    @EnvironmentObject var appLockVM: AppLockViewModel
    @EnvironmentObject var dataController: DataController

    @ObservedObject var persistence = PersistenceStatus.shared

    @AppStorage("colourScheme", store: UserDefaults.appGroup) var colourScheme: Int = 0
    @Environment(\.scenePhase) var scenePhase
    @AppStorage("showNotifications", store: UserDefaults.appGroup) var showNotifications: Bool = false
    @AppStorage("notificationsEnabled", store: UserDefaults.appGroup) var notificationsEnabled: Bool = true

    @AppStorage("firstLaunch", store: UserDefaults.appGroup) var firstLaunch: Bool = true

    // adds category orders
    @AppStorage("dataMigration1", store: UserDefaults.appGroup) var dataMigration1: Bool = true

    // converts category colors to hex codes
    @AppStorage("dataMigration2", store: UserDefaults.appGroup) var dataMigration2: Bool = true

    @AppStorage("currency", store: UserDefaults.appGroup) var currency: String = Locale.current.currency?.identifier ?? "USD"

    @State var showIntro: Bool = false
    @State var showUpdate: Bool = false

    var center = UNUserNotificationCenter.current()

    @AppStorage("topEdge", store: UserDefaults.appGroup) var savedTopEdge: Double = 30
    @AppStorage("bottomEdge", store: UserDefaults.appGroup) var savedBottomEdge: Double = 15

    // updateSheetShowing

    @AppStorage("previousVersion", store: UserDefaults.appGroup) var previousVersionString: String = "Version \(UIApplication.appVersion ?? "") (\(UIApplication.buildNumber ?? ""))"

    @AppStorage("showUpdateSheet", store: UserDefaults.appGroup) var showUpdateSheet: Bool = true

    var body: some View {
        Group {
            if persistence.isStoreLoaded {
                GeometryReader { proxy in
                    let topEdge = proxy.safeAreaInsets.top
                    let bottomEdge = proxy.safeAreaInsets.bottom

                    HomeView(topEdge: topEdge, bottomEdge: bottomEdge == 0 ? 15 : bottomEdge)
                        .ignoresSafeArea(.all, edges: .bottom)
                        .preferredColorScheme(colourScheme == 1 ? .light : colourScheme == 2 ? .dark : nil)
                        .fullScreenCover(isPresented: $showIntro) {
                            WelcomeSheetView()
                        }
                        .fullScreenCover(isPresented: $showUpdate) {
                            UpdateAlert()
                        }
                        .onAppear {
                            savedTopEdge = topEdge
                            savedBottomEdge = bottomEdge
                        }
                }
                .ignoresSafeArea(.keyboard)
            } else {
                // The store did not open: no Log on top of an empty in-memory store.
                StoreRecoveryView(error: persistence.storeLoadError) {
                    let loaded = persistence.retryLoadStore()

                    if loaded {
                        runFirstLaunchSetup()
                        runDataMigrations()
                        runLaunchMaintenance()
                    }

                    return loaded
                }
                .preferredColorScheme(colourScheme == 1 ? .light : colourScheme == 2 ? .dark : nil)
            }
        }
        // Root toast host. Sheets and covers mount their own, the last mounted one draws.
        .toastHost()
        .onAppear {
//            UserDefaults.appGroup.set(false, forKey: "newTransactionAdded")
//            WidgetCenter.shared.reloadTimelines(ofKind: "TemplateTransactions")

            // The lock prompt is started by AppLockWindowController (attached in HomeView).

            let defaults =
                UserDefaults.appGroup

            if defaults.object(forKey: "firstDayOfMonth") == nil {
                defaults.set(1, forKey: "firstDayOfMonth")
            }

            runFirstLaunchSetup()

            // The local setting wins. iCloud KVS only seeds a device that has no currency yet,
            // otherwise a stale synced value would replace the user's choice on every launch.
            if defaults.string(forKey: "currency") == nil {
                let keyValueStore = NSUbiquitousKeyValueStore.default

                if let syncedCurrency = keyValueStore.string(forKey: "currency"), !syncedCurrency.isEmpty {
                    defaults.set(syncedCurrency, forKey: "currency")
                } else {
                    let localCurrency = Locale.current.currency?.identifier ?? "USD"
                    defaults.set(localCurrency, forKey: "currency")
                    keyValueStore.set(localCurrency, forKey: "currency")
                }
            }

            runDataMigrations()
            runLaunchMaintenance()
            SMSRouter.shared.sceneBecameActive()

            // Both covers hang on HomeView, which is not on screen while the store is closed.
            if showUpdateSheet && persistence.isStoreLoaded {
                showUpdate = true
                showUpdateSheet = false
            }

            center.getNotificationSettings { settings in
                if settings.authorizationStatus == .authorized {
                    if !showNotifications && notificationsEnabled == false {
                        showNotifications = true
                        notificationsEnabled = true
                        newNotification()
                    }
                } else if settings.authorizationStatus == .denied {
                    notificationsEnabled = false

                    if showNotifications {
                        showNotifications = false
                        center.removeAllPendingNotificationRequests()
                    }
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background || newPhase == .inactive {
                // Only a real trip to the background locks. The lock window covers the
                // inactive state (app switcher, Control Centre) by itself.
                if newPhase == .background && appLockVM.isAppLockEnabled {
                    appLockVM.isAppUnLocked = false
                }

                // Second chance for anything a failed save left in memory.
                dataController.save(newPhase == .background ? "scene background" : "scene inactive")

                if newPhase == .background {
                    DiagnosticsLog.shared.log("app", "background")

                    let task = BackgroundTaskBox(name: "dime.backup")

                    BackupStore.shared.backupIfDue { _ in
                        task.end()
                    }
                }
            } else if newPhase == .active {
                runLaunchMaintenance()
                // Picks up what the Shortcuts automation stored in background, checks the
                // clipboard (no paste prompt) and clears the delivered notification.
                SMSRouter.shared.sceneBecameActive()

                center.getNotificationSettings { settings in
                    if settings.authorizationStatus == .authorized {
                        if !showNotifications && notificationsEnabled == false {
                            showNotifications = true
                            notificationsEnabled = true
                            newNotification()
                        }
                    } else if settings.authorizationStatus == .denied {
                        notificationsEnabled = false

                        if showNotifications {
                            showNotifications = false
                            center.removeAllPendingNotificationRequests()
                        }
                    }
                }
            }
        }
    }

    // Waits for an open store: the welcome cover hangs on HomeView, and after a failed
    // first launch the intro would be marked as shown without ever appearing.
    private func runFirstLaunchSetup() {
        guard firstLaunch, persistence.isStoreLoaded else {
            return
        }

        let defaults = UserDefaults.appGroup

        showIntro = true
        showUpdate = false
        firstLaunch = false
        showUpdateSheet = false

        defaults.set(UserDefaults.regionFirstWeekday, forKey: "firstWeekday")
        defaults.set(true, forKey: "weekStartRegionMigrated")
        defaults.set(1, forKey: "haptics")
        defaults.set(1, forKey: "firstDayOfMonth")
        defaults.set(1, forKey: "notificationOption")
        defaults.set(false, forKey: "confetti")
        defaults.set(false, forKey: "chromatic")
        defaults.set(true, forKey: "showCents")
        defaults.set(true, forKey: "animated")

        defaults.set(2, forKey: "numberEntryType")
    }

    // One-time migrations. They must not be marked done while the store is not open.
    private func runDataMigrations() {
        migrateWeekStartToRegion()

        guard dataController.isStoreLoaded else {
            return
        }

        if dataMigration1 {
            let categoryFetch = dataController.fetchRequestForCategoriesMigration(income: false)
            let categories = dataController.results(for: categoryFetch)

            categories.forEach { category in
                category.order = Int64(categories.firstIndex(of: category) ?? 0)
            }

            if !dataController.save("migration 1").isFailure {
                dataMigration1 = false
            }
        }

        if dataMigration2 {
            let categoryFetch = dataController.fetchRequestForCategoriesMigration()
            let categories = dataController.results(for: categoryFetch)

            categories.forEach { category in
                if category.income {
                    category.colour = "#76FBB1"
                } else {
                    if Double(category.wrappedColour) != nil {
                        category.colour = Color.colourMigrationDictionary[category.wrappedColour] ?? "#FFFFFF"
                    }
                }
            }

            if !dataController.save("migration 2").isFailure {
                dataMigration2 = false
            }
        }
    }

    // Older builds always wrote Sunday on first launch, so a Monday region was ignored.
    // Runs once; a day picked in Settings later is kept.
    private func migrateWeekStartToRegion() {
        let defaults = UserDefaults.appGroup
        guard !defaults.bool(forKey: "weekStartRegionMigrated") else {
            return
        }

        if defaults.integer(forKey: "firstWeekday") == 1 && UserDefaults.regionFirstWeekday == 2 {
            defaults.set(2, forKey: "firstWeekday")
        }
        defaults.set(true, forKey: "weekStartRegionMigrated")
    }

    // Cheap checks for launch and every return to the foreground.
    private func runLaunchMaintenance() {
        guard dataController.isStoreLoaded else {
            return
        }

        persistence.checkIntegrity()
        TrashStore.shared.purgeExpired()
        BackupStore.shared.backupIfDue()
    }
}

/// Keeps the app alive in the background until `end()` is called or time runs out.
final class BackgroundTaskBox {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    /// Main thread only. Safe to call twice.
    func end() {
        guard identifier != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Shown instead of the app when the database could not be opened.
struct StoreRecoveryView: View {
    let error: NSError?
    /// Returns true when the store is open again.
    let retry: () -> Bool

    @State var diagnosticsURL: URL?
    @State var retryFailed = false
    @State var retrying = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .foregroundColor(Color.AlertRed)
                .padding(.bottom, 6)
                .accessibilityHidden(true)

            Text("Couldn't open your data")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundColor(Color.PrimaryText)
                .multilineTextAlignment(.center)

            Text("Nothing was deleted. Try again, and if it keeps failing, export the diagnostics file.")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .multilineTextAlignment(.center)

            if retryFailed {
                Text("Still can't open it")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.AlertRed)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.AlertRed.opacity(0.23), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .transition(.opacity)
            }

            if let error = error {
                Text(verbatim: "\(error.domain) \(error.code)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Color.SubtitleText)
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                tryAgain()
            } label: {
                Text("Try again")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.LightIcon)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                    .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .opacity(retrying ? 0.6 : 1)
            }
            .buttonStyle(BouncyButton(duration: 0.2, scale: 0.9))
            .disabled(retrying)

            if let diagnosticsURL = diagnosticsURL {
                ShareLink(item: diagnosticsURL) {
                    Text("Export diagnostics")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(BouncyButton(duration: 0.2, scale: 0.9))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.PrimaryBackground.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: retryFailed)
        .onAppear {
            prepareDiagnostics()
        }
    }

    private func tryAgain() {
        retrying = true
        retryFailed = false

        // Next run loop, so the pressed state is drawn before the store load blocks the main thread.
        DispatchQueue.main.async {
            let loaded = retry()
            retrying = false

            if loaded {
                Haptics.success()
            } else {
                retryFailed = true
                Haptics.error()
                prepareDiagnostics()
            }
        }
    }

    // The file is written up front, the share button needs a ready URL.
    private func prepareDiagnostics() {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = DiagnosticsLog.shared.exportURL()

            DispatchQueue.main.async {
                diagnosticsURL = url
            }
        }
    }
}
