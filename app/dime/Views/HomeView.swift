//
//  HomeView.swift
//  xpenz
//
//  Created by Rafael Soh on 20/5/22.
//

import ConfettiSwiftUI
import Foundation
import SwiftUI

/// A delete waiting for confirmation. A value copy: the card can keep its text
/// while it slides away after the row is gone.
struct LogPendingDelete: Equatable {
    let row: LogRowModel
    let future: Bool
    let stopsRecurring: Bool
}

/// What the Log asks the root screen to present. Rows do not observe it (see LogActions),
/// only the small hosts below do, so a tap on a row redraws nothing else.
final class OverallTransactionManager: ObservableObject {
    static let shared = OverallTransactionManager()

    @Published var toEdit: Transaction?
    /// Same as `toEdit` while search is open: the editor is presented from the search cover.
    @Published var searchToEdit: Transaction?
    /// Source row for "Duplicate": the editor opens prefilled, nothing is saved until confirmed.
    @Published var toDuplicate: Transaction?
    @Published var searchToDuplicate: Transaction?
    @Published var pendingDelete: LogPendingDelete?
    @Published var showPopup: Bool = false

    var searchActive = false
}

struct HomeView: View {
    @EnvironmentObject var appLockVM: AppLockViewModel
    @EnvironmentObject var tabBarManager: TabBarManager

    // Not observed here on purpose: publishing must not rebuild the whole tab view.
    let transactionManager = OverallTransactionManager.shared

    @State var currentTab = "Log"

    var topEdge: CGFloat
    var bottomEdge: CGFloat

    @State var counter = 0

    // Hiding Native TabBar...
    init(topEdge: CGFloat, bottomEdge: CGFloat) {
        UITabBar.appearance().isHidden = true
        self.topEdge = topEdge
        self.bottomEdge = bottomEdge
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $currentTab) {
                LogView(topEdge: topEdge, bottomEdge: bottomEdge)
                    .ignoresSafeArea(.all)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag("Log")

                InsightsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag("Insights")

                BudgetView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag("Budget")

                SettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag("Settings")
            }

            PersistenceNotices(currentTab: $currentTab)
                .padding(.bottom, 70 + bottomEdge)
                .offset(y: tabBarManager.hideTab ? (60 + bottomEdge) : 0)

            CustomTabBar(currentTab: $currentTab, topEdge: topEdge, bottomEdge: bottomEdge, counter: $counter)
                .offset(y: tabBarManager.hideTab ? (70 + bottomEdge) : 0)

            DeletePopupLayer()

            // The real cover is a window above sheets and covers (AppLockWindowController).
            // This one hides the first frame and stays as a fallback if the window cannot be made.
            if appLockVM.isAppLockEnabled && !appLockVM.isAppUnLocked {
                AppLockView()
                    .ignoresSafeArea(.all)
            }
        }
        .background(TransactionCoverHost(inSearch: false))
        // The only place the SMS inbox is presented from. The full entry screen opens from
        // inside that cover, so it gets its environment here.
        .smsInboxPresenter { request in
            AnyView(
                TransactionView(
                    draft: TransactionEntryDraft(
                        amount: request.amount, income: request.income, date: request.date,
                        note: request.note, categoryID: request.categoryID
                    )
                ) { saved, id in
                    if saved {
                        SMSIngestor.shared.completeEdit(suggestionID: request.id, transactionID: id)
                    }
                }
                .environmentObject(DataController.shared)
                .environmentObject(OverallTransactionManager.shared)
            )
        }
        .confettiCannon(counter: $counter, num: 50, openingAngle: Angle(degrees: 0), closingAngle: Angle(degrees: 360), radius: 200)
        .onAppear {
            // Asks for Face ID / passcode at launch when the lock is on (first call only).
            AppLockWindowController.shared.attach(appLockVM, promptNow: true)
        }
        .onOpenURL { url in
            if SMSRouter.shared.handle(url) {
                currentTab = "Log"
            } else if url.host == "search" {
                currentTab = "Log"
            } else if url.host == "insights" {
                currentTab = "Insights"
            } else if url.host == "budget" {
                currentTab = "Budget"
            }
        }
        // Last, so the tab bar and the covers presented above also get it.
        .environmentObject(transactionManager)
    }
}

