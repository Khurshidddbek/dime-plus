//
//  SettingsNumberEntryView.swift
//  dime
//
//  Created by Rafael Soh on 5/11/23.
//

import Foundation
import SwiftUI

/// The three ways the number pad takes an amount. Raw values are the stored
/// "numberEntryType" setting, the same ones AmountInput.Mode.resolve reads.
enum NumberEntryOption: Int, CaseIterable, Identifiable {
  case centsFirst = 1
  case decimal = 2
  case whole = 3

  var id: Int { rawValue }

  static func stored(_ value: Int) -> NumberEntryOption {
    NumberEntryOption(rawValue: value) ?? .decimal
  }

  var shortName: String {
    switch self {
    case .centsFirst:
      return String(localized: "Cents first")
    case .decimal:
      return String(localized: "With decimals")
    case .whole:
      return String(localized: "Whole numbers")
    }
  }

  var explanation: String {
    switch self {
    case .centsFirst:
      return String(localized: "Every digit shifts in from the right, so the last two digits are always the cents.")
    case .decimal:
      return String(localized: "Whole amounts are typed as they are. The separator key starts the cents.")
    case .whole:
      return String(localized: "No cents at all. The 000 key adds three zeros at once.")
    }
  }
}

struct SettingsNumberEntryView: View {
  // Same default as the pad itself (NumberPad.swift), so an unset key shows what the pad does.
  @AppStorage("numberEntryType", store: UserDefaults.appGroup)
  var numberEntryType: Int = 1
  @Environment(\.colorScheme) var colorScheme
  @AppStorage("currency", store: UserDefaults.appGroup) var currency:
    String = MoneyFormat.defaultCurrencyCode

  @State private var price: Double = 0
  @State private var category: Category?
  @State var isEditingDecimal = false
  @State var decimalValuesAssigned: AssignedDecimal = .none

  @Namespace var animation

  /// Currencies without small change always use the whole-number pad, whatever is stored.
  private var forcedWhole: Bool {
    MoneyFormat.isZeroDecimal(currency)
  }

  private var selected: NumberEntryOption {
    forcedWhole ? .whole : NumberEntryOption.stored(numberEntryType)
  }

  var body: some View {
    VStack(spacing: 10) {
      SettingsSubviewHeader(title: "Number Entry Method")

      if forcedWhole {
        Text("Whole numbers")
          .font(.system(.body, design: .rounded).weight(.semibold))
          .foregroundColor(Color.PrimaryText)
          .padding(6)
          .padding(.horizontal, 8)
          .background(Color.SecondaryBackground, in: Capsule())
          .padding(25)
      } else {
        HStack(spacing: 0) {
          ForEach(NumberEntryOption.allCases) { option in
            Button {
              guard selected != option else {
                return
              }

              Haptics.selection()
              price = 0
              isEditingDecimal = false
              decimalValuesAssigned = .none

              withAnimation(.easeIn(duration: 0.15)) {
                numberEntryType = option.rawValue
              }
            } label: {
              Text(option.shortName)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(selected == option ? Color.PrimaryText : Color.SubtitleText)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(minHeight: 38)
                .background {
                  if selected == option {
                    Capsule()
                      .fill(Color.SecondaryBackground)
                      .matchedGeometryEffect(id: "TAB1", in: animation)
                  }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected == option ? .isSelected : [])
          }
        }
        .padding(3)
        .background(
          Capsule().fill(Color.PrimaryBackground).shadow(
            color: colorScheme == .light ? Color.Outline : Color.clear, radius: 6)
        )
        .overlay(
          Capsule().stroke(
            colorScheme == .light ? Color.clear : Color.Outline.opacity(0.4), lineWidth: 1.3)
        )
        .padding(.vertical, 25)
      }

      VStack(spacing: 10) {
        Text(selected.explanation)
          .font(.system(.subheadline, design: .rounded).weight(.medium))
          .multilineTextAlignment(.center)
          .foregroundColor(Color.SubtitleText)
          .fixedSize(horizontal: false, vertical: true)

        if forcedWhole {
          Text("This currency has no cents, so this is the only way to type amounts.")
            .font(.system(.footnote, design: .rounded).weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundColor(Color.SubtitleText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 25)

      Spacer()

      NumberPadTextView(
        price: $price,
        isEditingDecimal: $isEditingDecimal,
        decimalValuesAssigned: $decimalValuesAssigned
      )

      Spacer()

      NumberPad(
        price: $price,
        category: $category,
        isEditingDecimal: $isEditingDecimal,
        decimalValuesAssigned: $decimalValuesAssigned
      ) {
        submit()
      }
    }
    .modifier(SettingsSubviewModifier())
  }

  func submit() {
    Haptics.tap()
    price = 0
  }
}
