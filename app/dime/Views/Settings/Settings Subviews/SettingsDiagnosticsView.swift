//
//  SettingsDiagnosticsView.swift
//  dime
//
//  Settings > Diagnostics: the last lines of the app log (saves, backups, sync, imports)
//  and a button to share the whole log as a text file.
//

import SwiftUI

struct SettingsDiagnosticsView: View {
    @EnvironmentObject var persistence: PersistenceStatus

    @State private var lines: [String] = []
    @State private var loaded = false
    @State private var shareFile: ShareFile?
    @State private var confirmClear = false
    @State private var onlyProblems = false

    private var shownLines: [String] {
        let source = onlyProblems ? lines.filter { $0.contains("FAILED") || $0.contains("INTEGRITY") || $0.contains("incomplete") } : lines

        return Array(source.reversed())
    }

    var body: some View {
        VStack(spacing: 10) {
            SettingsSubviewHeader(title: "Diagnostics")
                .padding(.bottom, 10)

            if persistence.saveFailure != nil {
                Button {
                    if persistence.retrySave() {
                        ToastCenter.shared.success(String(localized: "Saved"))
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))

                        Text("Not saved - tap to retry")
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(Color.AlertRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minHeight: 46)
                    .frame(maxWidth: .infinity)
                    .background(Color.AlertRed.opacity(0.23), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                SettingsActionButton(title: "Share log", systemImage: "square.and.arrow.up", prominent: true) {
                    share()
                }

                SettingsActionButton(title: "Clear", systemImage: "trash", destructive: true) {
                    confirmClear = true
                }
            }

            Button {
                Haptics.selection()

                withAnimation(.easeInOut(duration: 0.15)) {
                    onlyProblems.toggle()
                }
            } label: {
                HStack {
                    Text("Only problems")
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(Color.PrimaryText)

                    Spacer()

                    SettingsSwitch(isOn: onlyProblems)
                }
                .padding(.horizontal, 15)
                .frame(minHeight: 46)
                .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(onlyProblems ? Text("On") : Text("Off"))

            SettingsFootnote(text: "Newest first. The log stays on this device and holds no amounts or notes.")

            ScrollView(showsIndicators: false) {
                if !loaded {
                    ProgressView()
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else if shownLines.isEmpty {
                    Text("Nothing logged yet")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(Color.SubtitleText)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(shownLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(line.contains("FAILED") || line.contains("INTEGRITY") ? Color.AlertRed : Color.PrimaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .background(Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.bottom, 90)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(SettingsSubviewModifier())
        .onAppear {
            reload()
        }
        .sheet(item: $shareFile) { file in
            ActivityViewController(activityItems: [file.url])
        }
        .confirmationDialog("Clear the diagnostics log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                DiagnosticsLog.shared.clear()
                lines = []
                Haptics.tap()
            }

            Button("Cancel", role: .cancel) {}
        }
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let recent = DiagnosticsLog.shared.recentLines(400)

            DispatchQueue.main.async {
                lines = recent
                loaded = true
            }
        }
    }

    private func share() {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = DiagnosticsLog.shared.exportURL()

            DispatchQueue.main.async {
                if let url = url {
                    Haptics.tap()
                    shareFile = ShareFile(url: url)
                } else {
                    ToastCenter.shared.error(String(localized: "Couldn't prepare the log"))
                }
            }
        }
    }
}
