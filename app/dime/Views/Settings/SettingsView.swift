//
//  SettingsView.swift
//  xpenz
//
//  Created by Rafael Soh on 20/5/22.
//

import Combine
import Foundation
import SwiftUI
import UserNotifications
import WidgetKit

struct SettingsView: View {
  @Environment(\.dynamicTypeSize) var dynamicTypeSize

  @AppStorage("colourScheme", store: UserDefaults.appGroup)
  var colourScheme: Int = 0
  var colourSchemeString: String {
    if colourScheme == 1 {
      return String(localized: "Light")
    } else if colourScheme == 2 {
      return String(localized: "Dark")
    } else {
      return String(localized: "System")
    }
  }

  @AppStorage("activeIcon", store: UserDefaults.appGroup)
  var activeIcon: String = "AppIcon"
  var appIconString: String {
    if activeIcon == "AppIcon1" {
      return "v2.0"
    } else if activeIcon == "AppIcon2" {
      return "Unicorn"
    } else if activeIcon == "AppIcon3" {
      return "v1.5"
    } else {
      return "O.G."
    }
  }

  @AppStorage("firstWeekday", store: UserDefaults.appGroup)
  var firstWeekday: Int = 1
  var firstWeekdayString: String {
    if firstWeekday == 1 {
      return String(localized: "Sunday")
    } else {
      return String(localized: "Monday")
    }
  }

  @AppStorage("showNotifications", store: UserDefaults.appGroup)
  var showNotifications: Bool = false
  @AppStorage("notificationOption", store: UserDefaults.appGroup)
  var option: Int = 1
  var notificationString: String {
    if showNotifications {
      if option == 1 {
        return String(localized: "Mornings")
      } else if option == 2 {
        return String(localized: "Evenings")
      } else {
        return String(localized: "Custom")
      }
    } else {
      return String(localized: "Off")
    }
  }

  @EnvironmentObject var appLockVM: AppLockViewModel
  @Namespace var animation

  // Same default as the pad itself (NumberPad.swift).
  @AppStorage("numberEntryType", store: UserDefaults.appGroup)
  var numberEntryType: Int = 1

  var numberEntryString: String {
    NumberEntryOption.stored(numberEntryType).shortName
  }

  @AppStorage("showCents", store: UserDefaults.appGroup)
  var showCents: Bool = true

  @AppStorage("animated", store: UserDefaults.appGroup) var animated:
    Bool = true

  @AppStorage("currency", store: UserDefaults.appGroup) var currency:
    String = MoneyFormat.defaultCurrencyCode

  @AppStorage("incomeTracking", store: UserDefaults.appGroup)
  var incomeTracking: Bool = true
    
  @AppStorage("showExpenseOrIncomeSign", store: UserDefaults.appGroup)
  var showExpenseOrIncomeSign: Bool = true

  @AppStorage(
    "showUpcomingTransactions", store: UserDefaults.appGroup)
  var showUpcoming: Bool = true

  var upcomingString: String {
    if showUpcoming {
      return String(localized: "Shown")
    } else {
      return String(localized: "Hidden")
    }
  }

    @AppStorage("haptics", store: UserDefaults.appGroup)
    var hapticType: Int = 1

    var hapticString: String {
      if hapticType == 0 {
        return String(localized: "None")
      } else if hapticType == 1 {
        return String(localized: "Subtle")
      } else {
        return String(localized: "Excessive")
      }
    }

  /// Currencies without small change: decimals and the entry method are fixed, so their rows are hidden.
  private var isZeroDecimal: Bool {
    MoneyFormat.isZeroDecimal(currency)
  }

  // popups

  @State var showImportGuide = false
  @State var showExport = false
  @State var showUpdate: Bool = false

  // Values on the right of the Data rows. Refreshed on appear and when a backup is written.
  @State private var cloudText = ""
  @State private var lastBackupText = ""

  @ObservedObject private var trash = TrashStore.shared

  @EnvironmentObject var tabBarManager: TabBarManager

  @EnvironmentObject var dataController: DataController

  /// SLOT: SMS import. It sits in the DATA card above "Import Data".
  /// Colour sets 128 to 130 and 115 are free.
  @ViewBuilder
  var smsSettingsEntry: some View {
    NavigationLink(destination: SMSSettingsView()) {
      SettingsRowView(systemImage: "message.fill", title: "Bank SMS", colour: 127)
    }
  }

