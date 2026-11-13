//
//  InsightsSummaryBlock.swift
//  dime
//
//  Created by Rafael Soh on 19/11/23.
//

import Foundation
import SwiftUI

// Income / Expenses tile of the Net view, two side by side like the original Dime insights cards.
// Takes the number, not a string, so the amount is grouped and shrinks instead of being cut off.
struct InsightsSummaryBlockView: View {
    let income: Bool
    let amount: Double
    let showOverlay: Bool
    var action: () -> Void

    var color: Color {
        return income ? Color.IncomeGreen : Color.AlertRed
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: income ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundColor(color)
                        .frame(width: 28, height: 28)
                        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(income ? LocalizedStringKey("Income") : LocalizedStringKey("Expenses"))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.SubtitleText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundColor(Color.SubtitleText.opacity(0.7))
                }

                AmountText(amount, role: .caption, sign: .never)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if showOverlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.Outline, lineWidth: 1.3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InsightsPressStyle())
    }
}
