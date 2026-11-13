//
//  SMSInboxEntryCard.swift
//  dime
//
//  Compact card for the top of the Log: how many bank messages wait and the newest one.
//  Takes no space while there is nothing to show.
//

import SwiftUI

struct SMSInboxEntryCard: View {
    @ObservedObject private var inbox = SMSInboxStore.shared
    @ObservedObject private var clipboard = SMSClipboard.shared

    private let onOpen: () -> Void

    init(onOpen: @escaping () -> Void = { SMSRouter.shared.openInbox() }) {
        self.onOpen = onOpen
    }

    /// The newest message that has an amount, else the newest one.
    private var newest: SMSSuggestion? {
        inbox.pending.first { !$0.isUnrecognised } ?? inbox.pending.first
    }

    // Only a clipboard that holds a money amount is worth a chip on the main screen.
    private var showsClipboardChip: Bool {
        clipboard.state == .likely
    }

    var body: some View {
        Group {
            if newest != nil || showsClipboardChip {
                VStack(spacing: 8) {
                    if let newest = newest {
                        Button {
                            Haptics.tap()
                            onOpen()
                        } label: {
                            card(newest)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }

                    if showsClipboardChip {
                        clipboardChip
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: inbox.pending.count)
        .animation(.easeInOut(duration: 0.2), value: showsClipboardChip)
    }

    private func card(_ suggestion: SMSSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble.fill")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundColor(Color.LightIcon)
                .frame(width: 40, height: 40)
                .background(Color.DarkBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Bank messages")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(Color.PrimaryText)
                        .lineLimit(1)

                    Text("\(inbox.pending.count)")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(Color.LightIcon)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 22, minHeight: 20)
                        .background(Color.DarkBackground, in: Capsule())
                }

                newestLine(suggestion)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.forward")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(Color.SubtitleText)
                .accessibilityHidden(true)
        }
        .smsCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the messages to review"))
    }

    // Two texts on purpose: a long merchant name is cut, the amount never is.
    @ViewBuilder
    private func newestLine(_ suggestion: SMSSuggestion) -> some View {
        if suggestion.isUnrecognised {
            Text("Could not read a message")
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Text(verbatim: SMSFormat.title(suggestion.parsed) + ",")
                    .lineLimit(1)

                Text(verbatim: SMSFormat.amountText(suggestion.parsed))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    private var clipboardChip: some View {
        HStack(spacing: 8) {
            Button {
                pasteFromClipboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))

                    Text("Paste bank SMS from clipboard")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundColor(Color.PrimaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                clipboard.markHandled()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundColor(Color.SubtitleText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // The text is read only here, after a tap: this is the moment iOS may ask about pasting.
    private func pasteFromClipboard() {
        guard let text = clipboard.read(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastCenter.shared.error(String(localized: "No bank messages found"))
            return
        }

        let result = SMSIngestor.shared.ingest(text: text, source: .paste)

        if result.failed {
            ToastCenter.shared.error(result.summary)
        } else if result.stored == 0 {
            if result.duplicates > 0 || result.alreadyLogged > 0 || result.skippedByRule > 0 {
                ToastCenter.shared.info(result.summary)
            } else {
                ToastCenter.shared.error(String(localized: "No bank messages found"))
            }
        } else {
            ToastCenter.shared.success(result.summary)
        }
    }
}
