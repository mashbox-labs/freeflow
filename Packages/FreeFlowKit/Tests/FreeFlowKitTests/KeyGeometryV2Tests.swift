import CoreGraphics
import XCTest
@testable import FreeFlowKit

/// Comfort v2 against Apple's own keyboard, measured from its drawn keys in the iOS 26.5 simulator
/// (2026-10-29). Screen points. Our keyboard view ends 75 pt above the screen bottom (measured on the iPhone Air,
/// 557...837 on a 912 pt screen; the same on the other sizes is an assumption until a device or sim shows it).
final class KeyGeometryV2Tests: XCTestCase {
    typealias Row = (y: Double, xs: [Double])
    static let apple: [(name: String, w: Double, h: Double, rows: [Row])] = [
        ("iPhone 17", 402, 874, [(612.5, [23.33, 62.83, 102.33, 141.83, 181.33, 220.83, 260.33, 299.83, 339.33, 378.83]), (666.5, [43.0, 82.5, 122.0, 161.5, 201.0, 240.5, 280.0, 319.5, 359.0]), (720.5, [82.5, 122.0, 161.5, 201.0, 240.5, 280.0, 319.5])]),
        ("iPhone Air", 420, 912, [(641.5, [24.17, 65.33, 106.67, 148.0, 189.33, 230.67, 272.0, 313.33, 354.67, 396.0]), (697.5, [44.67, 86.0, 127.33, 168.67, 210.0, 251.33, 292.67, 334.0, 375.33]), (753.5, [86.0, 127.33, 168.67, 210.0, 251.33, 292.67, 334.0])]),
        ("iPhone 17 Pro Max", 440, 956, [(685.5, [25.17, 68.33, 111.67, 155.0, 198.33, 241.67, 285.0, 328.33, 371.67, 415.0]), (741.5, [46.67, 90.0, 133.33, 176.67, 220.0, 263.33, 306.67, 350.0, 393.33]), (797.5, [90.0, 133.33, 176.67, 220.0, 263.33, 306.67, 350.0])]),    ]
    static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    static let ppm = 460 / 25.4 / 3

    private func keys(_ w: Double, symbols: Bool = false) -> (keys: [KeySlot], h: Double) {
        let a = AppleKeyMetrics.forWidth(w)
        return (KeyGeometry.comfortV2(width: w, height: a.viewHeight, pointsPerMM: Self.ppm, apple: a, symbols: symbols), a.viewHeight)
    }

    /// Spacing matches Apple's: every letter's centre within 1 pt of Apple's, on each size.
    func testLetterCentresWithinOnePointOfApple() {
        var worst = 0.0
        for s in Self.apple {
            let (ks, h) = keys(s.w)
            let top = s.h - 75 - h
            for (r, row) in Self.rows.enumerated() {
                for (i, c) in row.enumerated() {
                    guard let k = ks.first(where: { $0.id == String(c) }) else { XCTFail("\(s.name) no key \(c)"); continue }
                    worst = max(worst, abs(k.visible.midX - s.rows[r].xs[i]), abs(top + k.visible.midY - s.rows[r].y))
                    XCTAssertEqual(k.visible.midX, s.rows[r].xs[i], accuracy: 1, "\(s.name) \(c) x")
                    XCTAssertEqual(top + k.visible.midY, s.rows[r].y, accuracy: 1, "\(s.name) \(c) y")
                }
            }
        }
        print("KEYCENTRES worst \(worst) pt")
    }

    /// Every point of the keyboard belongs to exactly one key: no dead gaps, no overlaps (letters and the 123 page).
    func testEveryPointHasExactlyOneKey() {
        for w in [402.0, 420, 440, 393, 375] {
            for symbols in [false, true] {
                let (ks, h) = keys(w, symbols: symbols)
                var y = 0.37
                while y < h {
                    var x = 0.41
                    while x < w {
                        let n = ks.filter { $0.contains(CGPoint(x: x, y: y)) }.count
                        if n != 1 { XCTFail("w \(w) symbols \(symbols) point \(x),\(y): \(n) keys"); return }
                        x += 1.5
                    }
                    y += 1.5
                }
            }
        }
    }

    /// Return is a reverse L that owns the bottom-right corner. Taps anywhere in either arm send
    /// return, there is no gap between the arms, and the keys next to it keep their own areas.
    func testReturnIsOneReverseLInTheCorner() throws {
        for w in [402.0, 420, 440] {
            let (ks, h) = keys(w)
            func at(_ x: Double, _ y: Double) -> String? { KeyGeometry.key(at: CGPoint(x: x, y: y), in: ks)?.id }
            let r = try XCTUnwrap(ks.first { $0.id == "return" })
            let arm = r.visible, foot = try XCTUnwrap(r.visible2)
            XCTAssertGreaterThan(arm.minX, foot.minX, "the arm stands at the right end of the foot")
            XCTAssertLessThan(arm.minY, foot.minY - 20, "the arm rises into the row above")
            XCTAssertEqual(arm.maxX, foot.maxX, accuracy: 0.01)
            XCTAssertEqual(arm.maxY, foot.maxY, accuracy: 0.01, "one shape: the arm runs down into the foot")
            for rect in [arm, foot] {
                var y = rect.minY + 1
                while y < rect.maxY {
                    var x = rect.minX + 1
                    while x < rect.maxX { XCTAssertEqual(at(x, y), "return", "\(w) \(x),\(y)"); x += 2 }
                    y += 2
                }
            }
            var x = arm.minX + 0.5
            while x < arm.maxX {
                for y in stride(from: arm.minY, through: foot.maxY, by: 0.5) { XCTAssertEqual(at(x, y), "return", "junction \(w) \(x),\(y)") }
                x += 3
            }
            XCTAssertEqual(at(w - 0.5, h - 0.5), "return")
            XCTAssertEqual(at(w - 0.5, arm.minY), "return")
            XCTAssertGreaterThan(foot.minX, 6.5 * w / 10 + 20, "reaches less far left than build 5")
            for id in ["m", "n", "delete", "space", "l", "p", "k"] {
                let k = try XCTUnwrap(ks.first { $0.id == id })
                XCTAssertEqual(at(k.visible.midX, k.visible.midY), id, "\(w) \(id)")
                XCTAssertEqual(at(k.visible.maxX - 1, k.visible.maxY - 1), id, "\(w) \(id) corner")
            }
            let m = try XCTUnwrap(ks.first { $0.id == "m" }), del = try XCTUnwrap(ks.first { $0.id == "delete" })
            XCTAssertEqual(at(m.visible.maxX + 2, m.visible.midY), "m", "the gap after m is m's")
            XCTAssertEqual(at(del.visible.maxX + 2, del.visible.midY), "delete", "the gap after delete is delete's")
            XCTAssertLessThan(del.visible.maxX, foot.minX)
            XCTAssertEqual(del.visible.minY, foot.minY, accuracy: 0.01, "delete sits on the bottom row next to the foot")
        }
    }
}
