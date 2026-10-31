import CoreGraphics
import XCTest
@testable import FreeFlowKit

/// Parity with the Python reference (tools/keys/geometry.py, sim.py) and layout invariants.
/// Generated from tools/keys/fixture-v2.json (eval_v2.py): iPhone Air, 420 x 280 pt, 460 ppi at 3x.
final class KeyGeometryTests: XCTestCase {
    static let W = 420.0, H = 280.0, ppm = KeyGeometry.pointsPerMM(ppi: 460, scale: 3)
    static let expected: [(String, Double, Double, Double, Double, Double, Double, Double, Double)] = [
        ("hide", 0.0000, 0.0000, 55.5381, 60.0000, 3.0000, 3.0000, 49.5381, 54.0000),
        ("style", 55.5381, 0.0000, 84.0000, 60.0000, 58.5381, 3.0000, 78.0000, 54.0000),
        ("mic", 139.5381, 0.0000, 280.4619, 60.0000, 142.5381, 3.0000, 274.4619, 54.0000),
        ("q", 0.0000, 60.0000, 42.0000, 48.0000, 3.0000, 63.0000, 36.0000, 42.0000),
        ("w", 42.0000, 60.0000, 42.0000, 48.0000, 45.0000, 63.0000, 36.0000, 42.0000),
        ("e", 84.0000, 60.0000, 42.0000, 48.0000, 87.0000, 63.0000, 36.0000, 42.0000),
        ("r", 126.0000, 60.0000, 42.0000, 48.0000, 129.0000, 63.0000, 36.0000, 42.0000),
        ("t", 168.0000, 60.0000, 42.0000, 48.0000, 171.0000, 63.0000, 36.0000, 42.0000),
        ("y", 210.0000, 60.0000, 42.0000, 48.0000, 213.0000, 63.0000, 36.0000, 42.0000),
        ("u", 252.0000, 60.0000, 42.0000, 48.0000, 255.0000, 63.0000, 36.0000, 42.0000),
        ("i", 294.0000, 60.0000, 42.0000, 48.0000, 297.0000, 63.0000, 36.0000, 42.0000),
        ("o", 336.0000, 60.0000, 42.0000, 48.0000, 339.0000, 63.0000, 36.0000, 42.0000),
        ("p", 378.0000, 60.0000, 42.0000, 48.0000, 381.0000, 63.0000, 36.0000, 42.0000),
        ("a", 0.0000, 108.0000, 63.0000, 48.0000, 24.0000, 111.0000, 36.0000, 42.0000),
        ("s", 63.0000, 108.0000, 42.0000, 48.0000, 66.0000, 111.0000, 36.0000, 42.0000),
        ("d", 105.0000, 108.0000, 42.0000, 48.0000, 108.0000, 111.0000, 36.0000, 42.0000),
        ("f", 147.0000, 108.0000, 42.0000, 48.0000, 150.0000, 111.0000, 36.0000, 42.0000),
        ("g", 189.0000, 108.0000, 42.0000, 48.0000, 192.0000, 111.0000, 36.0000, 42.0000),
        ("h", 231.0000, 108.0000, 42.0000, 48.0000, 234.0000, 111.0000, 36.0000, 42.0000),
        ("j", 273.0000, 108.0000, 42.0000, 48.0000, 276.0000, 111.0000, 36.0000, 42.0000),
        ("k", 315.0000, 108.0000, 42.0000, 48.0000, 318.0000, 111.0000, 36.0000, 42.0000),
        ("l", 357.0000, 108.0000, 63.0000, 48.0000, 360.0000, 111.0000, 36.0000, 42.0000),
        ("shift", 0.0000, 156.0000, 63.0000, 56.0000, 3.0000, 159.0000, 57.0000, 42.0000),
        ("z", 63.0000, 156.0000, 42.0000, 56.0000, 66.0000, 159.0000, 36.0000, 42.0000),
        ("x", 105.0000, 156.0000, 42.0000, 56.0000, 108.0000, 159.0000, 36.0000, 42.0000),
        ("c", 147.0000, 156.0000, 42.0000, 56.0000, 150.0000, 159.0000, 36.0000, 42.0000),
        ("v", 189.0000, 156.0000, 42.0000, 56.0000, 192.0000, 159.0000, 36.0000, 42.0000),
        ("b", 231.0000, 156.0000, 42.0000, 56.0000, 234.0000, 159.0000, 36.0000, 42.0000),
        ("n", 273.0000, 156.0000, 42.0000, 56.0000, 276.0000, 159.0000, 36.0000, 42.0000),
        ("m", 315.0000, 156.0000, 42.0000, 56.0000, 318.0000, 159.0000, 36.0000, 42.0000),
        ("delete", 357.0000, 156.0000, 63.0000, 56.0000, 360.0000, 159.0000, 57.0000, 42.0000),
        ("abc123", 0.0000, 212.0000, 59.1443, 68.0000, 3.0000, 212.0000, 53.1443, 65.0000),
        ("space", 59.1443, 212.0000, 210.0000, 68.0000, 62.1443, 212.0000, 204.0000, 65.0000),
        ("return", 269.1443, 212.0000, 150.8557, 68.0000, 272.1443, 212.0000, 81.8557, 65.0000)
    ]
    // (x, y, two-char context, plain hit key, key after the letter model)
    static let decodeCases: [(Double, Double, String, String, String)] = [
        (16.630, 101.387, "o ", "q", "q"),
        (35.878, 101.729, "  ", "q", "q"),
        (173.186, 88.578, " t", "t", "r"),
        (140.386, 187.737, "qu", "x", "x"),
        (151.060, 130.407, "an", "f", "d"),
        (264.327, 115.570, " t", "h", "h"),
        (129.167, 80.178, "  ", "r", "r"),
        (154.338, 176.033, "o ", "c", "c"),
        (398.144, 136.279, "wh", "l", "l"),
        (311.631, 99.060, "  ", "i", "i"),
        (127.030, 88.820, "in", "r", "e"),
        (96.363, 140.582, "wh", "s", "s")
    ]
    /// return's moat corner and short part (Python reference)
    static let returnNotch = (357.0000, 212.0000, 63.0000, 12.0000)
    static let returnShort = (360.0000, 227.0000, 57.0000, 50.0000)
    // (x, y, key or nil): points around the moat under backspace
    static let moatCases: [(Double, Double, String?)] = [
        (380.0, 215.0, nil),
        (400.0, 222.5, nil),
        (358.0, 209.5, "delete"),
        (356.0, 215.0, "return"),
        (380.0, 205.0, "delete"),
        (380.0, 224.5, "return"),
        (300.0, 210.0, "n")
    ]

