//
//  CategoryDeleteCard.swift
//  dime
//
//  Bottom card that confirms a category delete. It says how many transactions go with
//  the category and offers to move them to another category first.
//

import CoreData
import SwiftUI

enum CategoryLimits {
    // The old limit was 24 (one per preset colour). Extra categories get a custom colour.
    static let maxExpense = 200
}

struct CategoryDeleteCard: View {
    let category: Category
    /// The user backed out.
    let onCancel: () -> Void
    /// Called right before the delete or the move, so the presenter can close first.
    let onConfirm: () -> Void

    @Environment(\.colorScheme) var systemColorScheme

    @AppStorage("bottomEdge", store: UserDefaults.appGroup) var bottomEdge: Double = 15

    @State private var offset: CGFloat = 0
    @State private var choosingTarget = false

    // Copied at init: the managed object is gone while the card is still animating away.
    private let name: String
    private let count: Int
    private let targets: [Category]

    init(category: Category, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.category = category
        self.onCancel = onCancel
        self.onConfirm = onConfirm

        if category.isDeleted || category.managedObjectContext == nil {
            name = ""
            count = 0
            targets = []
        } else {
            name = category.wrappedName
            count = category.transactionCount
            targets = DataController.shared.getAllCategories(income: category.income).filter { $0 != category }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    onCancel()
                }

            VStack(alignment: .leading, spacing: 1.5) {
                if choosingTarget {
                    targetPicker
                } else {
                    confirmation
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 13).fill(Color.PrimaryBackground).shadow(color: systemColorScheme == .dark ? Color.clear : Color.gray.opacity(0.25), radius: 6))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(systemColorScheme == .dark ? Color.gray.opacity(0.1) : Color.clear, lineWidth: 1.3))
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
                        if value.translation.height > 20 {
                            onCancel()
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

    @ViewBuilder
    private var confirmation: some View {
        Text("Delete '\(name)'?")
            .font(.system(.title2, design: .rounded).weight(.medium))
            .foregroundColor(.PrimaryText)

        Group {
            if count > 0 {
                Text("Transactions in this category: \(count). They are deleted with it and stay in Recently deleted for 30 days.")
            } else {
                Text("This category has no transactions.")
            }
        }
        .font(.system(.body, design: .rounded).weight(.medium))
        .foregroundColor(.SubtitleText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 15)

        if count > 0 && !targets.isEmpty {
            Button {
                Haptics.tap()

                withAnimation(.easeOut(duration: 0.2)) {
                    choosingTarget = true
                }
            } label: {
                Text("Move transactions to...")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.LightIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
                    .frame(height: 45)
                    .frame(maxWidth: .infinity)
                    .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.bottom, 8)
        }

        Button {
            deleteWithTransactions()
        } label: {
            DeleteButton(text: count > 0 ? String(localized: "Delete with transactions") : String(localized: "Delete"), red: true)
        }
        .padding(.bottom, 8)

        Button {
            onCancel()
        } label: {
            DeleteButton(text: String(localized: "Cancel"), red: false)
        }
    }

    @ViewBuilder
    private var targetPicker: some View {
        Text("Move transactions to...")
            .font(.system(.title2, design: .rounded).weight(.medium))
            .foregroundColor(.PrimaryText)

        Text("'\(name)' is deleted after the move. Transactions: \(count).")
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundColor(.SubtitleText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)

        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(targets, id: \.objectID) { target in
                    Button {
                        move(to: target)
                    } label: {
                        HStack(spacing: 10) {
                            Text(target.wrappedEmoji)
                                .font(.system(.subheadline, design: .rounded))

                            Text(target.wrappedName)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundColor(Color.PrimaryText)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if !target.income {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color(hex: target.wrappedColour))
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 45)
                        .frame(maxWidth: .infinity)
                        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 260)
        .padding(.bottom, 8)

        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                choosingTarget = false
            }
        } label: {
            DeleteButton(text: String(localized: "Back"), red: false)
        }
    }

    private func deleteWithTransactions() {
        let category = self.category

        onConfirm()

        // The presenter still shows the category for a moment; delete once it is closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !category.isDeleted, category.managedObjectContext != nil else {
                return
            }

            do {
                let groupID = try withAnimation {
                    try TrashStore.shared.deleteCategory(category)
                }

                ToastCenter.shared.undo(String(localized: "Category deleted")) {
                    _ = try? TrashStore.shared.restoreGroup(groupID)
                }
            } catch {
                // The "Couldn't save" toast is automatic; the copy stays in Recently deleted.
            }
        }
    }

    private func move(to target: Category) {
        let category = self.category

        onConfirm()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !category.isDeleted, category.managedObjectContext != nil,
                  !target.isDeleted, target.managedObjectContext != nil
            else {
                return
            }

            let rows = (category.transactions as? Set<Transaction>) ?? []
            let templates = (category.templates as? Set<TemplateTransaction>) ?? []
            let moved = rows.count
            let targetName = target.wrappedName

            rows.forEach { row in
                row.category = target
                row.income = target.income
            }

            templates.forEach { template in
                template.category = target
            }

            DiagnosticsLog.shared.log("category", "moved \(moved) transaction(s) to another category before a delete")

            do {
                // Nothing is left in the category, so only the category (and its budget) lands in the trash.
                _ = try withAnimation {
                    try TrashStore.shared.deleteCategory(category)
                }

                ToastCenter.shared.success(String(localized: "Moved to \(targetName): \(moved)"))
            } catch {
                // Automatic toast. The move and the delete are still pending and go out with the next save.
            }
        }
    }
}
