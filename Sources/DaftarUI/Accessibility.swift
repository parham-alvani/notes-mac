import AppKit
import SwiftUI

/// Reduce Motion: an animation the person asked not to see is none.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// [animation], or nil with Reduce Motion on.
    static func animation(_ animation: Animation?) -> Animation? { reduced ? nil : animation }
}

/// `withAnimation` that keeps to Reduce Motion.
@MainActor
func withMotion<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.animation(animation), body)
}

/// `.animation(_:value:)` that keeps to Reduce Motion.
private struct MotionAnimation<Value: Equatable>: ViewModifier {
    var animation: Animation?
    var value: Value
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content.animation(reduce ? nil : animation, value: value)
    }
}

/// The third level of grey, a step darker with Increase Contrast.
private struct Faint: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if contrast == .increased { content.foregroundStyle(.secondary) } else { content.foregroundStyle(.tertiary) }
    }
}

extension View {
    func motionAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// `.foregroundStyle(.tertiary)`, readable with Increase Contrast.
    func faint() -> some View { modifier(Faint()) }

    /// A row of an icon-free list that acts as a button: one element with
    /// [label], the button trait, selected when [selected], and [action]
    /// as its press, for a row drawn with `onTapGesture`.
    func accessibilityRow(_ label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

/// Says [text] with VoiceOver, for a change no focus move shows: a notice,
/// a copied link, an error in a panel.
@MainActor
func announce(_ text: String) {
    guard !text.isEmpty else { return }
    NSAccessibility.post(
        element: NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested,
        userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}