    func testMatchesPythonReference() {
        let keys = KeyGeometry.comfort(width: Self.W, height: Self.H, pointsPerMM: Self.ppm)
        XCTAssertEqual(keys.map(\.id), Self.expected.map(\.0))
        for (k, e) in zip(keys, Self.expected) {
            for (a, b) in zip([k.hit.minX, k.hit.minY, k.hit.width, k.hit.height, k.visible.minX, k.visible.minY, k.visible.width, k.visible.height],
                              [e.1, e.2, e.3, e.4, e.5, e.6, e.7, e.8]) {
                XCTAssertEqual(Double(a), b, accuracy: 0.01, k.id)
            }
        }
        let r = keys.first { $0.id == "return" }!
        let n = Self.returnNotch, sh = Self.returnShort
        XCTAssertEqual(r.notch, CGRect(x: n.0, y: n.1, width: n.2, height: n.3))
        XCTAssertEqual(Double(r.visible2!.minY), sh.1, accuracy: 0.01); XCTAssertEqual(Double(r.visible2!.height), sh.3, accuracy: 0.01)
        XCTAssertEqual(Double(r.visible2!.minX), sh.0, accuracy: 0.01); XCTAssertEqual(Double(r.visible2!.width), sh.2, accuracy: 0.01)
        for (x, y, id) in Self.moatCases {
            XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: x, y: y), in: keys)?.id, id, "at \(x),\(y)")
        }
    }

    func testTilesCoverKeyboardWithoutOverlapOrGaps() {
        for (w, h, ppm) in [(420.0, 280.0, Self.ppm), (440.0, 280.0, Self.ppm), (375.0, 280.0, Self.ppm), (820.0, 280.0, KeyGeometry.pointsPerMM(ppi: 264, scale: 2)), (1180.0, 280.0, KeyGeometry.pointsPerMM(ppi: 264, scale: 2))] {
            let keys = KeyGeometry.comfort(width: w, height: h, pointsPerMM: ppm)
            let moat = keys.compactMap(\.notch).reduce(0.0) { $0 + Double($1.width * $1.height) }
            let area = keys.reduce(0.0) { $0 + Double($1.hit.width * $1.hit.height) }
            XCTAssertEqual(area, w * h, accuracy: 0.5, "tiles must cover the keyboard exactly at \(w)")
            let del = keys.first { $0.id == "delete" }!, notch = keys.compactMap(\.notch)
            XCTAssertEqual(notch.count, 1, "one moat at \(w)")
            if let n = notch.first {
                XCTAssertEqual(Double(n.minX), Double(del.hit.minX), accuracy: 0.01); XCTAssertEqual(Double(n.width), Double(del.hit.width), accuracy: 0.01)
                XCTAssertEqual(Double(n.minY), Double(del.hit.maxY), accuracy: 0.01, "moat right under backspace")
                XCTAssertEqual(Double(n.height), 12, accuracy: 0.01); XCTAssertEqual(moat, Double(n.width * n.height), accuracy: 0.01)
            }
            for i in keys.indices {
                XCTAssertTrue(keys[i].hit.insetBy(dx: -0.01, dy: -0.01).contains(keys[i].visible), "\(keys[i].id) drawn outside its tile")
                if let v2 = keys[i].visible2 { XCTAssertTrue(keys[i].hit.insetBy(dx: -0.01, dy: -0.01).contains(v2), "return's short part outside its tile") }
                if let n = keys[i].notch {
                    XCTAssertTrue(n.intersection(keys[i].visible).isNull || n.intersection(keys[i].visible).height < 0.01, "moat over the drawn return")
                    XCTAssertTrue(keys[i].visible2.map { n.intersection($0).isNull || n.intersection($0).height < 0.01 } ?? true, "moat over return's short part")
                }
                for j in keys.indices where j > i {
                    let o = keys[i].hit.intersection(keys[j].hit)
                    XCTAssertTrue(o.isNull || o.width * o.height < 0.01, "\(keys[i].id) overlaps \(keys[j].id)")
                }
            }
            var hits = 0, total = 0
            for x in stride(from: 0.5, to: w, by: 3.0) {
                for y in stride(from: 0.5, to: h, by: 3.0) {
                    let p = CGPoint(x: x, y: y)
                    if keys.contains(where: { $0.notch?.contains(p) ?? false }) { continue }
                    total += 1
                    if KeyGeometry.key(at: p, in: keys) != nil { hits += 1 }
                }
            }
            XCTAssertEqual(hits, total, "dead zone outside the moat at width \(w)")
        }
    }

    func testDictationFirstSizes() {
        let keys = Dictionary(uniqueKeysWithValues: KeyGeometry.comfort(width: Self.W, height: Self.H, pointsPerMM: Self.ppm).map { ($0.id, $0) })
        let mic = keys["mic"]!.visible, q = keys["q"]!.visible
        let r = keys["return"]!, retArea = r.visible.width * r.visible.height + (r.visible2.map { $0.width * $0.height } ?? 0)
        XCTAssertGreaterThan(mic.width * mic.height, retArea)
        XCTAssertGreaterThan(retArea, q.width * q.height * 4)
        XCTAssertGreaterThanOrEqual(Double(keys["return"]!.hit.width), 103.33, "return at least as wide as the iOS 26 keyboard's on the same phone")
        XCTAssertGreaterThanOrEqual(Double(keys["space"]!.hit.width), 5 * Self.W / 10 - 0.01)
        XCTAssertGreaterThanOrEqual(Double(keys["abc123"]!.hit.width), 9.2 * Self.ppm - 0.01)
    }

    /// Return clear of backspace (Apple leaves 11 pt; Classic 9), backspace the same size as before,
    /// return no smaller than the iOS keyboard's, the letters-to-bottom-row gap Apple's 11 pt.
    func testReturnClearOfBackspace() {
        let keys = Dictionary(uniqueKeysWithValues: KeyGeometry.comfort(width: Self.W, height: Self.H, pointsPerMM: Self.ppm).map { ($0.id, $0) })
        let del = keys["delete"]!, ret = keys["return"]!, m = keys["m"]!
        XCTAssertEqual(Double(del.visible.width), 57, accuracy: 0.01, "backspace keeps its size")
        XCTAssertEqual(Double(del.visible.height), Double(m.visible.height), accuracy: 0.01, "backspace as tall as the letters")
        XCTAssertGreaterThanOrEqual(Double(ret.visible2!.minY - del.visible.maxY), 2 * 11, "return at least twice Apple's 11 pt below backspace")
        XCTAssertEqual(Double(ret.visible.minY - m.visible.maxY), 11, accuracy: 0.01, "Apple's row gap above the bottom row")
        XCTAssertGreaterThanOrEqual(Double(ret.drawn.width), 103.33, "return at least as wide as the iOS 26 keyboard's")
        XCTAssertGreaterThan(Double(ret.drawn.height), 45, "return taller than the iOS 26 keyboard's 45 pt")
        // a tap 2 sd (FFitts 1.648 mm) above the centre of return's short part still is not backspace
        let sd = CGFloat(1.648 * Self.ppm), s = ret.visible2!
        XCTAssertNotEqual(KeyGeometry.key(at: CGPoint(x: s.midX, y: s.midY - 2 * sd), in: Array(keys.values))?.id, "delete")
        XCTAssertNotEqual(KeyGeometry.key(at: CGPoint(x: del.visible.midX, y: del.visible.midY + 3 * sd), in: Array(keys.values))?.id, "return")
    }

    /// Left-handed: the action row mirrors (Dictate on the left, hide on the right); the letters do not move.
    func testLeftHandMirrorsActionRow() {
        let r = KeyGeometry.comfort(width: Self.W, height: Self.H, pointsPerMM: Self.ppm)
        let l = KeyGeometry.comfort(width: Self.W, height: Self.H, pointsPerMM: Self.ppm, hand: .left)
        let rk: [String: KeySlot] = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0) })
        let lk: [String: KeySlot] = Dictionary(uniqueKeysWithValues: l.map { ($0.id, $0) })
        for id in ["mic", "style", "hide"] {
            XCTAssertEqual(Double(lk[id]!.hit.minX), Self.W - Double(rk[id]!.hit.maxX), accuracy: 0.01, id)
            XCTAssertEqual(Double(lk[id]!.hit.width), Double(rk[id]!.hit.width), accuracy: 0.01, id)
        }
        XCTAssertGreaterThan(Double(rk["mic"]!.hit.midX), Self.W / 2); XCTAssertLessThan(Double(lk["mic"]!.hit.midX), Self.W / 2)
        for k in r where k.kind != .action { XCTAssertEqual(lk[k.id], k, k.id) }
        XCTAssertGreaterThanOrEqual(Double(rk["hide"]!.hit.width), 9.2 * Self.ppm - 0.01, "hide key at the one-thumb floor")
    }
}