  var body: some View {
    NavigationView {
      VStack {
        HStack {
          Text("Settings")
            .font(.system(.title, design: .rounded).weight(.semibold))

            //                        .font(.system(size: 25, weight: .semibold, design: .rounded))
            .accessibility(addTraits: .isHeader)
          Spacer()
        }
        .padding(.horizontal, 30)
        .padding(.top, 20)
        .padding(.bottom, 10)

        ScrollView(showsIndicators: false) {
          VStack(spacing: 5) {
            Text("GENERAL")
              .font(.system(.footnote, design: .rounded).weight(.semibold))

              //                            .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundColor(Color.SubtitleText)
              .padding(.horizontal, 10)
              .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 13) {

              NavigationLink(destination: SettingsNotificationsView()) {
                SettingsRowView(
                  systemImage: "bell.fill", title: "Notifications", colour: 102,
                  optionalText: notificationString)
              }

              NavigationLink(destination: SettingsCurrencyView()) {
                SettingsRowView(
                  systemImage: "coloncurrencysign.square.fill", title: "Currency", colour: 103,
                  optionalText: currency)
              }

              if !isZeroDecimal {
                NavigationLink(
                  destination: SettingsNumberEntryView()
                    .onAppear {
                      withAnimation(.easeOut.speed(1.5)) {
                        tabBarManager.navigationHideTab()
                      }
                    }
                    .onDisappear {
                      withAnimation(.easeOut.speed(1.5)) {
                        tabBarManager.navigationShowTab()
                      }
                    }
                ) {
                  SettingsRowView(
                    systemImage: "keyboard.fill", title: "Number Entry", colour: 104,
                    optionalText: numberEntryString)
                }
              }

              ToggleRow(
                icon: "faceid", color: "105", text: "Authentication",
                bool: appLockVM.isAppLockEnabled,
                onTap: {
                  appLockVM.appLockStateChange(appLockState: !appLockVM.isAppLockEnabled)
                })

              ToggleRow(
                icon: "banknote.fill", color: "106", text: "Income Tracking", bool: incomeTracking,
                onTap: {
                  incomeTracking.toggle()

                  if !incomeTracking {
                    UserDefaults.appGroup.set(
                      false, forKey: "insightsViewIncomeFiltering")
                    UserDefaults.appGroup.set(
                      3, forKey: "logInsightsType")
                  }
                })

              NavigationLink(destination: SettingsWeekStartView()) {
                SettingsRowView(systemImage: "calendar", title: "Time Frames", colour: 109)
              }
                
            }
            .padding(10)
            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 25)
          .onChange(of: currency) { _ in
            WidgetCenter.shared.reloadAllTimelines()
          }
          .onChange(of: firstWeekday) { _ in
            WidgetCenter.shared.reloadAllTimelines()
          }
          .onChange(of: showCents) { _ in
            WidgetCenter.shared.reloadAllTimelines()
          }

          VStack(spacing: 5) {
            Text("APPEARANCE")
              .font(.system(.footnote, design: .rounded).weight(.semibold))

              //                            .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundColor(Color.SubtitleText)
              .padding(.horizontal, 10)
              .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 13) {
              NavigationLink(destination: SettingsAppearanceView()) {
                SettingsRowView(
                  systemImage: "circle.righthalf.filled", title: "Theme", colour: 100,
                  optionalText: colourSchemeString)
              }

              NavigationLink(destination: SettingsAppIconView()) {
                SettingsRowView(
                  systemImage: "app.badge.fill", title: "App Icon", colour: 101,
                  optionalText: appIconString)
              }

              if !isZeroDecimal {
                ToggleRow(
                  icon: "centsign.circle.fill", color: "107", text: "Display Cents", bool: showCents,
                  onTap: {
                    showCents.toggle()
                  })
              }

              NavigationLink(destination: SettingsUpcomingView()) {
                SettingsRowView(
                  systemImage: "sun.min.fill", title: "Upcoming Logs", colour: 108,
                  optionalText: upcomingString)
              }
                
              ToggleRow(
                icon: "plusminus", color: "123", text: "Display +/- Symbol", bool: showExpenseOrIncomeSign,
                onTap: {
                    showExpenseOrIncomeSign.toggle()
                })

              ToggleRow(
                icon: "hare.fill", color: "121", text: "Animated Charts", bool: animated, smaller: true,
                onTap: {
                  animated.toggle()
                })

            }
            .padding(10)
            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 25)

          VStack(spacing: 5) {
            Text("DATA")
              .font(.system(.footnote, design: .rounded).weight(.semibold))

              //                            .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundColor(Color.SubtitleText)
              .padding(.horizontal, 10)
              .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 13) {
              NavigationLink(
                destination: SettingsCategoryView()
                  .onAppear {
                    withAnimation(.easeOut.speed(1.5)) {
                      tabBarManager.navigationHideTab()
                    }
                  }
                  .onDisappear {
                    withAnimation(.easeOut.speed(1.5)) {
                      tabBarManager.navigationShowTab()
                    }
                  }

              ) {
                SettingsRowView(
                  systemImage: "rectangle.grid.2x2.fill", title: "Categories", colour: 110)
              }

              NavigationLink(destination: SettingsCloudView()) {
                SettingsRowView(
                  systemImage: "icloud.fill", title: "iCloud Sync", colour: 111,
                  optionalText: cloudText)
              }

              NavigationLink(destination: SettingsBackupsView()) {
                SettingsRowView(
                  systemImage: "externaldrive.fill.badge.timemachine", title: "Backups", colour: 124,
                  optionalText: lastBackupText)
              }

              NavigationLink(destination: SettingsTrashView()) {
                SettingsRowView(
                  systemImage: "arrow.uturn.backward.circle.fill", title: "Recently deleted", colour: 125,
                  optionalText: trash.items.isEmpty ? nil : MoneyFormat.number(Double(trash.items.count)))
              }

              //
              //                            NavigationLink(destination: SettingsQuickAddWidgetView()) {
              //                                SettingsRowView(systemImage: "bolt.square.fill", title: "Quick-Add Widget", colour: 115)
              //                            }

              smsSettingsEntry

              Button {
                showImportGuide = true
              } label: {
                SettingsRowView(
                  systemImage: "square.and.arrow.down.fill", title: "Import Data", colour: 112)
              }

              Button {
                Haptics.tap()
                showExport = true
              } label: {
                SettingsRowView(
                  systemImage: "square.and.arrow.up.fill", title: "Export Data", colour: 113)
              }

              NavigationLink(destination: SettingsDiagnosticsView()) {
                SettingsRowView(systemImage: "stethoscope", title: "Diagnostics", colour: 126)
              }

              NavigationLink(destination: SettingsEraseView()) {
                SettingsRowView(systemImage: "xmark.bin.fill", title: "Erase Data", colour: 114)
              }
            }
            .padding(10)
            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 25)

          VStack(spacing: 5) {
            Text("OTHERS")
              .font(.system(.footnote, design: .rounded).weight(.semibold))

              //                            .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundColor(Color.SubtitleText)
              .padding(.horizontal, 10)
              .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 13) {

                NavigationLink(destination: SettingsHapticsView()) {
                  SettingsRowView(
                    systemImage: "hand.tap.fill", title: "Haptics", colour: 100,
                    optionalText: hapticString)
                }

              NavigationLink(destination: SettingsGoofyView()) {
                SettingsRowView(systemImage: "flame.fill", title: "Feature Lab", colour: 122)
              }
            }
            .padding(10)
            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 15)