/// Presents the editor for the row picked in the Log. A view of its own, so only this
/// zero-size host is redrawn when a row is tapped.
struct TransactionCoverHost: View {
    let inSearch: Bool

    @ObservedObject var manager = OverallTransactionManager.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fullScreenCover(item: inSearch ? $manager.searchToEdit : $manager.toEdit) { transaction in
                TransactionView(toEdit: transaction)
            }
            .background(
                Color.clear
                    .frame(width: 0, height: 0)
                    .fullScreenCover(item: inSearch ? $manager.searchToDuplicate : $manager.toDuplicate) { transaction in
                        TransactionView(duplicating: transaction)
                    }
            )
    }
}

/// The confirmation card for a half swipe, with the layer that closes it on an outside tap.
struct DeletePopupLayer: View {
    @ObservedObject var manager = OverallTransactionManager.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if manager.showPopup {
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        LogActions.cancelPendingDelete()
                    }
                    .accessibilityHidden(true)
            }

            DeleteTransactionAlert()
                .offset(y: manager.showPopup ? 0 : 600)
                // The card stays in the tree after it slid away: VoiceOver must not reach its Delete button.
                .accessibilityHidden(!manager.showPopup)
        }
    }
}

/// "Not saved" and "entries went missing" pills above the tab bar.
struct PersistenceNotices: View {
    @Binding var currentTab: String

    @ObservedObject var persistence = PersistenceStatus.shared

    var body: some View {
        VStack(spacing: 8) {
            if persistence.saveFailure != nil {
                Button {
                    if persistence.retrySave() {
                        ToastCenter.shared.success(String(localized: "Saved"))
                    }
                } label: {
                    pill(Text("Not saved - tap to retry"), icon: "exclamationmark.triangle.fill", tint: Color.AlertRed)
                }
                .buttonStyle(BouncyButton(duration: 0.2, scale: 0.95))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !persistence.missingTransactionIDs.isEmpty {
                Button {
                    Haptics.tap()
                    currentTab = "Settings"
                    persistence.clearMissing()
                } label: {
                    pill(
                        Text("\(persistence.missingTransactionIDs.count) entries went missing. Check Backups in Settings."),
                        icon: "questionmark.folder.fill",
                        tint: Color.PrimaryText
                    )
                }
                .buttonStyle(BouncyButton(duration: 0.2, scale: 0.95))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.2), value: persistence.saveFailure != nil)
        .animation(.easeInOut(duration: 0.2), value: persistence.missingTransactionIDs.count)
    }

    func pill(_ text: Text, icon: String, tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        return HStack(spacing: 6.5) {
            Image(systemName: icon)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))

            text
                .font(.system(.body, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .foregroundColor(tint)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(tint.opacity(0.23), in: shape)
        .background(Color.PrimaryBackground, in: shape)
        .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 3)
        .contentShape(shape)
    }
}

struct AppLockView: View {
    @EnvironmentObject var appLockVM: AppLockViewModel

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "lock.fill")
                .font(.system(size: 65))
                .foregroundColor(Color.DarkIcon.opacity(0.7))
                .accessibilityHidden(true)

            Text("App Locked")
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundColor(Color.PrimaryText)
                .padding(.bottom, 30)

            Button {
                AppLockWindowController.shared.authenticate()
            } label: {
                HStack {
                    Image(systemName: "faceid")

                    Text("Unlock App")
                }
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundColor(Color.PrimaryText)
                .padding(.horizontal, 40)
                .padding(.vertical, 15)
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(Color.Outline)
                }
                .contentShape(RoundedRectangle(cornerRadius: 13))
            }

            if appLockVM.enrollmentError {
                Text("Turn on a passcode or Face ID in the Settings app to unlock.")
                    .font(.system(.subheadline, design: .rounded).weight(.regular))
                    .foregroundColor(Color.SubtitleText)
                    .multilineTextAlignment(.center)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.PrimaryBackground.ignoresSafeArea())
    }
}
