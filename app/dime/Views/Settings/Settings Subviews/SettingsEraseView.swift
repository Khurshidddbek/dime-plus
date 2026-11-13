//
//  SettingsEraseView.swift
//  dime
//
//  Created by Rafael Soh on 5/11/23.
//

import Foundation
import SwiftUI

struct SettingsEraseView: View {
  @State var showAlert = false

  var body: some View {
    VStack(spacing: 10) {
      SettingsSubviewHeader(title: "Erase Data")
        .padding(.bottom, 10)

      Button {
        Haptics.tap()
        showAlert = true
      } label: {
        Text("Permanently Delete Everythin'")
          .font(.system(.body, design: .rounded))
          .foregroundColor(Color.AlertRed)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 15)
          .frame(minHeight: 46)
          .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      SettingsFootnote(
        text: "Deletes all transactions, categories, budgets and the Recently deleted list. A backup is saved first and stays in Settings, Backups until you delete it there."
      )
    }
    .modifier(SettingsSubviewModifier())
    .fullScreenCover(isPresented: $showAlert) {
      DeleteAllAlert()
    }
  }
}

struct DeleteAllAlert: View {
  @EnvironmentObject var dataController: DataController
  @Environment(\.dismiss) var dismiss
  @Environment(\.colorScheme) var systemColorScheme

  @AppStorage("bottomEdge", store: UserDefaults.appGroup)
  var bottomEdge: Double = 15

  @State private var offset: CGFloat = 0

  @GestureState var isDetectingLongPress = false
  @State var completedLongPress = false

  @State private var working = false
  // Set when the safety backup could not be written: the next long press erases without one.
  @State private var backupFailed = false

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
          if !working {
            dismiss()
          }
        }

      VStack(alignment: .leading, spacing: 1.5) {
        HStack(spacing: 7) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(.callout, design: .rounded).weight(.medium))

          Text("Danger Zone")
            .font(.system(.title2, design: .rounded).weight(.medium))
        }
        .foregroundColor(.PrimaryText)

        Group {
          if backupFailed {
            Text("The backup could not be saved. Long press again to erase without a backup.")
              .foregroundColor(Color.AlertRed)
          } else {
            Text("Everything is erased after a backup is saved. Long press to confirm.")
              .foregroundColor(.SubtitleText)
          }
        }
        .font(.system(.title3, design: .rounded).weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 15)

        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Rectangle()
              .fill(Color.AlertRed.opacity(0.23))
              .frame(width: proxy.size.width)

            Rectangle()
              .fill(Color.AlertRed)
              .frame(width: proxy.size.width, height: 100)
              .offset(x: completedLongPress ? 0 : (isDetectingLongPress ? 0 : -(proxy.size.width)))
              .animation(.easeInOut(duration: 2), value: isDetectingLongPress)

            HStack(spacing: 8) {
              if working {
                ProgressView()
                  .tint(.white)
              }

              Text(working ? LocalizedStringKey("Erasing...") : LocalizedStringKey("Delete Literally Everything"))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 8)
            .frame(width: proxy.size.width, alignment: .center)
          }
          .frame(height: proxy.size.height)
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(height: 45)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .gesture(
          LongPressGesture(minimumDuration: 2)
            .updating(
              $isDetectingLongPress,
              body: { currentState, state, _ in
                state = currentState
              }
            )
            .onEnded { _ in
              if !working {
                completedLongPress = true
              }
            }
        )
        .onChange(of: completedLongPress) { _ in
          if completedLongPress {
            Haptics.impact(.heavy)
            erase()
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Delete Literally Everything"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
          // VoiceOver cannot hold for 2 seconds; the double tap is the confirmation there.
          if !working {
            completedLongPress = true
          }
        }

        Button {
          withAnimation(.easeOut(duration: 0.7)) {
            dismiss()
          }

        } label: {
          DeleteButton(text: String(localized: "Back Out"), red: false)
        }
        .disabled(working)
      }
      .padding(13)
      .background(
        RoundedRectangle(cornerRadius: 13).fill(Color.PrimaryBackground).shadow(
          color: systemColorScheme == .dark ? Color.clear : Color.gray.opacity(0.25), radius: 6)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 13).stroke(
          systemColorScheme == .dark ? Color.gray.opacity(0.1) : Color.clear, lineWidth: 1.3)
      )
      .offset(y: offset)
      .gesture(
        DragGesture()
          .onChanged { gesture in
            if gesture.translation.height < 0 {
              offset = gesture.translation.height / 3
            } else {
              offset = gesture.translation.height
            }
          }
          .onEnded { value in
            if value.translation.height > 20, !working {
              dismiss()
            } else {
              withAnimation {
                offset = 0
              }
            }
          }
      )
      .padding(.horizontal, 17)
      .padding(.bottom, bottomEdge == 0 ? 13 : bottomEdge)
    }
    .edgesIgnoringSafeArea(.all)
    .background(BackgroundBlurView())
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
  }

  private func erase() {
    guard !working else {
      return
    }

    working = true

    if backupFailed {
      // The user was told and confirmed again.
      DiagnosticsLog.shared.log("erase", "confirmed without a backup")
      finishErase()
      return
    }

    BackupStore.shared.backupNowAsync(tag: "pre-erase") { result in
      switch result {
      case .success:
        finishErase()
      case let .failure(error):
        DiagnosticsLog.shared.log("erase", "stopped, no backup: \(DataController.describe(error as NSError))")
        Haptics.error()
        working = false
        backupFailed = true
        completedLongPress = false
      }
    }
  }

  private func finishErase() {
    let erased = dataController.deleteAll()

    if erased {
      // The trash holds copies of deleted rows; an erase that left them would not be one.
      TrashStore.shared.empty()
      // SMS rules, cards and the inbox point at categories that no longer exist.
      SMSFiles.eraseAll()
    }

    dismiss()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      if erased {
        ToastCenter.shared.success(String(localized: "Everything was erased"))
      } else {
        ToastCenter.shared.error(String(localized: "Some data could not be erased"))
      }
    }
  }
}
