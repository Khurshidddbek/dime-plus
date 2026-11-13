//
//  CustomTabBar.swift
//  xpenz
//
//  Created by Rafael Soh on 20/5/22.
//

import Foundation
import SwiftUI

struct CustomTabBar: View {
    @EnvironmentObject var appLockVM: AppLockViewModel
    @Binding var currentTab: String
    var topEdge: CGFloat
    var bottomEdge: CGFloat
    @State var addTransaction: Bool = false

    // Count only: a fetch of every transaction lived here just to know whether the Log is empty.
    @ObservedObject var stats = LogFeed.shared.stats

    @State var count = 0
    @Binding var counter: Int

    @AppStorage("confetti", store: UserDefaults.appGroup) var confetti: Bool = false
    @AppStorage("firstTransactionViewLaunch", store: UserDefaults.appGroup) var firstLaunch: Bool = true

    @State var animate = false

    private var isZoomed: Bool {
        UIScreen.main.scale != UIScreen.main.nativeScale
    }

    var body: some View {
        HStack(spacing: 4) {
            TabButton(image: "Log", zoomed: isZoomed, currentTab: $currentTab)

            TabButton(image: "Insights", zoomed: isZoomed, currentTab: $currentTab)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.DarkBackground.opacity(0.6))
                    .frame(width: 95, height: 68)
                    .opacity(self.animate ? 0 : 1)
                    .scaleEffect(self.animate ? 1 : 0.4)

                RoundedRectangle(cornerRadius: 20.5, style: .continuous).fill(Color.DarkBackground.opacity(0.8))
                    .frame(width: 80, height: 53)
                    .opacity(self.animate ? 0 : 1)
                    .scaleEffect(self.animate ? 1 : 0.6)

                Button {
                    Haptics.tap()

                    addTransaction = true

                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(MyButtonStyle())
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
            }
            .onAppear {
                if stats.count == 0 {
                    withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: false)) {
                        self.animate.toggle()
                    }
                }
            }
            .accessibilityLabel("Add New Transaction")

            TabButton(image: "Budget", zoomed: isZoomed, currentTab: $currentTab)

            TabButton(image: "Settings", zoomed: isZoomed, currentTab: $currentTab)
        }
        .padding(.horizontal, 15)
        .padding(.bottom, bottomEdge - 10)
        .frame(maxWidth: .infinity)
        .background(Color.PrimaryBackground)
        .fullScreenCover(isPresented: $addTransaction, onDismiss: {
            if confetti {
                if count != stats.count {
                    counter += 1
                }
            }

            if firstLaunch {
                firstLaunch = false
            }

        }, content: {
            TransactionView(toEdit: nil)
        })
        .onChange(of: addTransaction) { _, presented in
            if presented {
                count = stats.count
            }
        }
        .onChange(of: stats.count) { _, newCount in
            self.animate = newCount == 0
        }
        .onOpenURL { url in
            guard
                url.host == "newExpense"

            else {
                return
            }

            addTransaction = true
        }
    }
}

struct MyButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(Color.LightIcon)
            .frame(width: 65, height: 38)
            .background(configuration.isPressed ? Color.SubtitleText : Color.DarkBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            // 44 pt tap target around the 38 pt key.
            .padding(.vertical, 3)
            .contentShape(Rectangle())
    }
}

struct BouncyButton: ButtonStyle {
    var duration: Double
    var scale: Double

    public func makeBody(configuration: Self.Configuration) -> some View {
        return configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
//            .scaleEffect(configuration.isPressed ? 1.3 : 1)
            .animation(.easeOut(duration: duration), value: configuration.isPressed)
    }
}

struct TabButton: View {
    var image: String
    var zoomed: Bool
    @Binding var currentTab: String

    var body: some View {
        Button {
            DispatchQueue.main.async {
                currentTab = image
            }
        } label: {
            Image(image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 28, maxHeight: 28)
                .animation(.easeInOut(duration: 0.3), value: currentTab)
                .frame(maxWidth: .infinity)
                .foregroundColor(currentTab == image ? Color.DarkIcon : Color.GreyIcon)
        }
        .buttonStyle(BouncyButton(duration: 0.3, scale: 0.6))
        .accessibilityLabel(Text(LocalizedStringKey(image)))
        .accessibilityAddTraits(
            currentTab == image
                ? [.isButton, .isSelected]
                : .isButton
        )
    }
}
