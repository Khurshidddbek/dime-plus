//
//  ImportDataView.swift
//  dime
//
//  Created by Rafael Soh on 21/8/23.
//

import ConfettiSwiftUI
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ColumnLabel {
    let image: String
    let label: String
}

enum ProcessingState {
    case review, loading, success, error
}

struct MatchedCategory: Hashable {
    let excelValue: String
    var income: Bool
    var category: Category?
    /// Ties the entry to its rows (see CSVImport.categoryKey).
    var key: String = ""

    mutating func toggleIncome() {
        income = !income
    }
}

extension Sequence where Iterator.Element: Hashable {
    func unique() -> [Iterator.Element] {
        var seen: Set<Iterator.Element> = []
        return filter { seen.insert($0).inserted }
    }
}

struct ImportDataView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var dataController: DataController

    @State private var exportSample = false
    @State private var importing = false

    @State private var table: ImportTable?
    @State private var plan = ImportPlan()
    @State private var importedCount = 0
    @State private var rows = [[String]]()
    @State private var numberOfRows: Int = 0
    @State private var displayedColumns = [[String]]()
    @State private var columns = [[String]]()

    @State private var remainingColumns = [Int]()
    @State private var selectedColumns = [Int]()

    var indexColumnWidth: CGFloat {
        let additionalPadding: Double

        if dynamicTypeSize > .xLarge {
            additionalPadding = 10
        } else {
            additionalPadding = 0
        }

        if numberOfRows < 10 {
            return "9".widthOfRoundedString(size: 15, weight: .bold) + 16.0 + additionalPadding
        } else if numberOfRows < 100 {
            return "99".widthOfRoundedString(size: 15, weight: .bold) + 16.0 + additionalPadding
        } else {
            return "999".widthOfRoundedString(size: 15, weight: .bold) + 16.0 + additionalPadding
        }
    }

    @State var progress = 1

    @State var selectedColumn = 0
    @State var columnSelectionCompleted = false
    @State var sampleDateString = ""
    @State var dateFormatString = ""
    @State var validDateFormatString = false
    @State var uniqueCategories: [MatchedCategory] = .init()

    @State var processingState = ProcessingState.review
    @State var errorMessage = ""
    @State var confettiNumber = 0

    var numberOfLinkedCategories: Int {
        uniqueCategories.filter { $0.category != nil }.count
    }

    @State var showingCategoryView = false
    @State var pageIndex = 0

    // just for the adding of transactions
    @State var income = false

    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    var columnWidth: CGFloat {
        if dynamicTypeSize > .xLarge {
            return 150
        } else {
            return 100
        }
    }

    let instructions: [InstructionHeadings] = [
        InstructionHeadings(title: "Import transactions", subtitle: "Begin by adding a CSV file with 4 columns: amount, note, date, and category."),
        InstructionHeadings(title: "Assign category column", subtitle: "Select a column from your import that corresponds to the categories of your transactions."),
        InstructionHeadings(title: "Assign note column", subtitle: "Select a column from your import that corresponds to the notes/subtitles of your transactions."),
        InstructionHeadings(title: "Assign date column", subtitle: "Select a column from your import that corresponds to the dates of your transactions."),
        InstructionHeadings(title: "Assign amount column", subtitle: "Select a column from your import that corresponds to the values of your transactions."),
        InstructionHeadings(title: "Indicate date format", subtitle: "Referencing this article, state the format of the dates in the assigned column."),
        InstructionHeadings(title: "Link categories", subtitle: "Match values found in the 'Category' column to the corresponding categories in Dime."),
        InstructionHeadings(title: "Processing import", subtitle: "Please wait while we process your new transactions.")
    ]

    let labels: [ColumnLabel] = [
        ColumnLabel(image: "square.grid.2x2.fill", label: "Category"),
        ColumnLabel(image: "doc.plaintext.fill", label: "Note"),
        ColumnLabel(image: "calendar", label: "Date"),
        ColumnLabel(image: "dollarsign.circle.fill", label: "Amount")
    ]

    var pointers: [String] {
        [
            String(localized: "A CSV exported from Dime can be imported as it is. Columns are matched by their names."),
            String(localized: "Amounts may have spaces, thousands separators and a currency, for example 35 880 000 or 1,250.50."),
            String(localized: "All dates should be of a consistent, recognizable format. If no timestamps are provided, the time of transaction will default to 12:00 am."),
            String(localized: "Nothing is saved until you confirm. Rows that cannot be read are listed before the import.")
        ]
    }

    var showsBackChevron: Bool {
        progress > 1 && !(progress == 8 && processingState == .success)
    }

    var incomeCategories: [Category] {
        dataController.getAllCategories(income: true)
    }

    var expenseCategories: [Category] {
        dataController.getAllCategories(income: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    goBack()
                } label: {
                    Image(systemName: showsBackChevron ? "chevron.left" : "xmark")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.SubtitleText)
                        .padding(8)
                        .background(Color.SecondaryBackground, in: Circle())
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .contentTransition(.symbolEffect(.replace.downUp.wholeSymbol))
                .disabled(progress == 8 && processingState == .loading)
                .accessibilityLabel(showsBackChevron ? Text("Back") : Text("Close"))

                Spacer()

                CustomCapsuleProgress(percent: Double(min(progress, 7)) / 7, width: 4, topStroke: Color.DarkBackground, bottomStroke: Color.SecondaryBackground)
                    .frame(width: 60)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, progress == 8 ? 10 : 50)

            if progress == 8 {
                resultView
            } else {

                VStack(alignment: .leading, spacing: 5) {
                    if progress == 6 {
                        HStack {
                            Text("Indicate date format")
                                .foregroundColor(.PrimaryText)
                                .font(.system(.title2, design: .rounded).weight(.semibold))

//                                .font(.system(size: 26, weight: .semibold, design: .rounded))

                            Spacer()
                        }
                        .frame(maxWidth: .infinity)

                        Text("Referencing \(makeAttributedString()), state the format of the dates in the assigned column.")
                            .foregroundColor(.SubtitleText)
                            .font(.system(.body, design: .rounded).weight(.medium))

//                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack {
                            Text(LocalizedStringKey(instructions[progress - 1].title))
                                .foregroundColor(Color.PrimaryText)
                                .font(.system(.title2, design: .rounded).weight(.semibold))

//                                .font(.system(size: 26, weight: .semibold, design: .rounded))

                            if progress == 7 {
                                Button {
                                    showingCategoryView = true
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                                        .foregroundColor(Color.SubtitleText)
                                        .padding(4)
                                        .background(Color.SecondaryBackground, in: Circle())
                                        .contentShape(Circle())
                                }
                            }

                            Spacer()
                        }
                        .frame(maxWidth: .infinity)

                        Text(LocalizedStringKey(instructions[progress - 1].subtitle))
                            .foregroundColor(.SubtitleText)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: UIScreen.main.bounds.size.height / (dynamicTypeSize > .xLarge ? 5.3 : 5.8), alignment: .top)
                .padding(.bottom, 10)

                if progress == 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))