          VStack(spacing: 5) {
            HStack(spacing: 3) {
              Text("Version \(UIApplication.appVersion ?? "") (\(UIApplication.buildNumber ?? ""))")
                .font(.system(.footnote, design: .rounded).weight(.medium))

                //                                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(Color.SubtitleText)

              Text("·")
                .font(.system(.footnote, design: .rounded).weight(.medium))

                .foregroundColor(Color.SubtitleText)

              Text("What's New")
                .font(.system(.footnote, design: .rounded).weight(.medium))

                .foregroundColor(Color.PrimaryText)
                .onTapGesture {
                  showUpdate = true
                }
            }

            Text("Made with ❤️ by \(makeAttributedString()) from 🇸🇬")
              .font(.system(.footnote, design: .rounded).weight(.medium))

              .foregroundColor(Color.SubtitleText)
              .multilineTextAlignment(.center)
          }
          .padding(.horizontal, 25)
          .padding(.bottom, 95)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      }
      .navigationBarTitle("")
      .navigationBarHidden(true)
      .background(Color.PrimaryBackground)
      .fullScreenCover(isPresented: $showExport) {
        ExportDataCard()
      }
      .fullScreenCover(isPresented: $showUpdate) {
        UpdateAlert()
      }
      .fullScreenCover(isPresented: $showImportGuide) {
        ImportDataView()
      }
      .onAppear {
        refreshDataRows()
      }
      .onReceive(NotificationCenter.default.publisher(for: BackupStore.didChangeNotification)) { _ in
        refreshDataRows()
      }
    }
  }

  @ViewBuilder
    func ToggleRow(icon: String, color: String, text: String, bool: Bool, smaller: Bool = false, onTap: @escaping () -> Void)
    -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
            .font(.system(smaller ? .subheadline : .body, design: .rounded))
        .foregroundColor(.white)
        .frame(
          width: dynamicTypeSize > .xLarge ? 40 : 30, height: dynamicTypeSize > .xLarge ? 40 : 30,
          alignment: .center
        )
        .background(Color(color), in: RoundedRectangle(cornerRadius: 6))

      Text(LocalizedStringKey(text))
        .font(.system(.body, design: .rounded).weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundColor(Color.PrimaryText)

      Spacer()

      ZStack(alignment: bool ? .trailing : .leading) {
        Capsule()
          .frame(width: 42, height: 28)
          .foregroundColor(bool ? .green : .gray.opacity(0.8))

        Circle()
          .foregroundColor(Color.white)
          .padding(2)
          .frame(width: 28, height: 28)
          .matchedGeometryEffect(id: "toggle\(color)", in: animation)
      }
    }
    .frame(maxWidth: .infinity)
    // The whole row is the target, not only the 28 pt capsule.
    .contentShape(Rectangle())
    .onTapGesture {
      Haptics.tap()

      withAnimation {
        onTap()
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(bool ? Text("On") : Text("Off"))
  }

  private func refreshDataRows() {
    cloudText = CloudSyncStatus.current(dataController).shortText

    if let newest = BackupStore.shared.list().first, newest.createdAt != Date.distantPast {
      lastBackupText = CloudSyncStatus.dateText(newest.createdAt)
    } else {
      lastBackupText = String(localized: "Never")
    }
  }

  func makeAttributedString() -> AttributedString {
    var string = AttributedString("Rafael")
    string.foregroundColor = Color.PrimaryText
    string.link = URL(string: "https://www.x.com/rarfell")

    return string
  }
}


