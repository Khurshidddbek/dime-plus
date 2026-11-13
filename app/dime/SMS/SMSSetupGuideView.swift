//
//  SMSSetupGuideView.swift
//  dime
//
//  Step-by-step instructions for the Shortcuts automation that hands every bank SMS
//  to AddBankSMSIntent. Works as a sheet and as a pushed settings screen.
//

import SwiftUI

struct SMSSetupGuideView: View {
    @ObservedObject private var inbox = SMSInboxStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var sample: SMSPreviewItem?
    @State private var sampleFailed = false
    @State private var showHelp = false

    /// Sender names of the bank messages: Humo cards and Uzcard cards.
    static let senders = ["HUMOCARD", "CARDINFO"]

    /// The words the older "Message Contains" filter needs, exactly as the banks print them.
    static let triggerWords = ["HUMOCARD", "karta", "Miqdor"]

    // The flow seen in Shortcuts on iOS 27.
    private static let steps: [LocalizedStringKey] = [
        "Open the Shortcuts app and tap + to make a new shortcut.",
        "In the action search open the Automation category and choose the Message trigger.",
        "Tap Sender is and type HUMOCARD, then add CARDINFO as a second sender. Type them as text, they are not in your contacts.",
        "Add the action Add Bank SMS from Dime+.",
        "In its Message text field choose the message content (Shortcut Input).",
        "Set it to run immediately without asking and turn off the notification when it runs. Tap Done.",
    ]

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            SMSScreenHeader("Set up automation", onClose: { dismiss() })
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shortcuts can pass every bank SMS to the app the moment it arrives. Nothing opens, the message just waits for you in the inbox.")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                        .fixedSize(horizontal: false, vertical: true)

                    status

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.steps.indices, id: \.self) { index in
                            step(index + 1, Self.steps[index])
                        }
                    }
                    .smsCard(padding: 14)

                    words

                    SMSPillButton(title: String(localized: "Open Shortcuts"), systemImage: "arrow.up.forward.app") {
                        openShortcuts()
                    }

                    test

                    help
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.PrimaryBackground.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .toastHost()
    }

    // MARK: Blocks

    private var status: some View {
        let last = inbox.lastAutomationRunAt

        return HStack(spacing: 10) {
            Image(systemName: last == nil ? "clock" : "checkmark.circle.fill")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundColor(last == nil ? Color.SubtitleText : Color.IncomeGreen)
                .accessibilityHidden(true)

            if let last = last {
                Text("Works. Last message came \(Fmt.relative(last)).")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.PrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Waiting for the first message from Shortcuts.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.SubtitleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .smsCard()
        .accessibilityElement(children: .combine)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundColor(Color.LightIcon)
                .frame(width: 26, height: 26)
                .background(Color.DarkBackground, in: Circle())

            Text(text)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundColor(Color.PrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 8) {
            SMSGroupTitle(title: "Senders", count: 0)

            Text("HUMOCARD sends the Humo messages, CARDINFO the Uzcard ones. Tap a name to copy it.")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(Self.senders, id: \.self) { word in
                    Button {
                        SMSClipboard.shared.copy(word)
                        ToastCenter.shared.success(String(localized: "Copied \(word)"))
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: word)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)

                            Image(systemName: "doc.on.doc")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                        }
                        .foregroundColor(Color.PrimaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.SecondaryBackground, in: RoundedRectangle(cornerRadius: 11.5, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy \(word)"))
                }
            }

            // Older iOS has no sender filter in the message automation.
            Text("No Sender is on an older iOS? Use Message Contains with one of these words instead, one automation per word: \(Self.triggerWords.joined(separator: ", ")).")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundColor(Color.SubtitleText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, 4)
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 8) {
            SMSPillButton(title: String(localized: "Test with a sample"), systemImage: "play.fill", prominent: false) {
                runSample()
            }

            if let sample = sample {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sample.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Color.SubtitleText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.IncomeGreen)
                            .accessibilityHidden(true)

                        Text(verbatim: sampleLine(sample))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundColor(Color.PrimaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("The app reads this message. Nothing was added to your Log.")
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .smsCard()
                .transition(.opacity)
            } else if sampleFailed {
                Text("The sample was not read. Please report it: the parser is broken in this build.")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundColor(Color.AlertRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .smsCard()
            }
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.tap()

                withAnimation(.easeInOut(duration: 0.2)) {
                    showHelp.toggle()
                }
            } label: {
                HStack {
                    Text("If nothing happens")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(Color.PrimaryText)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundColor(Color.SubtitleText)
                        .rotationEffect(.degrees(showHelp ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHelp {
                VStack(alignment: .leading, spacing: 8) {
                    helpLine("Check that the automation is switched on in Shortcuts.")
                    helpLine("After a restart the phone has to be unlocked once before automations run.")
                    helpLine("Type the sender exactly as shown, in capital letters.")
                    helpLine("Run Immediately needs iOS 17 or later.")
                    helpLine("A message that was missed can always be pasted by hand. The same message is never added twice.")
                }
                .transition(.opacity)
            }
        }
        .smsCard()
    }

    private func helpLine(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "-")
                .foregroundColor(Color.SubtitleText)

            Text(text)
                .foregroundColor(Color.SubtitleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.footnote, design: .rounded).weight(.medium))
    }

    // MARK: Actions

    private func openShortcuts() {
        Haptics.tap()

        guard let url = URL(string: "shortcuts://") else {
            return
        }

        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                ToastCenter.shared.error(String(localized: "Couldn't open Shortcuts"))
            }
        }
    }

    // Runs the parser on a Humo message dated now. Nothing is stored.
    private func runSample() {
        let found = SMSIngestor.shared.preview(text: SMSParser.sampleMessage(), source: .test).first
        let works = found?.parsed.amountMinor != nil && found?.parsed.confidence == 1

        withAnimation(.easeInOut(duration: 0.2)) {
            sample = works ? found : nil
            sampleFailed = !works
        }

        if works {
            Haptics.success()
        } else {
            Haptics.error()
        }
    }

    private func sampleLine(_ item: SMSPreviewItem) -> String {
        SMSFormat.title(item.parsed) + ", " + SMSFormat.amountText(item.parsed) + ", "
            + SMSFormat.subtitle(item.parsed, cards: SMSCardStore.shared)
    }
}