//                            .font(.system(size: 15, weight: .semibold, design: .rounded))

                        Text("Additional Pointers")
                            .font(.system(.body, design: .rounded).weight(.semibold))

//                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .foregroundColor(Color.IncomeGreen)
                    .background(Color.IncomeGreen.opacity(0.23), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .padding(.bottom, 20)

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(pointers.indices, id: \.self) { index in
                                PointerView(number: index + 1, text: pointers[index])
                            }
                        }
                    }
                } else if progress < 6 {
                    VStack(spacing: 10) {
                        Text("Sampled Rows from Import CSV")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))

//                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.SubtitleText)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                VStack(spacing: 0) {
                                    ForEach(0 ..< (numberOfRows + 1), id: \.self) { number in
                                        if number == 0 {
                                            Rectangle()
                                                .fill(Color.PrimaryBackground)
                                                .frame(width: indexColumnWidth, height: 30, alignment: .leading)
                                        } else {
                                            Text("\(number)")
                                                .foregroundStyle(Color.SubtitleText)
                                                .font(.system(.subheadline, design: .rounded).weight(.bold))

//                                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                                .padding(.horizontal, 8)
                                                .frame(width: indexColumnWidth, height: 30, alignment: .leading)
                                                .overlay(Rectangle().stroke(Color.Outline, lineWidth: 1))
                                        }
                                    }
                                }
                                .background(Color.SecondaryBackground.opacity(0.6))

                                HStack(spacing: 0) {
                                    ForEach(displayedColumns.indices, id: \.self) { columnIndex in

                                        VStack(spacing: 0) {
                                            if selectedColumns.contains(columnIndex) {
                                                if let index = selectedColumns.firstIndex(of: columnIndex) {
                                                    HStack(spacing: 4.5) {
                                                        Image(systemName: labels[index].image)
                                                            .font(.system(.caption, design: .rounded).weight(.semibold))

//                                                            .font(.system(size: 12, weight: .semibold, design: .rounded))

                                                        Text(LocalizedStringKey(labels[index].label))
                                                            .font(.system(.subheadline, design: .rounded).weight(.semibold))

//                                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                    }
                                                    .padding(.horizontal, 10)
                                                    .frame(width: columnWidth, height: 30, alignment: .leading)
                                                    .foregroundColor(Color(labels[index].label))
                                                    .background(Color(labels[index].label).opacity(0.23), in: RoundedCorner(radius: 10, corners: [.topLeft, .topRight]))
                                                }
                                            } else {
                                                Rectangle()
                                                    .fill(Color.PrimaryBackground)
                                                    .frame(width: columnWidth, height: 30, alignment: .leading)
                                            }

                                            VStack(spacing: 0) {
                                                ForEach(Array(displayedColumns[columnIndex].enumerated()), id: \.offset) { _, value in
                                                    Text(value)
                                                        .lineLimit(1)
                                                        .foregroundStyle(Color.PrimaryText)
                                                        .font(.system(.subheadline, design: .rounded).weight(.medium))

//                                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                                        .padding(.horizontal, 8)
                                                        .frame(width: columnWidth, height: 30, alignment: .leading)
                                                        .overlay(Rectangle().stroke(Color.Outline, lineWidth: 1))
                                                    //
                                                }
                                            }
                                            .onTapGesture {
                                                if progress >= 2 {
                                                    if remainingColumns.contains(columnIndex) {
                                                        withAnimation {
                                                            selectedColumn = columnIndex
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .overlay(alignment: .leading) {
                                    if !columnSelectionCompleted && progress < 6 {
                                        VStack(spacing: 0) {
                                            HStack(spacing: 4.5) {
                                                Image(systemName: labels[progress - 2].image)
                                                    .font(.system(.caption, design: .rounded).weight(.semibold))

//                                                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                                                Text(LocalizedStringKey(labels[progress - 2].label))
                                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))

//                                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .padding(.horizontal, 10)
                                            .frame(width: columnWidth + 2, height: 30, alignment: .leading)
                                            .foregroundColor(Color.LightIcon)
                                            .background(Color.DarkBackground, in: RoundedCorner(radius: 10, corners: [.topLeft, .topRight]))

                                            Rectangle()
                                                .stroke(Color.DarkBackground, lineWidth: 2)
                                                .frame(width: columnWidth)
                                                .frame(maxHeight: .infinity)
                                        }
                                        .offset(x: CGFloat(CGFloat(selectedColumn) * columnWidth))
                                    }
                                }
                            }
                            .padding(2)
                        }
                    }
                } else if progress == 6 {
                    VStack(spacing: 10) {
                        Text("Sample from 'Date' Column")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))

//                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.SubtitleText)

                        Text(sampleDateString)
                            .font(.system(.title3, design: .rounded).weight(.semibold))

//                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.PrimaryText)
                            .frame(width: 300, height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Color.Outline, lineWidth: 2)
                            )
                            .padding(.bottom, 30)

                        HStack(spacing: 7) {
                            Image(systemName: "calendar")
                                .font(.system(.callout, design: .rounded).weight(.semibold))

//                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color.SubtitleText)

                            TextField("Date Format", text: $dateFormatString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .foregroundColor(Color.PrimaryText)
                                .font(.system(.title3, design: .rounded).weight(.semibold))

//                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity)

                            if validDateFormatString {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))

//                                        .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color.IncomeGreen)
                            } else if !validDateFormatString && dateFormatString != "" {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .foregroundColor(Color.AlertRed)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 300, height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.SubtitleText, lineWidth: 2)
                                .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .onChange(of: dateFormatString) { newValue in
                            validDateFormatString = !newValue.isEmpty && ImportDateParser(format: newValue).date(from: sampleDateString) != nil
                        }
                    }
                } else if progress == 7 {
                    VStack(spacing: 10) {
                        Text("\(numberOfLinkedCategories)/^[\(uniqueCategories.count) category](inflect: true) linked")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))

