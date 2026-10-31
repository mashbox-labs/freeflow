import CoreGraphics
import XCTest
@testable import FreeFlowKit

/// The iPad's floating keyboard (for accessibility): iPadOS gives the keyboard about an iPhone's
/// width (320 pt) when it floats. It must get the iPhone metrics for that width, not iPad key heights and row pitch
/// squeezed into it; docked, the iPad metrics. The panel density stays the iPad's either way.
final class KeyboardFloatingTests: XCTestCase {
    static let floating: Double = 320
    static let docked: [Double] = [744, 820, 1024, 1032, 1366]

    func testFloatingIPadGetsIPhoneMetrics() {
        let pad = KeyboardLayouts.metrics(width: Self.floating, isPad: true)
        XCTAssertEqual(pad, AppleKeyMetrics.forWidth(Self.floating), "iPad keyboard at 320 pt: iPhone metrics")
        XCTAssertNotEqual(pad, AppleKeyMetrics.iPad(width: Self.floating))
        XCTAssertEqual(KeyboardLayouts.height(width: Self.floating, isPad: true), AppleKeyMetrics.forWidth(Self.floating).viewHeight, accuracy: 1e-9)
        print("FLOATING iPad 320 pt: pitch \(pad.pitch) cap \(pad.capHeight) rowPitch \(pad.rowPitch) height \(KeyboardLayouts.height(width: Self.floating, isPad: true)); old rule would give cap \(AppleKeyMetrics.iPad(width: Self.floating).capHeight) rowPitch \(AppleKeyMetrics.iPad(width: Self.floating).rowPitch) height \(AppleKeyMetrics.iPad(width: Self.floating).viewHeight)")
    }

    func testDockedIPadGetsIPadMetrics() {
        for w in Self.docked {
            XCTAssertEqual(KeyboardLayouts.metrics(width: w, isPad: true), AppleKeyMetrics.iPad(width: w), "iPad docked at \(w) pt")
        }
        for w in [375.0, 393, 402, 420, 440] {
            XCTAssertEqual(KeyboardLayouts.metrics(width: w, isPad: false), AppleKeyMetrics.forWidth(w), "iPhone at \(w) pt")
        }
    }

    /// The floating keyboard keeps the iPad's real panel density (the screen does not change when the keyboard floats).
    func testFloatingKeepsIPadDensity() {
        XCTAssertEqual(KeyboardLayouts.pointsPerMM(scale: 2, isPad: true), KeyGeometry.pointsPerMM(ppi: 264, scale: 2), accuracy: 1e-12)
    }

    /// Floating, every layout still tiles: every point belongs to exactly one key (letters and the 123 page), and every
    /// key is drawn inside the keyboard with room for its label.
    func testFloatingLayoutsTile() {
        let w = Self.floating, h = KeyboardLayouts.height(width: w, isPad: true)
        for kind in KeyLayoutKind.allCases {
            for symbols in [false, true] {
                for globe in [false, true] {
                    let ks = KeyboardLayouts.keys(kind, width: w, height: h, isPad: true, scale: 2, globe: globe, symbols: symbols)
                    var y = 0.37
                    while y < h {
                        var x = 0.41
                        while x < w {
                            let n = ks.filter { $0.contains(CGPoint(x: x, y: y)) }.count
                            if n != 1 { XCTFail("\(kind) floating symbols \(symbols) globe \(globe) point \(x),\(y): \(n) keys"); return }
                            x += 1.5
                        }
                        y += 1.5
                    }
                    for k in ks {
                        XCTAssertTrue(CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: -0.01, dy: -0.01).contains(k.drawn), "\(kind) \(k.id) drawn inside")
                        XCTAssertGreaterThan(k.visible.width, 20, "\(kind) \(k.id) width \(k.visible.width)")
                    }
                }
            }
        }
    }
}
