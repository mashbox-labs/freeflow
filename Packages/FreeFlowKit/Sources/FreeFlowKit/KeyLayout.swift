import CoreGraphics
import Foundation

// Layout data for Comfort and the setting that picks the layout. The numbers come from tools/keys
// (tap simulator, dev text only) and the research floors documented there.

public extension ComfortSpec {
    /// iPhone, dictation first: per dictated message 1 mic tap, 1 return and about 5 typed keys.
    /// Row heights: chosen on dev text by the tap simulator (iPhone Air: 60 / 48 / 48 / 48 / 76 pt).
    /// Width weights: taps per message; space, 123 from the dev text's letter, space and punctuation shares.
    /// v2 (2026-10-29): a hide key at the far end from Dictate (9.2 mm, the one-thumb floor), Dictate keeps the
    /// rest of the row on the thumb's side; return is an L clear of backspace (see KeyGeometry).
    static let phone = ComfortSpec(
        rowMM: (action: 9.939130434782609, letter: 7.951304347826087, bottom: 12.589565217391304),
        rowMinMM: (action: 7.3, letter: 7.3, bottom: 7.3),
        action: [Item("hide", weight: 0.02, minMM: 9.2), Item("style", weight: 0.02, minMM: 9.2, minPt: 84), Item("mic", weight: 1.0, minMM: 9.2)],
        bottom: [Item("abc123", weight: 0.39205913822968697, minMM: 9.2), Item("globe", weight: 0.02, minMM: 7.3),
                 Item("space", weight: 0.9275202722995295, minMM: 9.2, minPitch: 5), Item("return", weight: 1.0, minMM: 9.2)],
        gap: 6, edge: 3, lift: 0)
}

public extension ComfortSpec {
    /// Build 37: with Apple Intelligence cleanup off the style key does nothing, so the action row is the
    /// hide key, a little wider (the style key's 84 pt content floor), and Dictate, which takes the rest. iPhone only
    /// from build 38 (iPad: [KeySlot].withoutStyleKey).
    static let phoneNoStyle: ComfortSpec = {
        var s = phone
        s.action = [Item("hide", weight: 0.02, minMM: 9.2, minPt: 84), Item("mic", weight: 1.0, minMM: 9.2)]
        return s
    }()
    static func keyboard(styleKey: Bool) -> ComfortSpec { styleKey ? phone : phoneNoStyle }
}

public extension KeyHand {
    /// Which side the Dictate key sits on in Comfort (Left mirrors the top row for left thumbs).
    static var current: KeyHand {
        get { KeyHand(rawValue: FF.defaults.string(forKey: "keyHand") ?? "") ?? .right }
        set { FF.defaults.set(newValue.rawValue, forKey: "keyHand") }
    }
}

public extension KeyLayoutKind {
    /// The default for new installs: Classic (2026-10-30: the default stays the layout people already have; this
    /// replaces the earlier L4 default). L4 stays a choice; a saved choice stays.
    static let standard: KeyLayoutKind = .classic

    /// The keyboard reads this from the App Group; the default until the person picks one.
    static var current: KeyLayoutKind {
        get { KeyLayoutKind(rawValue: FF.defaults.string(forKey: "keyLayout") ?? "") ?? standard }
        set { FF.defaults.set(newValue.rawValue, forKey: "keyLayout") }
    }

    /// The three small previews in Settings: the default first, then the one in use, then L4 and Current.
    static func rowPreviews(current: KeyLayoutKind) -> [KeyLayoutKind] {
        var out: [KeyLayoutKind] = []
        for k in [standard, current, .deleteAfterL, .comfort, .roomy] where !out.contains(k) && out.count < 3 { out.append(k) }
        return out
    }
}