//                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.SubtitleText)

                        TabView(selection: $pageIndex) {
                            ForEach(uniqueCategories.indices, id: \.self) { categoryIndex in
                                VStack(spacing: 20) {
                                    HStack(spacing: 8) {
                                        Text(uniqueCategories[categoryIndex].excelValue.isEmpty ? String(localized: "No category") : uniqueCategories[categoryIndex].excelValue)
                                            .font(.system(.title3, design: .rounded).weight(.semibold))

                                            .lineLimit(1)
//                                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                                            .foregroundColor(Color.PrimaryText)
//                                            .frame(height: 36)
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(Color.Outline, lineWidth: 2)
                                            )
                                            .minimumScaleFactor(0.7)

                                        if let unwrappedCategory = uniqueCategories[categoryIndex].category {
                                            HStack(spacing: 8) {
                                                Image(systemName: "triangle.fill")
                                                    .rotationEffect(Angle(degrees: 90))
                                                    .font(.system(size: 12, weight: .regular, design: .rounded))
                                                    .foregroundColor(Color.SubtitleText)

                                                HStack(spacing: 5) {
                                                    Text(unwrappedCategory.wrappedEmoji)
//                                                        .font(.system(size: 15))
                                                        .font(.system(.subheadline, design: .rounded))

                                                    Text(unwrappedCategory.wrappedName)
                                                        .font(.system(.title3, design: .rounded).weight(.semibold))

                                                        .lineLimit(1)

//                                                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                                                }
                                                .padding(.vertical, 6)
                                                .padding(.horizontal, 10)
//                                                .frame(height: 36)
                                                .foregroundColor(Color(hex: unwrappedCategory.wrappedColour))
                                                .background(Color(hex: unwrappedCategory.wrappedColour).opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                                .minimumScaleFactor(0.7)
                                            }
                                            .transition(.opacity)
                                        }
                                    }
                                    .drawingGroup()

                                    MatchCategoryStepperView(category: $uniqueCategories[categoryIndex].category, categories: uniqueCategories[categoryIndex].income ? incomeCategories : expenseCategories, pageIndex: $pageIndex, maxIndex: uniqueCategories.count)
                                        .overlay(alignment: .bottomTrailing) {
                                            let income = uniqueCategories[categoryIndex].income

                                            ZStack {
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .fill(Color.PrimaryBackground)

                                                Image(systemName: income ? "plus" : "minus")
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .foregroundColor(income ? Color.IncomeGreen : Color.AlertRed)
                                                    .frame(width: 30, height: 30)
                                                    .background(income ? Color.IncomeGreen.opacity(0.23) : Color.AlertRed.opacity(0.23), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            }
                                            .frame(width: 30, height: 30)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                uniqueCategories[categoryIndex].income.toggle()

                                                // The list below now shows the other type; a link of the old type would be imported silently.
                                                if let linked = uniqueCategories[categoryIndex].category, linked.income != uniqueCategories[categoryIndex].income {
                                                    uniqueCategories[categoryIndex].category = nil
                                                }
                                            }
                                            .padding(12)
                                        }

                                    Spacer()
                                }
                                .padding(10)
                                .tag(categoryIndex)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .frame(height: 390)
                    }
                }

                Spacer()

                if progress == 1 {
                    VStack(spacing: 13) {
                        Button {
                            Haptics.tap()

                            importing = true

                        } label: {
                            HStack(spacing: 6) {
                                Text("Import")
                                    .font(.system(.title3, design: .rounded).weight(.semibold))

//                                    .font(.system(size: 19, weight: .semibold, design: .rounded))

                                Image(systemName: "square.and.arrow.up.fill")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))

//                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                            }
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(Color.LightIcon)
                            .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(BouncyButton(duration: 0.2, scale: 0.8))

                        Button {
                            exportSample = true
                        } label: {
                            HStack(spacing: 6) {
//                                Image(systemName: "doc.text")
//                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                Text("Sample Sheet")
                                    .underline()
                                    .font(.system(.body, design: .rounded).weight(.semibold))

//                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(Color.SubtitleText)
                        }
                    }

                } else {
                    Button {
                        if progress == 7 {
                            if numberOfLinkedCategories == uniqueCategories.count {
                                // Everything is checked first; nothing is written before the review screen.
                                guard buildPlan() else {
                                    ToastCenter.shared.error(String(localized: "Invalid File"))
                                    return
                                }

                                Haptics.tap()
                                processingState = .review

                                withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.8)) {
                                    progress += 1
                                }
                            } else {
                                ToastCenter.shared.error(String(localized: "Unlinked Categories"))

                                if let firstUnlinked = uniqueCategories.firstIndex(where: { $0.category == nil }) {
                                    withAnimation {
                                        pageIndex = firstUnlinked
                                    }
                                }
                            }

                        } else if progress > 5 {
                            guard validDateFormatString else {
                                ToastCenter.shared.error(String(localized: "Date format doesn't match"))
                                return
                            }

                            Haptics.tap()

                            withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.8)) {
                                progress += 1
                            }
                        } else {
                            withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.8)) {
                                guard !remainingColumns.isEmpty else { return }

                                // A second tap while the last step is animating would pick a fifth column.
                                guard !columnSelectionCompleted else { return }

                                guard selectedColumn < columns.count else { return }

                                if progress == 4 {
                                    guard columns[selectedColumn].contains(where: { $0.containsDigits }) else {
                                        ToastCenter.shared.error(String(localized: "Invalid Column"))
                                        return
                                    }
                                }

                                if progress == 5 {
                                    guard validateAmounts(strings: columns[selectedColumn]) else {
                                        ToastCenter.shared.error(String(localized: "Invalid Column"))
                                        return
                                    }
                                }

                                // remove from possible pool
                                let index = remainingColumns.firstIndex(of: selectedColumn) ?? 0
                                remainingColumns.remove(at: index)

                                // add to holding pool
                                selectedColumns.append(selectedColumn)

                                if progress < 5 {
                                    guard !remainingColumns.isEmpty else {
                                        ToastCenter.shared.error(String(localized: "Insufficient Columns"))
                                        return
                                    }
                                    selectedColumn = remainingColumns[0]
                                }

                                // reset selected column

                                if progress == 5 {
                                    prepareDateAndCategories()

                                    columnSelectionCompleted = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        withAnimation {
                                            progress += 1
                                        }
                                    }
                                } else {
                                    progress += 1
                                }
                            }
                        }
                    } label: {
                        Text("Continue")
                            .font(.system(.title3, design: .rounded).weight(.semibold))

//                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(Color.LightIcon)
                            .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(BouncyButton(duration: 0.2, scale: 0.8))
                }
            }
        }
        .padding(20)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.keyboard)
        .background(Color.PrimaryBackground)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]
        ) { result in
            switch result {
            case let .success(file):
                loadFile(file)
            case let .failure(error):
                DiagnosticsLog.shared.log("import", "file picker failed: \(error.localizedDescription)")
                ToastCenter.shared.error(String(localized: "Couldn't open the file"))
            }
        }
        .sheet(isPresented: $exportSample) {
            if let url = Bundle.main.url(forResource: "sample", withExtension: "csv") {
                ActivityViewController(activityItems: [url])
            }
        }
        .sheet(isPresented: $showingCategoryView) {
            if #available(iOS 16.0, *) {
                NewCategoryAlert(income: $income, bottomSpacers: false, budgetMode: false)
                    .presentationDetents([.height(270)])
            } else {
                NewCategoryAlert(income: $income, bottomSpacers: true, budgetMode: false)
            }
        }
        .toastHost()
        .confettiCannon(counter: $confettiNumber, num: 50, openingAngle: Angle(degrees: 0), closingAngle: Angle(degrees: 360), radius: 200)
    }

    /// The amount column passes when most of its filled cells read as a number.
    func validateAmounts(strings: [String]) -> Bool {
        let filled = strings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !filled.isEmpty else {
            return false
        }

        let readable = filled.filter { $0.containsDigits && ImportAmount.parse($0) != nil }.count

        return readable * 2 >= filled.count
    }

    func goBack() {
        let spring = Animation.interactiveSpring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.8)

        if progress == 8 {
            if processingState == .loading {
                return
            }

            if processingState == .success {
                dismiss()
                return
            }

            withAnimation(spring) {
                progress = 7
            }
        } else if progress == 2 || progress > 6 {
            withAnimation(spring) {
                progress -= 1
            }
        } else if progress > 2 {
            withAnimation(spring) {
                if let removedColumn = selectedColumns.popLast() {
                    remainingColumns.append(removedColumn)
                    remainingColumns.sort()
                    selectedColumn = remainingColumns[0]
                    columnSelectionCompleted = false

                    progress -= 1
                }
            }
        } else {
            dismiss()
        }
    }

    func loadFile(_ file: URL) {
        let scoped = file.startAccessingSecurityScopedResource()

        defer {
            if scoped {
                file.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: file) else {
            DiagnosticsLog.shared.log("import", "file could not be read")
            ToastCenter.shared.error(String(localized: "Couldn't open the file"))
            return
        }

        guard let loaded = CSVImport.readTable(from: data) else {
            ToastCenter.shared.error(String(localized: "Invalid File"))
            return
        }

        guard loaded.columnCount >= 4 else {
            ToastCenter.shared.error(String(localized: "Insufficient Columns"))
            return
        }

        table = loaded
        rows = loaded.rows
        columns = (0 ..< loaded.columnCount).map { loaded.column($0) }
        displayedColumns = columns.map { Array($0.prefix(8)) }
        numberOfRows = displayedColumns.first?.count ?? 0
        remainingColumns = Array(0 ..< loaded.columnCount)
        selectedColumns = []
        selectedColumn = 0
        columnSelectionCompleted = false
        uniqueCategories = []
        pageIndex = 0
        plan = ImportPlan()
        dateFormatString = ""
        validDateFormatString = false

        DiagnosticsLog.shared.log("import", "csv opened: \(loaded.rows.count) rows, \(loaded.columnCount) columns, legacy=\(loaded.isLegacyDimeExport)")

        if let auto = CSVImport.mapping(forHeader: loaded.header) {
            // Dime's own export (old and new) and files with the same column names skip the manual steps.
            selectedColumns = [auto.category, auto.note, auto.date, auto.amount]
            remainingColumns.removeAll { selectedColumns.contains($0) }
            columnSelectionCompleted = true
            prepareDateAndCategories()

            withAnimation {
                progress = validDateFormatString ? 7 : 6
            }

            ToastCenter.shared.info(String(localized: "Columns matched by their names"))
        } else {
            withAnimation {
                progress = 2
            }
        }
    }

    /// Columns picked by the user (or by header name), plus the optional type and id columns.
    func currentMapping() -> ImportMapping? {
        guard selectedColumns.count == 4 else {
            return nil
        }

        var mapping = ImportMapping(category: selectedColumns[0], note: selectedColumns[1], date: selectedColumns[2], amount: selectedColumns[3], type: nil, id: nil)
        let extras = CSVImport.optionalColumns(forHeader: table?.header)

        if let type = extras.type, !selectedColumns.contains(type) {
            mapping.type = type
        }

        if let id = extras.id, !selectedColumns.contains(id) {
            mapping.id = id
        }

        return mapping
    }

    /// Existing category with the same name, of the wanted type when the file says which.
    func autoLink(value: String, hint: Bool?) -> (category: Category?, income: Bool) {
        let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !wanted.isEmpty else {
            return (nil, hint ?? false)
        }

        let expense = expenseCategories.first { $0.wrappedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }
        let income = incomeCategories.first { $0.wrappedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }

        if let hint = hint {
            return (hint ? income : expense, hint)
        }

        if let expense = expense {
            return (expense, false)
        }

        if let income = income {
            return (income, true)
        }

        return (nil, false)
    }

    /// Guesses the date format from the whole column and builds the list for the linking step.
    func prepareDateAndCategories() {
        guard let table = table, let mapping = currentMapping() else {
            return
        }

        let dateValues = table.column(mapping.date)
        sampleDateString = dateValues.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""

        if let deducedFormat = ImportDateParser.deduceFormat(from: dateValues) {
            dateFormatString = deducedFormat
            validDateFormatString = true
        } else {
            dateFormatString = ""
            validDateFormatString = false
        }

        var seen = Set<String>()
        var list = [MatchedCategory]()

        for row in table.rows {
            let key = CSVImport.categoryKey(for: row, mapping: mapping)

            guard seen.insert(key).inserted else {
                continue
            }

            let value = mapping.category < row.count ? row[mapping.category].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let linked = autoLink(value: value, hint: CSVImport.typeHint(for: row, mapping: mapping))

            list.append(MatchedCategory(excelValue: value, income: linked.income, category: linked.category, key: key))
        }

        uniqueCategories = list
        pageIndex = list.firstIndex { $0.category == nil } ?? 0
    }

    /// Validates every row. false when the file or the mapping is gone.
    func buildPlan() -> Bool {
        guard let table = table, let mapping = currentMapping(), !dateFormatString.isEmpty else {
            return false
        }

        var links = [String: ImportCategoryLink]()
        var assignedIDs = false

        for matched in uniqueCategories {
            guard let category = matched.category, !category.isDeleted, category.managedObjectContext != nil else {
                continue
            }

            if category.id == nil {
                // Drafts point at categories by id.
                category.id = UUID()
                assignedIDs = true
            }

            if let id = category.id {
                links[matched.key] = ImportCategoryLink(id: id, name: category.wrappedName, income: category.income)
            }
        }

        if assignedIDs, dataController.save("category ids for import").isFailure {
            return false
        }

        let parser = ImportDateParser(format: dateFormatString)
        let dates = table.column(mapping.date).compactMap { parser.date(from: $0) }
        var existing: (signatures: [String: Int], ids: Set<UUID>) = ([:], [])

        if mapping.id != nil {
            // With an ID column the whole store is checked: a row whose date was edited in
            // the app after the export must not come back as a twin with the same id.
            existing = CSVImport.existingRows(in: dataController, from: Date.distantPast, to: Date.distantFuture)
        } else if let first = dates.min(), let last = dates.max() {
            existing = CSVImport.existingRows(in: dataController, from: first, to: last)
        }

        plan = CSVImport.plan(table: table, mapping: mapping, dateParser: parser, links: links, existing: existing.signatures, existingIDs: existing.ids)

        return true
    }

    /// One background write for the whole file. The result screen shows what really happened.
    func runImport() {
        let drafts = plan.drafts
        let skipped = plan.skippedCount

        guard !drafts.isEmpty, processingState != .loading else {
            return
        }

        Haptics.tap()

        withAnimation {
            processingState = .loading
        }

        let controller = dataController

        DispatchQueue.global(qos: .userInitiated).async {
            // A way back when the file turns out to be the wrong one.
            _ = try? BackupStore.shared.backupNow(tag: "pre-import")

            let result = Result { try controller.newTransactions(drafts, reason: "csv import") }

            DispatchQueue.main.async {
                switch result {
                case let .success(ids):
                    importedCount = ids.count
                    DiagnosticsLog.shared.log("import", "csv imported \(ids.count), skipped \(skipped)")
                    Haptics.success()

                    withAnimation {
                        processingState = .success
                        confettiNumber += 1
                    }
                case let .failure(error):
                    errorMessage = error.localizedDescription
                    DiagnosticsLog.shared.log("import", "csv FAILED \(DataController.describe(error as NSError))")
                    Haptics.error()

                    withAnimation {
                        processingState = .error
                    }
                }
            }
        }
    }

    // MARK: review and result (step 8)

    @ViewBuilder
    var resultView: some View {
        VStack(spacing: 14) {
            switch processingState {
            case .review:
                resultHeader(icon: "tray.and.arrow.down.fill", tint: Color.PrimaryText, title: "Check before importing")
                summaryCard
                issuesList
                Spacer(minLength: 0)
                primaryButton(
                    plan.readyCount > 0 ? String(localized: "Import \(plan.readyCount)") : String(localized: "Nothing to import"),
                    enabled: plan.readyCount > 0
                ) {
                    runImport()
                }
            case .loading:
                Spacer()

                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(0.8)

                Text("Processing Import")
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)

                Spacer()
                Spacer()
            case .success:
                resultHeader(icon: "checkmark", tint: Color.IncomeGreen, title: "Import Successful")
                summaryCard
                issuesList
                Spacer(minLength: 0)
                primaryButton(String(localized: "Done"), enabled: true) {
                    dismiss()
                }
            case .error:
                resultHeader(icon: "xmark", tint: Color.AlertRed, title: "Import Failed")

                Text(errorMessage)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .multilineTextAlignment(.center)

                Text("Nothing was imported.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)

                Spacer(minLength: 0)
                primaryButton(String(localized: "Back"), enabled: true) {
                    goBack()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func resultHeader(icon: String, tint: Color, title: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundColor(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.2), in: Circle())

            Text(title)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundColor(Color.PrimaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    var summaryCard: some View {
        VStack(spacing: 0) {
            if processingState == .success {
                summaryRow("Imported", value: importedCount, color: Color.IncomeGreen)
            } else {
                summaryRow("To import", value: plan.readyCount, color: Color.PrimaryText)
            }

            Divider()
                .overlay(Color.Outline)

            summaryRow("Skipped", value: plan.skippedCount - plan.duplicateCount, color: plan.skippedCount - plan.duplicateCount > 0 ? Color.AlertRed : Color.SubtitleText)

            if plan.duplicateCount > 0 {
                Divider()
                    .overlay(Color.Outline)

                summaryRow("Already in the app", value: plan.duplicateCount, color: Color.SubtitleText)
            }
        }
        .padding(.horizontal, 15)
        .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    func summaryRow(_ title: LocalizedStringKey, value: Int, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundColor(Color.PrimaryText)

            Spacer()

            Text(MoneyFormat.number(Double(value)))
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundColor(color)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    var issuesList: some View {
        let issues = plan.issues.filter { $0.reason != .duplicate }

        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("SKIPPED ROWS")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundColor(Color.SubtitleText)
                    .padding(.horizontal, 10)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(issues.prefix(200)) { issue in
                            HStack {
                                Text("Line \(issue.line)")
                                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                                    .foregroundColor(Color.PrimaryText)

                                Spacer()

                                Text(issue.reason.text)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundColor(Color.SubtitleText)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 9)
                        }

                        if issues.count > 200 {
                            Text("and \(issues.count - 200) more")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(Color.SubtitleText)
                                .padding(.vertical, 9)
                        }
                    }
                    .padding(.horizontal, 15)
                }
                .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .frame(height: 50)
                .frame(maxWidth: .infinity)
                .foregroundColor(Color.LightIcon)
                .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(BouncyButton(duration: 0.2, scale: 0.8))
        .disabled(!enabled)
    }

    func makeAttributedString() -> AttributedString {
        var string = AttributedString("this article")
        string.foregroundColor = Color.PrimaryText
        string.link = URL(string: "https://pro.arcgis.com/en/pro-app/latest/help/mapping/time/convert-string-or-numeric-time-values-into-data-format.htm")
        string.underlineColor = UIColor(Color.PrimaryText)
        string.underlineStyle = .single

        return string
    }

    @ViewBuilder
    func PointerView(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            ZStack {
                Circle()
                    .fill(Color.SecondaryBackground)

                Text("\(number)")
                    .font(.system(.body, design: .rounded).weight(.bold))

//                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Color.SubtitleText)
            }
            .frame(width: 25, height: 25)

            Text(text)
                .font(.system(.body, design: .rounded).weight(.medium))

//                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(Color.PrimaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]?

    func makeUIViewController(context _: UIViewControllerRepresentableContext<ActivityViewController>) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: UIViewControllerRepresentableContext<ActivityViewController>) {}
}

struct MatchCategoryStepperView: View {
    @Binding var category: Category?
    @Binding var pageIndex: Int
    var categories: [Category]
    var maxIndex: Int
//
//    @Environment(\.dynamicTypeSize) var dynamicTypeSize
//
//    var fontSize: CGFloat {
//        switch dynamicTypeSize {
//        case .xSmall:
//            return 14
//        case .small:
//            return 15
//        case .medium:
//            return 16
//        case .large:
//            return 17
//        case .xLarge:
//            return 19
//        case .xxLarge:
//            return 21
//        case .xxxLarge:
//            return 23
//        default:
//            return 23
//        }
//    }

    var body: some View {
        VStack {
            if categories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(.title, design: .rounded))

//                        .font(.system(size: 28, weight: .regular, design: .rounded))
                        .foregroundColor(Color.SubtitleText.opacity(0.7))
                        .padding(.top, 20)

                    Text("No remaining\ncategories.")
                        .font(.system(.callout, design: .rounded).weight(.medium))

//                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundColor(Color.SubtitleText.opacity(0.7))
                        .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(getRows(), id: \.self) { rows in

                            HStack(spacing: 8) {
                                ForEach(rows) { row in

                                    // Row View....
                                    RowView(categoryInput: row)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(15)
        .frame(height: 250)
        .background(Color.Outline.opacity(0.3), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.Outline, lineWidth: 2)
        }
//        .background(Color.PrimaryBackground, in: )
    }

    func getRows() -> [[Category]] {
        var rows: [[Category]] = []
        var currentRow: [Category] = []

        var totalWidth: CGFloat = 0

        let screenWidth: CGFloat = UIScreen.main.bounds.width - 80

        categories.forEach { category in

            let roundedFont = UIFont.rounded(ofSize: UIFont.textStyleSize(.body), weight: .semibold)

            let attributes = [NSAttributedString.Key.font: roundedFont]

            let size = (category.fullName as NSString).size(withAttributes: attributes)

            totalWidth += (size.width + 10 + 10 + 8)

            if totalWidth > screenWidth {
                totalWidth = (!currentRow.isEmpty || rows.isEmpty ? (size.width + 10 + 10 + 8) : 0)

                rows.append(currentRow)
                currentRow.removeAll()
                currentRow.append(category)

            } else {
                currentRow.append(category)
            }
        }

        // Safe check...
        // if having any value storing it in rows...
        if !currentRow.isEmpty {
            rows.append(currentRow)
            currentRow.removeAll()
        }

        return rows
    }

    @ViewBuilder
    func RowView(categoryInput: Category) -> some View {
        Button {
            withAnimation {
                category = categoryInput
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation {
                    // remember to check for cap
                    if pageIndex < maxIndex - 1 {
                        pageIndex += 1
                    }
                }
            }

        } label: {
            HStack(spacing: 5) {
                Text(categoryInput.wrappedEmoji)
                    .font(.system(.footnote, design: .rounded))

//                    .font(.system(size: 13))
                Text(categoryInput.wrappedName)
                    .font(.system(.body, design: .rounded).weight(.semibold))

//                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(category == categoryInput ? Color(hex: categoryInput.wrappedColour) : Color.PrimaryText)
            .background(category == categoryInput ? Color(hex: categoryInput.wrappedColour).opacity(0.35) : Color.PrimaryBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if category != categoryInput {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.Outline,
                                      style: StrokeStyle(lineWidth: 1.5))
                }
            }
//            .opacity(category == nil ? 1 : (category == categoryInput ? 1 : 0.4))
        }
        .buttonStyle(BouncyButton(duration: 0.2, scale: 0.8))
    }

    init(category: Binding<Category?>?, categories: [Category], pageIndex: Binding<Int>, maxIndex: Int) {
        _category = category ?? Binding.constant(nil)
        _pageIndex = pageIndex
        self.categories = categories
        self.maxIndex = maxIndex
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
