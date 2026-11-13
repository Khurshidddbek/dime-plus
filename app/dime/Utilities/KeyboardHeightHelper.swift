//
//  KeyboardHeightHelper.swift
//  xpenz
//
//  Created by Rafael Soh on 16/5/22.
//

import Combine
import Foundation
import SwiftUI
import UIKit

class KeyboardHeightHelper: ObservableObject {
    @Published var keyboardHeight: CGFloat = 0

    private var observer: NSObjectProtocol?

    private func listenForKeyboardNotifications() {
        // Weak self plus removal in deinit: views create this object on every init,
        // a strong block observer would keep each one alive for the life of the app.
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification,
                                                          object: nil,
                                                          queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let keyboardRect = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

            self?.keyboardHeight = keyboardRect.height
        }
    }

    init() {
        listenForKeyboardNotifications()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension Publishers {
    // 1.
    static var keyboardHeight: AnyPublisher<CGFloat, Never> {
        // 2.
        let willShow = NotificationCenter.default.publisher(for: UIApplication.keyboardWillShowNotification)
            .map { $0.keyboardHeight }

        let willHide = NotificationCenter.default.publisher(for: UIApplication.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }

        // 3.
        return MergeMany(willShow, willHide)
            .eraseToAnyPublisher()
    }
}

extension Notification {
    var keyboardHeight: CGFloat {
        return (userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
    }
}

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct KeyboardAwareModifier: ViewModifier {
    @AppStorage("keyboard", store: UserDefaults.appGroup) var savedKeyboardHeight: Double = .init(UIScreen.main.bounds.height / 2.5)
    var showToolbar: Bool

    private var keyboardHeightPublisher: AnyPublisher<CGFloat, Never> {
        Publishers.Merge(
            NotificationCenter.default
                .publisher(for: UIResponder.keyboardWillShowNotification)
                .compactMap { $0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue }
                .map { $0.cgRectValue.height },
            NotificationCenter.default
                .publisher(for: UIResponder.keyboardWillHideNotification)
                .map { _ in CGFloat(0) }
        ).eraseToAnyPublisher()
    }

    // One odd keyboard (emoji, third party, a stale value from another device) must not deform the pad.
    private var clampedHeight: CGFloat {
        let screen = UIScreen.main.bounds.height
        return min(max(CGFloat(savedKeyboardHeight), screen * 0.30), screen * 0.45)
    }

    func body(content: Content) -> some View {
        content
            .frame(height: clampedHeight)
            .onReceive(keyboardHeightPublisher) { value in
                let screen = UIScreen.main.bounds.height

                if value > 200, value < screen * 0.5 {
                    let wanted = Double(value - 20)

                    if abs(wanted - savedKeyboardHeight) > 0.5 {
                        savedKeyboardHeight = wanted
                    }
                }
            }
    }
}

extension View {
    func keyboardAwareHeight(showToolbar: Bool) -> some View {
        ModifiedContent(content: self, modifier: KeyboardAwareModifier(showToolbar: showToolbar))
    }
}
