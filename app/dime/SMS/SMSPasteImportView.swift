//
//  SMSPasteImportView.swift
//  dime
//
//  Paste one or many bank messages (or pick a text file), see what the parser reads, import.
//  Presented as a sheet.
//

import SwiftUI
import UniformTypeIdentifiers

struct SMSPasteImportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var items = [SMSPreviewItem]()
    @State private var fromFile = false
    @State private var showFilePicker = false
    @FocusState private var editorFocused: Bool

    private static let shownRows = 40

    init(initialText: String = "") {
        _text = State(initialValue: initialText)
    }

    private var freshCount: Int {
        items.filter { $0.status == .fresh }.count
    }

    private var unrecognisedCount: Int {
        items.filter { $0.status == .unrecognised }.count
    }

    private var knownCount: Int {
        items.filter { $0.status == .known }.count
    }

    private var skippedCount: Int {
        items.filter { $0.status == .ignored && $0.parsed.skipReason != nil }.count
    }

    private var transferCount: Int {
        items.filter { $0.ownTransfer }.count
    }

    private var importable: Int {
        freshCount + unrecognisedCount
    }

    var body: some View {
        VStack(spacing: 0) {
            SMSScreenHeader("Paste messages", closeIcon: "xmark", onClose: { dismiss() })
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    editor

                    HStack(spacing: 8) {
                        SMSPillButton(title: String(localized: "Paste"), systemImage: "doc.on.clipboard", prominent: false) {
                            paste()
                        }

                        SMSPillButton(title: String(localized: "From file"), systemImage: "doc.text", prominent: false) {
                            Haptics.tap()
                            showFilePicker = true
                        }

                        Spacer(minLength: 0)

                        if !text.isEmpty {
                            SMSPillButton(title: String(localized: "Clear"), prominent: false, destructive: true) {
                                Haptics.tap()
                                text = ""
                                fromFile = false
                            }
                        }
                    }

                    if !items.isEmpty {
                        summary

                        ForEach(items.prefix(Self.shownRows)) { item in
                            row(item)
                        }

                        if items.count > Self.shownRows {
                            Text("And \(items.count - Self.shownRows) more")
                                .font(.system(.footnote, design: .rounded).weight(.medium))
                                .foregroundColor(Color.SubtitleText)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No bank messages found")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundColor(Color.AlertRed)
                    } else {
                        Text("In Messages, hold a bank message, tap More, tick as many as you need and tap Forward. Copy the text that appears and paste it here.")
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .foregroundColor(Color.SubtitleText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)

            importButton
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.PrimaryBackground.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .toastHost()
        .onAppear {
            refresh()
        }
        .onChange(of: text) { _ in
            refresh()
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [UTType.plainText], allowsMultipleSelection: false) { result in
            loadFile(result)
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(.footnote, design: .rounded))
            .foregroundColor(Color.PrimaryText)
            .scrollContentBackground(.hidden)
            .focused($editorFocused)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .frame(minHeight: 120, maxHeight: 180)
            .padding(8)
            .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste one or many bank messages")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(Color.SubtitleText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New: \(freshCount)")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundColor(Color.PrimaryText)

            if knownCount > 0 {
                Text("Already in the app: \(knownCount)")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
            }

            if transferCount > 0 {
                Text("Between own cards, skipped by default: \(transferCount)")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
            }

            if skippedCount > 0 {
                Text("Not operations, skipped: \(skippedCount)")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
            }

            if unrecognisedCount > 0 {
                Text("Unrecognised, saved for review: \(unrecognisedCount)")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func row(_ item: SMSPreviewItem) -> some View {
        let dimmed = item.status == .known || item.status == .ignored

        return HStack(spacing: 10) {
            Image(systemName: item.ownTransfer ? "arrow.left.arrow.right.circle.fill" : icon(for: item.status))
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .foregroundColor(item.status == .fresh ? Color.IncomeGreen : Color.SubtitleText)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: item))
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText)
                    .lineLimit(1)

                Text(caption(for: item))
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if item.parsed.amountMinor != nil, item.status != .ignored {
                Text(SMSFormat.amountText(item.parsed))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(item.parsed.isIncome && !item.ownTransfer ? Color.IncomeGreen : Color.PrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
        }
        .smsCard(padding: 10)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private func icon(for status: SMSPreviewItem.Status) -> String {
        switch status {
        case .fresh: return "checkmark.circle.fill"
        case .unrecognised: return "questionmark.circle"
        case .known: return "arrow.triangle.2.circlepath"
        case .ignored: return "minus.circle"
        }
    }

    private func title(for item: SMSPreviewItem) -> String {
        switch item.status {
        case .unrecognised, .ignored:
            return item.text
        case .fresh, .known:
            return SMSFormat.title(item.parsed)
        }
    }

    private func caption(for item: SMSPreviewItem) -> String {
        switch item.status {
        case .unrecognised:
            return String(localized: "Unrecognised, will wait for review")
        case .ignored:
            switch item.parsed.skipReason {
            case .some(.declined):
                return String(localized: "Declined, no money moved. Skipped")
            case .some(.code):
                return String(localized: "Code or password. Skipped")
            default:
                return String(localized: "Not a payment, ignored")
            }
        case .known:
            return String(localized: "Already in the app")
        case .fresh:
            let line = SMSFormat.subtitle(item.parsed, cards: SMSCardStore.shared)

            // Both halves go to Transfers and are skipped unless logged by hand.
            return item.ownTransfer ? String(localized: "Between own cards") + ", " + line : line
        }
    }

    private var importButton: some View {
        Button {
            runImport()
        } label: {
            Text(importable > 0 ? String(localized: "Import: \(importable)") : String(localized: "Nothing to import"))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundColor(importable > 0 ? Color.LightIcon : Color.SubtitleText)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    importable > 0 ? Color.DarkBackground : Color.SecondaryBackground,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importable == 0)
    }

    // MARK: Actions

    private func refresh() {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items = []
        } else {
            items = SMSIngestor.shared.preview(text: text)
        }
    }

    private func paste() {
        Haptics.tap()

        guard let pasted = SMSClipboard.shared.read(), !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastCenter.shared.error(String(localized: "The clipboard is empty"))
            return
        }

        fromFile = false
        text = text.isEmpty ? pasted : text + "\n" + pasted
    }

    private func loadFile(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else {
            return
        }

        // A file picked from Files sits outside the sandbox until access is opened.
        let scoped = url.startAccessingSecurityScopedResource()

        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        else {
            ToastCenter.shared.error(String(localized: "Couldn't read the file"))
            return
        }

        fromFile = true
        text = content
    }

    private func runImport() {
        editorFocused = false

        let result = SMSIngestor.shared.ingest(text: text, source: fromFile ? .file : .paste)

        if result.failed {
            ToastCenter.shared.error(result.summary)
            return
        }

        SMSClipboard.shared.markHandled()
        dismiss()

        // Posted after the dismiss starts, so the host under the sheet draws it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            ToastCenter.shared.success(result.summary)
        }
    }
}
