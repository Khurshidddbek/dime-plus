//
//  Haptics.swift
//  dime
//

import SwiftUI
import UIKit

// App target only. The single place that plays haptics, so the Haptics setting is honoured everywhere.

enum Haptics {
    enum Level: Int {
        case none = 0
        case subtle = 1
        case excessive = 2
    }

    enum Feedback: Equatable {
        case tap // light touch on buttons, chips, toggles
        case selection // picker or segment moved
        case success
        case warning
        case error
        case light
        case medium
        case heavy
        case soft
        case rigid
        case key // number pad key, plays only in the Excessive mode
    }

    static let settingKey = "haptics"

    static var level: Level {
        // object(forKey:) on purpose: integer(forKey:) gives 0 for an unset key and would mute everything.
        let raw = UserDefaults.appGroup.object(forKey: settingKey) as? Int ?? Level.subtle.rawValue
        return Level(rawValue: raw) ?? .subtle
    }

    static var isEnabled: Bool {
        level != .none
    }

    // MARK: Semantic calls

    static func tap() { play(.tap) }
    static func selection() { play(.selection) }
    static func success() { play(.success) }
    static func warning() { play(.warning) }
    static func error() { play(.error) }
    static func key() { play(.key) }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        switch style {
        case .light: play(.light)
        case .medium: play(.medium)
        case .heavy: play(.heavy)
        case .soft: play(.soft)
        case .rigid: play(.rigid)
        @unknown default: play(.medium)
        }
    }

    static func play(_ feedback: Feedback) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                Haptics.play(feedback)
            }
            return
        }

        let current = level
        if current == .none { return }
        if feedback == .key, current != .excessive { return }

        switch feedback {
        case .tap, .light:
            fire(lightGenerator)
        case .medium:
            fire(mediumGenerator)
        case .heavy:
            fire(heavyGenerator)
        case .soft:
            fire(softGenerator)
        case .rigid, .key:
            fire(rigidGenerator)
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .success:
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        case .warning:
            notificationGenerator.notificationOccurred(.warning)
            notificationGenerator.prepare()
        case .error:
            notificationGenerator.notificationOccurred(.error)
            notificationGenerator.prepare()
        }
    }

    // Wakes the Taptic Engine before a moment that must feel instant (sheet with a number pad).
    static func prepare() {
        guard Thread.isMainThread, isEnabled else { return }
        lightGenerator.prepare()
        rigidGenerator.prepare()
        notificationGenerator.prepare()
    }

    // MARK: Generators

    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    private static func fire(_ generator: UIImpactFeedbackGenerator) {
        generator.impactOccurred()
        generator.prepare()
    }
}

private struct HapticOnChangeModifier<Value: Equatable>: ViewModifier {
    let feedback: Haptics.Feedback
    let trigger: Value

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, _ in
            Haptics.play(feedback)
        }
    }
}

extension View {
    // Plays the feedback every time trigger changes, respecting the Haptics setting.
    func haptic<Value: Equatable>(_ feedback: Haptics.Feedback, trigger: Value) -> some View {
        modifier(HapticOnChangeModifier(feedback: feedback, trigger: trigger))
    }
}
