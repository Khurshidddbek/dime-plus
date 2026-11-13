//
//  SettingsExportCard.swift
//  dime
//
//  Bottom card behind Settings > Export Data: a CSV for spreadsheets or a JSON backup
//  with everything. The file is written first and shared only when that worked.
//

import SwiftUI

struct ExportDataCard: View {
    @EnvironmentObject var dataController: DataController
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var systemColorScheme

    @AppStorage("bottomEdge", store: UserDefaults.appGroup) var bottomEdge: Double = 15
    // Excel on Windows needs the byte order mark to read Cyrillic; a few other tools dislike it.
    @AppStorage("exportCSVWithBOM", store: UserDefaults.appGroup) var includeBOM: Bool = true

    @State private var offset: CGFloat = 0
    @State private var transactionCount = -1
    @State private var working = false
    @State private var shareFile: ShareFile?

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
                Text("Export Data")
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .foregroundColor(.PrimaryText)

                Group {
                    if transactionCount >= 0 {
                        Text("Transactions: \(transactionCount)")
                    } else {
                        Text("Pick a format")
                    }
                }
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(.SubtitleText)
                .padding(.bottom, 12)

                SettingsActionButton(title: "Spreadsheet (CSV)", systemImage: "tablecells", prominent: true) {
                    exportCSV()
                }
                .padding(.bottom, 4)

                Button {
                    Haptics.tap()

                    withAnimation(.easeInOut(duration: 0.15)) {
                        includeBOM.toggle()
                    }
                } label: {
                    HStack {
                        Text("Readable in Excel (adds a BOM)")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(Color.PrimaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Spacer()

                        SettingsSwitch(isOn: includeBOM)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(includeBOM ? Text("On") : Text("Off"))
                .padding(.bottom, 8)

                SettingsActionButton(title: "Backup file (JSON)", systemImage: "externaldrive.fill", busy: working) {
                    exportJSON()
                }

                Text("The CSV has dates, notes, amounts and categories and can be imported back. The JSON file also keeps budgets, colours and repeats and is restored in Backups.")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(.SubtitleText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Button {
                    dismiss()
                } label: {
                    DeleteButton(text: String(localized: "Close"), red: false)
                }
                .disabled(working)
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
        .toastHost()
        .onAppear {
            transactionCount = dataController.transactionCountForLog()
        }
        .sheet(item: $shareFile) { file in
            ActivityViewController(activityItems: [file.url])
        }
    }

    private func exportCSV() {
        guard !working else {
            return
        }

        do {
            let export = try DataExport.writeCSV(dataController: dataController, includeBOM: includeBOM)

            guard export.count > 0 else {
                ToastCenter.shared.info(String(localized: "There is nothing to export yet"))
                return
            }

            Haptics.success()
            shareFile = ShareFile(url: export.url)
        } catch {
            ToastCenter.shared.error(String(localized: "Couldn't write the export file"))
        }
    }

    private func exportJSON() {
        guard !working else {
            return
        }

        working = true

        DataExport.writeJSON { result in
            working = false

            switch result {
            case let .success(url):
                Haptics.success()
                shareFile = ShareFile(url: url)
            case let .failure(error):
                ToastCenter.shared.error(error.localizedDescription)
            }
        }
    }
}
