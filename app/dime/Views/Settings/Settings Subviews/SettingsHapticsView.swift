//
//  SettingsHapticsView.swift
//  dime
//
//  Created by Rafael Soh on 5/11/23.
//

import Foundation
import SwiftUI

struct SettingsHapticsView: View {
    @AppStorage("haptics", store: UserDefaults.appGroup)
    var hapticType: Int = 1

    let options = ["None", "Subtle", "Excessive"]

    @Namespace var animation

    @State var shake: Bool = false
    @State var alternateShake: Bool = false

    @State var wordShake: Bool = false

    private var explanation: LocalizedStringKey {
        switch hapticType {
        case 0:
            return "No vibration anywhere in the app."
        case 2:
            return "Everything in Subtle, plus a tick for every key of the number pad."
        default:
            return "A light tap for buttons, switches and pickers, and a stronger one for saves, errors and deletes."
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            SettingsSubviewHeader(title: "Haptic Feedback")
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { option in
                    Button {
                        withAnimation(.easeIn(duration: 0.15)) {
                            hapticType = option
                        }
                    } label: {
                        HStack {
                            Text(LocalizedStringKey(options[option]))
                                .font(.system(.body, design: .rounded))
                                .foregroundColor(Color.PrimaryText)

                            Spacer()

                            if hapticType == option {
                                Image(systemName: "checkmark")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundColor(.DarkIcon.opacity(0.6))
                                    .matchedGeometryEffect(id: "tick", in: animation)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                        .offset(x: wordShake && option == 1 ? -5 : 0)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(hapticType == option ? .isSelected : [])
                    .overlay(alignment: .bottom) {
                        if option < (options.count - 1) {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 15)
            .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
            .offset(x: shake ? -5 : 5)
            .offset(x: alternateShake ? 0 : -5)

            SettingsFootnote(text: explanation)
        }
        .modifier(SettingsSubviewModifier())
        .onChange(of: hapticType) { newValue in
            // Played through the central helper, so the preview is what the new level really does
            // (nothing at all for None).
            if newValue == 2 {
                Haptics.impact(.heavy)

                withAnimation(.easeInOut(duration: 0.1)) {
                    alternateShake = true
                }
                withAnimation(.easeInOut(duration: 0.1).repeatCount(5)) {
                    shake = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        shake = false
                        alternateShake = false
                    }
                }
            } else if newValue == 1 {
                Haptics.tap()

                withAnimation(.easeInOut(duration: 0.1).repeatCount(5)) {
                    wordShake = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        wordShake = false
                    }
                }
            }
        }
    }
}
