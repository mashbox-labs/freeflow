import Foundation

/// The Mac hotkey: push to talk on fn. Pure logic, no AppKit: the Mac app's event tap feeds key events in, and each
/// call says what the dictation does and whether the key is kept from the app in front.
///
/// Behaviour:
/// - Hold fn and talk; let go to insert. A press let go in under half a second inserts nothing.
/// - Hands-free: double-press fn within half a second, or press fn+Space while holding fn. Press fn (or fn+Space)
///   again to stop and insert. A third quick press right after a double-press cancels.
/// - Esc cancels a recording.
/// Shortcuts: fn with another key (fn+arrow, fn+Delete, fn+F1) is a shortcut, not dictation, so it cancels and
/// the key goes through; fn pressed together with Command, Control, Option or Shift is ignored.
public struct FnGesture: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case idle, holding, handsFree }
    public enum Key: Equatable, Sendable { case space, escape, other }
    public enum Action: Equatable, Sendable {
        case none
        case start            // start recording (push to talk)
        case startHandsFree   // start recording that keeps going without fn held
        case becomeHandsFree  // the recording in progress keeps going without fn held
        case stopAndInsert
        case cancel
    }

    /// Half a second: the shortest press that inserts, and the double-press window.
    public static let quick: Double = 0.5

    public private(set) var mode: Mode = .idle
    public private(set) var fnDown = false
    private var downAt: Double = 0
    /// Down time of the last press let go too quickly to insert (the first half of a double press).
    private var lastTapDownAt: Double?
    private var handsFreeAt: Double = 0
    /// This fn press started hands-free, so letting it go keeps recording.
    private var pressStartedHandsFree = false
    /// This fn press, made during hands-free, stops the recording when it is let go.
    private var stopOnRelease = false

    public init() {}

    /// fn went down at `t` (seconds on a monotonic clock).
    public mutating func fnPressed(at t: Double, otherModifiers: Bool = false) -> Action {
        guard !fnDown else { return .none }
        fnDown = true
        downAt = t
        pressStartedHandsFree = false
        stopOnRelease = false
        switch mode {
        case .idle:
            if otherModifiers { lastTapDownAt = nil; return .none }
            if let tap = lastTapDownAt, t - tap <= Self.quick {
                lastTapDownAt = nil
                mode = .handsFree
                handsFreeAt = t
                pressStartedHandsFree = true
                return .startHandsFree
            }
            lastTapDownAt = nil
            mode = .holding
            return .start
        case .holding:
            return .none
        case .handsFree:
            if t - handsFreeAt <= Self.quick {
                reset()
                return .cancel
            }
            stopOnRelease = true
            return .none
        }
    }

    /// fn came up at `t`.
    public mutating func fnReleased(at t: Double) -> Action {
        guard fnDown else { return .none }
        fnDown = false
        switch mode {
        case .idle:
            return .none
        case .holding:
            mode = .idle
            if t - downAt < Self.quick {
                lastTapDownAt = downAt
                return .cancel
            }
            return .stopAndInsert
        case .handsFree:
            if pressStartedHandsFree { pressStartedHandsFree = false; return .none }
            if stopOnRelease { reset(); return .stopAndInsert }
            return .none
        }
    }

    /// Another key went down at `t`. `swallow` true: the key is Free Flow's and does not reach the app in front.
    public mutating func keyPressed(_ key: Key, at t: Double) -> (action: Action, swallow: Bool) {
        if key == .escape {
            guard mode != .idle else { return (.none, false) }
            reset()
            return (.cancel, true)
        }
        guard fnDown else { return (.none, false) }
        switch (mode, key) {
        case (.holding, .space):
            mode = .handsFree
            handsFreeAt = t
            pressStartedHandsFree = true
            return (.becomeHandsFree, true)
        case (.handsFree, .space):
            // fn+Space again stops; Space inside the press that started hands-free is just held down again.
            if pressStartedHandsFree { return (.none, true) }
            reset()
            return (.stopAndInsert, true)
        case (.holding, .other):
            reset()
            return (.cancel, false)
        case (.handsFree, .other):
            // fn used for a shortcut during hands-free: this press no longer stops the recording.
            stopOnRelease = false
            return (.none, false)
        default:
            return (.none, false)
        }
    }

    /// The recording ended some other way (the pill's buttons, an error). fn's own up/down state is kept.
    public mutating func reset() {
        mode = .idle
        lastTapDownAt = nil
        pressStartedHandsFree = false
        stopOnRelease = false
    }
}
