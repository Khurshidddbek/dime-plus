//
//  InsightsSummaryBlock.swift
//  dime
//
//  Created by Rafael Soh on 19/11/23.
//

import Foundation
import SwiftUI

// Full-width Income / Expenses tile of the Net view. Takes the number, not a string,
// so the amount is grouped and shrinks to the compact form instead of being cut off.
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
            HStack(spacing: 10) {
                Image(systemName: income ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.23), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(income ? "Income" : "Expenses")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .foregroundColor(Color.PrimaryText)

                Spacer(minLength: 8)

                AmountText(amount, role: .row, sign: .never)
                    .layoutPriority(1)

                Image(systemName: "chevron.right")
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .foregroundColor(Color.SubtitleText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if showOverlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.Outline, lineWidth: 1.3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(InsightsPressStyle())
    }
}