struct SettingsRowView: View {
  var systemImage: String
  var title: String
  var colour: Int
  var optionalText: String?

  @Environment(\.dynamicTypeSize) var dynamicTypeSize

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(.body, design: .rounded))

        //                .font(.system(size: 17))
        //                .padding(5)
        .foregroundColor(.white)
        .frame(
          width: dynamicTypeSize > .xLarge ? 40 : 30, height: dynamicTypeSize > .xLarge ? 40 : 30,
          alignment: .center
        )
        .background(Color("\(colour)"), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

      Text(LocalizedStringKey(title))
        .font(.system(.body, design: .rounded).weight(.medium))

        //                .font(.system(size: 17, weight: .medium, design: .rounded))
        .lineLimit(1)
        .foregroundColor(Color.PrimaryText)

      Spacer()

      if let optionalText = optionalText {
        Text(optionalText)
          .font(.system(.body, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .foregroundColor(.DarkIcon.opacity(0.6))
          .layoutPriority(1)
          .padding(.trailing, -8)
      }

      Image(systemName: "chevron.forward")
        .font(.system(.subheadline, design: .rounded))
        //                .font(.system(size: 15))
        .foregroundColor(.DarkIcon.opacity(0.6))
    }
    .frame(maxWidth: .infinity)
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
  }
}

struct SettingsCategoryView: View {
  @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>

  var body: some View {
    CategoryView(mode: .settings, income: false)
      .navigationBarBackButtonHidden(true)
      .navigationBarTitle("")
      .navigationBarHidden(true)
      .background(Color.PrimaryBackground)
  }
}
