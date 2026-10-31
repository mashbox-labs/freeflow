import FreeFlowKit
import QuartzCore
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// One click per key, like the system keyboard (the impact generator, prepared once Full Access is known).
/// A keyboard can only play haptics with Allow Full Access.
@MainActor
final class KeyFeel {
    private(set) var level = KeyTick.Level.medium
    private var fullAccess = false
    private let click = UIImpactFeedbackGenerator(style: .light)
    /// Free Flow's mic session is ready (set by the controller), for the click check.
    var micReady: @MainActor () -> Bool = { false }
    /// This keyboard's click check counts since the last save (KeyClickCounts: counts only, on this device).
    private var counted = KeyClickCounts()

    var on: Bool { fullAccess && level != .off }

    /// Called from viewWillAppear, after the Full Access check.
    func load(fullAccess: Bool) {
        self.fullAccess = fullAccess
        level = SharedSession.keyHaptics
        if on { click.prepare() }
    }

    /// Key touch down: one click at the level set in Settings. The key's text is inserted on touch up.
    func press(_ kind: KeyTick.Kind) {
        counted.note(fullAccess: fullAccess, clicksOff: level == .off, micReady: micReady())
        if counted.presses >= 10 { save() }
        guard on else { return }
        let i = KeyTick.Level.allCases.firstIndex(of: level) ?? 2
        click.impactOccurred(intensity: [0, 0.55, 0.8, 1.0][min(i, 3)])
        click.prepare()
    }

    /// Adds this keyboard's counts to the App Group total (a keyboard can only write there with Full Access).
    func save() {
        guard !counted.isEmpty else { return }
        var all = KeyClickCounts.stored
        all.add(counted)
        KeyClickCounts.stored = all
        counted = KeyClickCounts()
    }
}

/// Key fills in the system keyboard's own shades (FreeFlowKit KeyShades, shared with the app's layout preview).
enum KeyColors {
    /// Not seen, only there so every point of the keyboard takes touches (FreeFlowKit KeyShades.touchFloor; the
    /// layout previews draw the same floor).
    static let touchFloor = KeyShades.touchFloorUI
    static let key = KeyShades.key
    static let modifier = KeyShades.modifier
}

/// A key: its fill swaps shade while pressed, like Apple's keyboard, and it clicks on touch down. Only the
/// colour changes (no movement, no size change), so there is nothing for Reduce Motion to stop.
struct KeyStyle: ButtonStyle {
    let kind: KeyTick.Kind
    let feel: KeyFeel

    func makeBody(configuration: Configuration) -> some View {
        let lightKey = kind == .letter || kind == .space
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KeyShades.fill(light: lightKey, down: configuration.isPressed)))
            .modifier(ClickOnPress(pressed: configuration.isPressed, kind: kind, feel: feel))
    }
}

/// For buttons that keep their own look (the mic): click on touch down and dim slightly while pressed.
struct ClickStyle: ButtonStyle {
    let kind: KeyTick.Kind
    let feel: KeyFeel

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .modifier(ClickOnPress(pressed: configuration.isPressed, kind: kind, feel: feel))
    }
}

private struct ClickOnPress: ViewModifier {
    let pressed: Bool
    let kind: KeyTick.Kind
    let feel: KeyFeel

    func body(content: Content) -> some View {
        content.onChange(of: pressed) { _, down in if down { feel.press(kind) } }
    }
}
