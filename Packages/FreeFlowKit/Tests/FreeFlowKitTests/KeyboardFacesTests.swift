import CoreGraphics
import XCTest
@testable import FreeFlowKit

/// Style labels fit on one line, readable (2026-10-30: the Classic "Formal." pill wrapped to "Forma" / "l." on build
/// 8). Text is measured in the keyboard's own font (Outfit, wght 700, 16 pt, fixed: the keyboard keeps its keys at the
/// large text size) with CoreText, against the room the keyboard gives it. Scale = the minimumScaleFactor SwiftUI
/// needs to fit the line (1 = full size). Readable: 0.8 or more, everywhere.
final class KeyboardFacesTests: XCTestCase {
    /// iPhone SE 3, 393, 402 and 440 pt iPhones; iPad mini, iPad Pro 13, and the iPad's floating keyboard (320 pt).
    static let devices: [(width: Double, isPad: Bool, scale: Double, name: String)] = [
        (375, false, 2, "iPhone SE 3"), (393, false, 3, "393"), (402, false, 3, "402"), (440, false, 3, "440"),
        (744, true, 2, "iPad mini"), (1032, true, 2, "iPad Pro 13"), (320, true, 2, "iPad floating"),
    ]
    static let readable = 0.8

    /// The style key in the action row: every pill, every layout, both hands, globe or not, every width.
    func testStyleKeyPillsFit() {
        var worst: [String: (scale: Double, at: String)] = [:]
        var table: [String] = []
        for d in Self.devices {
            let h = KeyboardLayouts.height(width: d.width, isPad: d.isPad)
            var rowMin: [String: Double] = [:]
            for kind in KeyLayoutKind.allCases {
                for hand in KeyHand.allCases {
                    for globe in [false, true] {
                        let keys = KeyboardLayouts.keys(kind, width: d.width, height: h, isPad: d.isPad, scale: d.scale, globe: globe, hand: hand)
                        guard let style = keys.first(where: { $0.id == "style" }) else { XCTFail("\(kind) \(d.name): no style key"); continue }
                        for pill in DictationStyle.allCases.map(\.pill) {
                            let s = StyleKeyText.scale(pill, keyWidth: style.visible.width)
                            let at = "\(d.name) \(kind.rawValue) \(hand.rawValue) globe=\(globe) key \(String(format: "%.1f", style.visible.width)) pt"
                            XCTAssertGreaterThanOrEqual(s, Self.readable, "\(pill) at \(at): scale \(s)")
                            if s < worst[pill]?.scale ?? 2 { worst[pill] = (s, at) }
                            rowMin[pill] = min(rowMin[pill] ?? 2, s)
                        }
                    }
                }
            }
            table.append("PILLFIT style-key \(d.name) " + DictationStyle.allCases.map { "\($0.pill)=\(String(format: "%.3f", rowMin[$0.pill]!))" }.joined(separator: " "))
        }
        for line in table { print(line) }
        for pill in DictationStyle.allCases.map(\.pill) {
            let w = worst[pill]!
            print("PILLFIT style-key worst \(pill) width \(String(format: "%.2f", KeyText.width(pill, size: StyleKeyText.size, weight: StyleKeyText.weight))) pt scale \(String(format: "%.3f", w.scale)) at \(w.at)")
        }
    }

    /// The top bar of the opening, didn't-open and message states: every pill with the widest cleanup chip (each
    /// title tried), every width.
    func testTopBarPillsFit() {
        for d in Self.devices {
            var line: [String] = []
            for pill in DictationStyle.allCases.map(\.pill) {
                var m = 2.0
                for cleanup in ["none"] {  // build 12: no cleanup chip
                    let s = KeyboardTopBar.styleScale(pill, width: d.width, cleanup: cleanup)
                    XCTAssertGreaterThanOrEqual(s, Self.readable, "top bar \(pill) with \(cleanup) at \(d.name) (\(d.width) pt): scale \(s)")
                    m = min(m, s)
                }
                line.append("\(pill)=\(String(format: "%.3f", m))")
            }
            let chip = KeyboardTopBar.showsCleanup(width: d.width)
            print("PILLFIT top-bar \(d.name) cleanup chip \(chip ? "shown" : "left out") room \(String(format: "%.1f", KeyboardTopBar.styleTextRoom(width: d.width, cleanup: chip ? "Verbatim" : nil))) pt " + line.joined(separator: " "))
        }
    }

    /// The font is the keyboard's: Outfit's wght axis at 700, the size as given (no Dynamic Type scaling).
    func testKeyFontIsOutfitBoldFixed() {
        let f = FFFont.fixedCT(16, .bold)
        XCTAssertEqual(CTFontGetSize(f), 16, accuracy: 0.001)
        XCTAssertTrue((CTFontCopyFamilyName(f) as String).hasPrefix("Outfit"), CTFontCopyFamilyName(f) as String)
        let axes = CTFontCopyVariation(f) as? [NSNumber: NSNumber]
        XCTAssertEqual(axes?[NSNumber(value: 0x7767_6874)]?.doubleValue ?? 0, 700, accuracy: 0.5, "wght axis")
        XCTAssertGreaterThan(KeyText.width("Formal.", size: 16, weight: .bold), KeyText.width("Formal.", size: 16, weight: .regular), "bold is wider")
    }
}
