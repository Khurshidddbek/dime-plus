//
//  ToastCenter.swift
//  dime
//

import SwiftUI
import UIKit

// App target only. One feedback channel for the whole app: any screen or service posts to
// ToastCenter.shared, the topmost .toastHost() draws it.

struct ToastMessage: Identifiable {
    enum Kind {
        case success
        case info
        case error
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let icon: String
    let actionTitle: String?
    let action: (() -> Void)?
    let duration: TimeInterval

    var tint: Color {
        switch kind {
        case .success: return Color.IncomeGreen
        case .info: return Color.PrimaryText
        case .error: return Color.AlertRed
        }
    }

    static func defaultIcon(for kind: Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: ToastMessage?
    // Hosts in mount order. Only the last one draws, so a toast is never shown twice
    // (root screen plus the sheet above it).
    @Published private(set) var hosts: [UUID] = []

    private var hideWork: DispatchWorkItem?

    private init() {}

    // MARK: Posting

    // title must already be localised: String(localized: "key").
    // A new toast replaces the one on screen and restarts the timer.
    func show(
        _ kind: ToastMessage.Kind,
        _ title: String,
        icon: String? = nil,
        actionTitle: String? = nil,
        duration: TimeInterval? = nil,
        haptic: Bool = true,
        action: (() -> Void)? = nil
    ) {
        let hasAction = action != nil
        let message = ToastMessage(
            kind: kind,
            title: title,
            icon: icon ?? ToastMessage.defaultIcon(for: kind),
            actionTitle: hasAction ? (actionTitle ?? String(localized: "Undo")) : nil,
            action: action,
            duration: duration ?? (hasAction ? 5 : 2.5)
        )

        if Thread.isMainThread {
            present(message, haptic: haptic)
        } else {
            DispatchQueue.main.async {
                self.present(message, haptic: haptic)
            }
        }
    }

    func success(_ title: String, icon: String? = nil) {
        show(.success, title, icon: icon)
    }

    func info(_ title: String, icon: String? = nil) {
        show(.info, title, icon: icon)
    }

    func error(_ title: String, icon: String? = nil) {
        show(.error, title, icon: icon)
    }

    // "Log Deleted   Undo": stays 5 s, a tap anywhere on the toast runs the action.
    func undo(_ title: String, icon: String = "arrow.uturn.backward.circle.fill", action: @escaping () -> Void) {
        // Red like the old "Log Deleted" toast, but a delete is not an error: no error haptic.
        show(.error, title, icon: icon, actionTitle: String(localized: "Undo"), haptic: false, action: action)
        Haptics.impact(.medium)
    }

    func saveFailed() {
        show(.error, String(localized: "Couldn't save"))
    }

    // MARK: Hiding

    func dismiss() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.dismiss()
            }
            return
        }
        hideWork?.cancel()
        hideWork = nil
        guard current != nil else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            current = nil
        }
    }

    // Called by the host when the toast is tapped.
    func activate(_ message: ToastMessage) {
        guard current?.id == message.id else { return }
        dismiss()
        if let action = message.action {
            Haptics.tap()
            action()
        }
    }

    // MARK: Hosts

    func register(host id: UUID) {
        if !hosts.contains(id) {
            hosts.append(id)
        }
    }

    func unregister(host id: UUID) {
        hosts.removeAll { $0 == id }
    }

    // MARK: Internals

    private func present(_ message: ToastMessage, haptic: Bool) {
        hideWork?.cancel()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            current = message
        }

        if haptic {
            switch message.kind {
            case .success: Haptics.success()
            case .info: Haptics.tap()
            case .error: Haptics.error()
            }
        }

        UIAccessibility.post(notification: .announcement, argument: message.title)

        let id = message.id
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.current?.id == id else { return }
            self.dismiss()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + message.duration, execute: work)
    }
}

struct ToastHost: View {
    @ObservedObject private var center = ToastCenter.shared
    @State private var hostID = UUID()

    var body: some View {
        ZStack(alignment: .top) {
            if let message = center.current, center.hosts.last == hostID {
                ToastPill(message: message) {
                    center.activate(message)
                } onDismiss: {
                    center.dismiss()
                }
                .id(message.id)
                .transition(AnyTransition.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            center.register(host: hostID)
        }
        .onDisappear {
            center.unregister(host: hostID)
        }
    }
}

private struct ToastPill: View {
    let message: ToastMessage
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        HStack(spacing: 6.5) {
            Image(systemName: message.icon)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))

            Text(message.title)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let actionTitle = message.actionTitle {
                Text(actionTitle)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.vertical, 3)
                    .padding(.horizontal, 9)
                    .background(message.tint.opacity(0.23), in: Capsule())
                    .padding(.leading, 6)
            }
        }
        .foregroundColor(message.tint)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: message.actionTitle == nil ? 35 : 44)
        .background(message.tint.opacity(0.23), in: shape)
        // Opaque base: the tinted pill floats over lists, not over a plain header.
        .background(Color.PrimaryBackground, in: shape)
        .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 3)
        .contentShape(shape)
        .onTapGesture {
            onTap()
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -10 {
                        onDismiss()
                    }
                }
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(message.action == nil ? [] : .isButton)
    }
}

extension View {
    // Mount once on the root screen and once on every sheet or full screen cover root.
    func toastHost() -> some View {
        overlay(alignment: .top) {
            ToastHost()
        }
    }
}
