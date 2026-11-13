//
//  TransactionCategoryPicker.swift
//  dime
//
//  Created by Rafael Soh on 20/11/23.
//

import CoreData
import Foundation
import SwiftUI

struct NewCategoryPickerView: View {
    @Binding var category: Category?
    @Binding var showPicker: Bool
    @Binding var showingCategoryView: Bool
    @FetchRequest private var categories: FetchedResults<Category>
    @Environment(\.colorScheme) var colorScheme

    // Called after the user tapped a cell, so the host knows the choice was made by hand.
    private let onPick: (() -> Void)?

    let layout = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible())
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: layout, spacing: 10) {
                ForEach(categories) { item in
                    cell(item)
                }
            }
            // Room for the floating Edit pill, so it never covers the last row.
            .padding(.bottom, 75)
        }
        .keyboardAwareHeight(showToolbar: false)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .overlay(alignment: .bottom) {
            editPill
        }
    }

    private func cell(_ item: Category) -> some View {
        HStack(spacing: 7) {
            Text(item.wrappedEmoji)
                .font(.system(.subheadline, design: .rounded))

            Text(item.wrappedName)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
        }
        .id(item.id)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .foregroundColor(Color(hex: item.wrappedColour))
        .background(
            Color(hex: item.wrappedColour).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
        )
        .contentShape(Rectangle())
        .overlay {
            if item == category {
                RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                    .strokeBorder(Color(hex: item.wrappedColour),
                                  style: StrokeStyle(lineWidth: 2))
            }
        }
        .onTapGesture {
            pick(item)
        }
        .opacity(category != nil ? (category == item ? 1 : 0.5) : 1)
        .accessibilityAddTraits(.isButton)
    }

    private var editPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil")
                .font(.system(.body, design: .rounded).weight(.semibold))
            Text("Edit")
                .font(.system(.body, design: .rounded).weight(.semibold))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .foregroundColor(Color.SubtitleText)
        .background(
            RoundedRectangle(cornerRadius: 11.5, style: .continuous).fill(Color.SecondaryBackground).shadow(
                color: colorScheme == .light ? Color.Outline : Color.clear, radius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            showPicker = false
            showingCategoryView = true
        }
        .padding(.bottom, 15)
        .accessibilityAddTraits(.isButton)
    }

    private func pick(_ item: Category) {
        Haptics.selection()

        withAnimation(.easeOut(duration: 0.12)) {
            category = item
        }

        onPick?()

        // Just long enough to see which cell was taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showPicker = false
            }
        }
    }

    init(
        category: Binding<Category?>?, showPicker: Binding<Bool>, showSheet: Binding<Bool>,
        income: Bool, onPick: (() -> Void)? = nil
    ) {
        _categories = FetchRequest<Category>(
            sortDescriptors: [
                SortDescriptor(\.order, order: .reverse)
            ], predicate: NSPredicate(format: "income = %d", income))

        _category = category ?? Binding.constant(nil)
        _showPicker = showPicker
        _showingCategoryView = showSheet
        self.onPick = onPick
    }
}

// One-tap row with the categories used most, shown while nothing is chosen.
struct CategoryChipsRow: View {
    let categories: [Category]
    let onPick: (Category) -> Void

    init(categories: [Category], onPick: @escaping (Category) -> Void) {
        self.categories = categories
        self.onPick = onPick
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.objectID) { item in
                    Button {
                        onPick(item)
                    } label: {
                        HStack(spacing: 5) {
                            Text(item.wrappedEmoji)
                                .font(.system(.footnote, design: .rounded).weight(.semibold))

                            Text(item.wrappedName)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8.5)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .foregroundColor(Color(hex: item.wrappedColour))
                        .background(
                            Color(hex: item.wrappedColour).opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                        )
                    }
                    .buttonStyle(NumPadButton())
                }
            }
        }
        .edgeToEdgeChips()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

extension View {
    // The entry screen pads its content by 17 pt. A chip row breaks out of that padding so chips
    // scroll to the physical screen edge, and the content margin keeps the first chip aligned at rest.
    func edgeToEdgeChips(inset: CGFloat = 17) -> some View {
        self
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .padding(.horizontal, -inset)
    }
}
