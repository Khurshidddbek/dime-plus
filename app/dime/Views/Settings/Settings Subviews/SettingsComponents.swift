//
//  SettingsComponents.swift
//  dime
//
//  Small pieces shared by the settings screens, in the look the old screens already have.
//

import SwiftUI

/// A file handed to the share sheet through `.sheet(item:)`.
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Centred title with the round back button on the left.
struct SettingsSubviewHeader: View {
    let title: LocalizedStringKey

    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>

    var body: some View {
        Text(title)
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundColor(Color.PrimaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 44)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    SettingsBackButton()
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Back"))
            }
            .accessibilityAddTraits(.isHeader)
    }
}

/// Grey caption under a settings card.
struct SettingsFootnote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .multilineTextAlignment(.leading)
            .foregroundColor(Color.SubtitleText)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small upper-case title above a settings card.
struct SettingsSectionTitle: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundColor(Color.SubtitleText)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Full-width button. Dark when prominent, card-coloured otherwise.
struct SettingsActionButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var prominent: Bool = false
    var destructive: Bool = false
    var busy: Bool = false
    let action: () -> Void

    private var foreground: Color {
        if prominent {
            return Color.LightIcon
        }

        return destructive ? Color.AlertRed : Color.PrimaryText
    }

    var body: some View {
        Button {
            if !busy {
                action()
            }
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .tint(foreground)
                } else if let systemImage = systemImage {
                    Image(systemName: systemImage)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }

                // Russian labels run about 30% longer: wrap to a second line instead of truncating.
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 46)
            .frame(maxWidth: .infinity)
            .background(prominent ? Color.DarkBackground : Color.SettingsBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// The capsule switch the settings rows draw. Display only: the row handles the tap.
struct SettingsSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .frame(width: 42, height: 28)
                .foregroundColor(isOn ? .green : .gray.opacity(0.8))

            Circle()
                .foregroundColor(Color.white)
                .padding(2)
                .frame(width: 28, height: 28)
        }
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .accessibilityHidden(true)
    }
}

/// Label on the left, value on the right, inside a settings card.
struct SettingsValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var valueColor: Color = Color.SubtitleText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundColor(Color.PrimaryText)

            Spacer(minLength: 0)

            Text(value)
                .font(.system(.body, design: .rounded))
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
