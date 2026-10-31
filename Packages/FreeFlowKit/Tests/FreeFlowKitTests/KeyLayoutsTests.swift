import CoreGraphics
import XCTest
@testable import FreeFlowKit

/// The layouts in Settings > Keyboard > Layout (2026-10-29): Current (Comfort v2) unchanged
/// and the default, Classic = Apple's keyboard, L1-L4 the experiments. Screen points.
final class KeyLayoutsTests: XCTestCase {
    static let phoneWidths: [Double] = [375, 393, 402, 420, 440]
    static let padWidths: [Double] = [744, 820, 1024]
    static let ppm = 460 / 25.4 / 3

    private func keys(_ kind: KeyLayoutKind, _ w: Double, pad: Bool = false, symbols: Bool = false, globe: Bool = false) -> (keys: [KeySlot], h: Double) {
        let h = KeyboardLayouts.height(width: w, isPad: pad)
        return (KeyboardLayouts.keys(kind, width: w, height: h, isPad: pad, scale: pad ? 2 : 3, globe: globe, symbols: symbols), h)
    }

    private func key(_ ks: [KeySlot], _ id: String) -> KeySlot { ks.first { $0.id == id }! }

    private func same(_ a: CGRect?, _ b: CGRect?, _ what: String) {
        guard let a, let b else { XCTAssertTrue(a == nil && b == nil, "\(what): \(String(describing: a)) vs \(String(describing: b))"); return }
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 1e-9, what)
        }
    }

    /// The current layout stays exactly as it is. Current == build 6-8's comfortV2, key for key.
    func testComfortIsV2() {
        for w in Self.phoneWidths {
            for symbols in [false, true] {
                for globe in [false, true] {
                    let a = AppleKeyMetrics.forWidth(w)
                    let v2 = KeyGeometry.comfortV2(width: w, height: a.viewHeight, pointsPerMM: Self.ppm, apple: a, globe: globe, symbols: symbols)
                    let now = KeyGeometry.layout(.comfort, width: w, height: a.viewHeight, pointsPerMM: Self.ppm, apple: a, globe: globe, symbols: symbols)
                    XCTAssertEqual(now.map(\.id), v2.map(\.id), "\(w) ids")
                    for (n, o) in zip(now, v2) {
                        let t = "\(w) symbols \(symbols) globe \(globe) \(n.id)"
                        same(n.hit, o.hit, t + " hit"); same(n.visible, o.visible, t + " visible")
                        same(n.notch, o.notch, t + " notch"); same(n.visible2, o.visible2, t + " visible2")
                        XCTAssertEqual(n.kind, o.kind, t)
                    }
                }
            }
        }
        XCTAssertEqual(KeyLayoutKind(rawValue: "comfort"), .comfort, "the stored value of the default never changes")
        XCTAssertEqual(KeyLayoutKind(rawValue: "classic"), .classic)
    }

    /// Every point of the keyboard belongs to exactly one key in every layout, letters and the 123 page, iPhone and iPad.
    func testEveryPointHasExactlyOneKey() {
        for kind in KeyLayoutKind.allCases {
            for (w, pad) in Self.phoneWidths.map({ ($0, false) }) + Self.padWidths.map({ ($0, true) }) {
                for symbols in [false, true] {
                    let (ks, h) = keys(kind, w, pad: pad, symbols: symbols)
                    var y = 0.37
                    while y < h {
                        var x = 0.41
                        while x < w {
                            let n = ks.filter { $0.contains(CGPoint(x: x, y: y)) }.count
                            if n != 1 { XCTFail("\(kind) w \(w) symbols \(symbols) point \(x),\(y): \(n) keys"); return }
                            x += 1.5
                        }
                        y += 1.5
                    }
                }
            }
        }
    }

    /// Every key's tap area at least Apple's 44 pt guidance tall; delete and return at least 44 wide too.
    func testHitAreasAtLeast44() {
        for kind in KeyLayoutKind.allCases {
            for (w, pad) in Self.phoneWidths.map({ ($0, false) }) + Self.padWidths.map({ ($0, true) }) {
                for symbols in [false, true] {
                    let (ks, _) = keys(kind, w, pad: pad, symbols: symbols)
                    for k in ks {
                        XCTAssertGreaterThanOrEqual(k.hit.height, 44, "\(kind) \(w) \(k.id) hit height")
                        if ["delete", "return", "space", "mic"].contains(k.id) {
                            // L4's delete takes one letter column (402 pt: 42.9); the a row's tap boundaries move up to
                            // 2.5 pt left so it reaches 44 from 393 pt up; 375 pt reaches 42.49 (target >= 44 pt)
                            let floor = Self.l4DeleteFloor(kind: kind, id: k.id, width: w)
                            XCTAssertGreaterThanOrEqual(k.hit.width, floor, "\(kind) \(w) \(k.id) hit width")
                        }
                    }
                }
            }
        }
    }

    /// No smaller letters: every letter is drawn exactly as in Current, in every layout (L4's a row moves half a key
    /// left at the same size), and its tap area is at least a full key pitch wide and as tall as in Current.
    func testLettersKeepTheirSize() {
        for (w, pad) in Self.phoneWidths.map({ ($0, false) }) + Self.padWidths.map({ ($0, true) }) {
            let (base, _) = keys(.comfort, w, pad: pad)
            let P = KeyboardLayouts.metrics(width: w, isPad: pad).pitch
            for kind in KeyLayoutKind.allCases {
                let (ks, _) = keys(kind, w, pad: pad)
                for c in "qwertyuiopasdfghjklzxcvbnm" {
                    let k = key(ks, String(c)), b = key(base, String(c))
                    let dx = kind == .deleteAfterL && "asdfghjkl".contains(c) ? -P / 2 : 0
                    same(k.visible, b.visible.offsetBy(dx: dx, dy: 0), "\(kind) \(w) \(c) drawn")
                    XCTAssertGreaterThanOrEqual(k.hit.width, P - 1e-9, "\(kind) \(w) \(c) hit width")
                    XCTAssertGreaterThanOrEqual(k.hit.height, b.hit.height - 1e-9, "\(kind) \(w) \(c) hit height")
                }
            }
        }
    }

    /// Delete stays beside return but with more room around it (L1, L2, L3). The room is the neighbours':
    /// a tap 5 pt off delete's left edge types space, 5 pt off its right edge sends return.
    func testRoomAroundDelete() {
        for w in Self.phoneWidths + Self.padWidths {
            let pad = w > 700
            let a = KeyboardLayouts.metrics(width: w, isPad: pad)
            for kind in [KeyLayoutKind.roomy, .bigReturn, .tallReturn] {
                let (ks, _) = keys(kind, w, pad: pad)
                let del = key(ks, "delete"), sp = key(ks, "space"), ret = key(ks, "return")
                let retBottom = ret.visible2 ?? ret.visible
                XCTAssertEqual(del.visible.width, a.deleteWidth, accuracy: 1e-9, "\(kind) \(w) delete keeps Apple's size")
                XCTAssertEqual(del.visible.minY, sp.visible.minY, accuracy: 1e-9, "\(kind) \(w) delete on the bottom row")
                XCTAssertGreaterThanOrEqual(del.visible.minX - sp.visible.maxX, 14 - 1e-9, "\(kind) \(w) room left of delete")
                XCTAssertGreaterThanOrEqual(retBottom.minX - del.visible.maxX, 14 - 1e-9, "\(kind) \(w) room right of delete")
                let y = del.visible.midY
                XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: del.visible.minX - 5, y: y), in: ks)?.id, "space", "\(kind) \(w)")
                XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: del.visible.maxX + 5, y: y), in: ks)?.id, "return", "\(kind) \(w)")
                XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: del.visible.minX + 1, y: y), in: ks)?.id, "delete", "\(kind) \(w)")
                XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: del.visible.maxX - 1, y: y), in: ks)?.id, "delete", "\(kind) \(w)")
            }
        }
    }

    private func area(_ k: KeySlot) -> Double {
        Double(k.visible.width * k.visible.height + (k.visible2.map { $0.width * $0.height } ?? 0))
    }

    /// Return slightly bigger or smaller: L2's return is bigger than Current's, L3's smaller and one
    /// tall key; L4 keeps Current's return.
    func testReturnSizes() {
        for w in Self.phoneWidths {
            let (base, _) = keys(.comfort, w)
            let r0 = key(base, "return")
            let big = key(keys(.bigReturn, w).keys, "return"), tall = key(keys(.tallReturn, w).keys, "return")
            XCTAssertGreaterThan(area(big), area(r0), "\(w) L2 bigger")
            XCTAssertGreaterThan(big.visible2!.width, r0.visible2!.width + 20, "\(w) L2 foot wider")
            XCTAssertLessThan(area(tall), area(r0), "\(w) L3 smaller")
            XCTAssertNil(tall.visible2, "\(w) L3 one tall key")
            XCTAssertGreaterThan(tall.visible.height, 2 * KeyboardLayouts.metrics(width: w, isPad: false).capHeight, "\(w) L3 two rows tall")
            let l4 = key(keys(.deleteAfterL, w).keys, "return")
            same(l4.visible, r0.visible, "\(w) L4 arm"); same(l4.visible2, r0.visible2, "\(w) L4 foot")
        }
    }

    /// L4's delete tap area: Apple's 44 pt from 393 pt wide up (iPhone 17 / 17 Pro were 42.9); 375 pt gets 42.49, because
    /// more would put the l / delete tap boundary on the drawn l.
    static func l4DeleteFloor(kind: KeyLayoutKind, id: String, width w: Double) -> Double {
        kind == .deleteAfterL && id == "delete" && w < 393 ? 42.48 : 44
    }

    /// L4's a row tap boundaries (a..l, then delete; symbols too) tile the row and each one stays inside the gap between
    /// the drawn keys, at least 0.5 pt from both.
    func testL4TapBoundariesStayInGaps() {
        for (w, pad) in Self.phoneWidths.map({ ($0, false) }) + Self.padWidths.map({ ($0, true) }) {
            for symbols in [false, true] {
                let (ks, _) = keys(.deleteAfterL, w, pad: pad, symbols: symbols)
                let del = key(ks, "delete")
                let row = ks.filter { abs($0.visible.minY - del.visible.minY) < 1e-9 && ($0.kind == .letter || $0.id == "delete") }
                    .sorted { $0.visible.minX < $1.visible.minX }
                XCTAssertEqual(row.last?.id, "delete", "\(w) delete ends the a row")
                XCTAssertEqual(row.first?.hit.minX ?? -1, 0, accuracy: 1e-9, "\(w) the row starts at the edge")
                XCTAssertEqual(row.last?.hit.maxX ?? -1, w, accuracy: 1e-9, "\(w) the row ends at the edge")
                for (l, r) in zip(row, row.dropFirst()) {
                    XCTAssertEqual(l.hit.maxX, r.hit.minX, accuracy: 1e-9, "\(w) \(l.id)|\(r.id) tiles")
                    XCTAssertGreaterThanOrEqual(l.hit.maxX, l.visible.maxX + 0.5 - 1e-9, "\(w) \(l.id)|\(r.id) off the drawn \(l.id)")
                    XCTAssertLessThanOrEqual(l.hit.maxX, r.visible.minX - 0.5 + 1e-9, "\(w) \(l.id)|\(r.id) off the drawn \(r.id)")
                }
            }
        }
    }

    /// L4: the a..l row moves slightly left and delete sits at its end, right of l; return keeps its L.
    func testDeleteAfterL() {
        for (w, pad) in Self.phoneWidths.map({ ($0, false) }) + Self.padWidths.map({ ($0, true) }) {
            for symbols in [false, true] {
                let (ks, _) = keys(.deleteAfterL, w, pad: pad, symbols: symbols)
                let del = key(ks, "delete"), last = key(ks, symbols ? "@" : "l"), q = key(ks, symbols ? "1" : "q"), p = key(ks, symbols ? "0" : "p")
                XCTAssertEqual(del.visible.minY, last.visible.minY, accuracy: 1e-9, "\(w) delete on the a row")
                XCTAssertGreaterThan(del.visible.minX, last.visible.maxX, "\(w) delete right of l")
                XCTAssertEqual(del.visible.maxX, p.visible.maxX, accuracy: 1e-9, "\(w) delete ends where p ends")
                XCTAssertGreaterThanOrEqual(del.visible.width, q.visible.width - 1e-9, "\(w) delete at least a letter wide")
                XCTAssertGreaterThanOrEqual(del.hit.width, Self.l4DeleteFloor(kind: .deleteAfterL, id: "delete", width: w), "\(w) delete hit width")
                XCTAssertGreaterThanOrEqual(del.hit.height, 44)
                XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: w - 1, y: del.visible.midY), in: ks)?.id, "delete")
                XCTAssertNotNil(key(ks, "return").visible2, "\(w) return keeps its L")
                XCTAssertEqual(ks.filter { $0.id == "delete" }.count, 1)
                if symbols { XCTAssertNotNil(ks.first { $0.id == "\"" }, "\(w) the a row's tenth symbol moves down") }
                else { XCTAssertEqual(key(ks, "a").visible.midX, q.visible.midX, accuracy: 1e-9, "\(w) a under q") }
            }
        }
    }

    /// Classic matches Apple's keyboard (measured, iOS 26.5): letters, shift, delete at
    /// the end of the z row, return on the bottom row at Apple's width and place; only the Free Flow row on top.
    func testClassicIsApple() {
        // Apple, measured: delete width, return width and x, shift width
        let apple: [Double: (del: Double, ret: Double, retX: Double, shift: Double)] = [
            402: (45.67, 93.0, 402 - 6.33 - 93.0, 45.33), 420: (48.0, 97.33, 316.33, 47.67), 440: (50.33, 102.33, 440 - 6.34 - 102.33, 50.0),
        ]
        for (w, m) in apple {
            let (ks, h) = keys(.classic, w)
            let del = key(ks, "delete"), ret = key(ks, "return"), z = key(ks, "z"), sh = key(ks, "shift"), sp = key(ks, "space")
            XCTAssertEqual(del.visible.width, m.del, accuracy: 0.5, "\(w) delete width")
            XCTAssertEqual(del.visible.minY, z.visible.minY, accuracy: 1e-9, "\(w) delete on the z row")
            XCTAssertEqual(ret.visible.width, m.ret, accuracy: 0.5, "\(w) return width")
            XCTAssertEqual(ret.visible.minX, m.retX, accuracy: 0.5, "\(w) return x")
            XCTAssertEqual(ret.visible.minY, sp.visible.minY, accuracy: 1e-9, "\(w) return on the bottom row")
            XCTAssertNil(ret.visible2); XCTAssertNil(ret.notch)
            XCTAssertEqual(sh.visible.width, m.shift, accuracy: 0.5, "\(w) shift width")
            XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: w - 1, y: h - 1), in: ks)?.id, "return")
            XCTAssertEqual(KeyGeometry.key(at: CGPoint(x: w - 1, y: del.visible.midY), in: ks)?.id, "delete")
        }
    }

    /// Per layout on the iPhone Air (420) and the iPad mini (744).
    func testPrintMeasureTable() {
        func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
        for (name, w, pad) in [("air", 420.0, false), ("ipadmini", 744.0, true)] {
            let a = KeyboardLayouts.metrics(width: w, isPad: pad)
            print("KEYTABLE \(name) metrics pitch \(f(a.pitch)) cap \(f(a.pitch - 6))x\(f(a.capHeight)) rowPitch \(f(a.rowPitch)) height \(f(KeyboardLayouts.height(width: w, isPad: pad)))")
            for kind in KeyLayoutKind.allCases {
                let (ks, _) = keys(kind, w, pad: pad)
                let del = key(ks, "delete"), ret = key(ks, "return"), sp = key(ks, "space"), q = key(ks, "q")
                let retDrawn = ret.visible2.map { ret.visible.union($0) } ?? ret.visible
                func gap(_ r: CGRect, _ o: CGRect) -> Double {
                    let dx = max(0, o.minX - r.maxX, r.minX - o.maxX), dy = max(0, o.minY - r.maxY, r.minY - o.maxY)
                    return Double((dx * dx + dy * dy).squareRoot())
                }
                let gapDR = ([ret.visible] + (ret.visible2.map { [$0] } ?? [])).map { gap(del.visible, $0) }.min()!
                let minHit = ks.map(\.hit.height).min()!
                // every key, for the overlays: hit and drawn rects in keyboard points
                func r(_ c: CGRect?) -> String { c.map { "\(f($0.minX)),\(f($0.minY)),\(f($0.width)),\(f($0.height))" } ?? "-" }
                for k in ks { print("KEYSLOT \(name) \(kind.rawValue) \(k.id) hit \(r(k.hit)) drawn \(r(k.visible)) drawn2 \(r(k.visible2)) notch \(r(k.notch))") }
                print("KEYTABLE \(name) \(kind.rawValue) delete drawn \(f(del.visible.width))x\(f(del.visible.height)) hit \(f(del.hit.width))x\(f(del.hit.height))"
                      + " return drawn box \(f(retDrawn.width))x\(f(retDrawn.height)) area \(String(format: "%.0f", area(ret)))"
                      + " hit \(f(ret.hit.width))x\(f(ret.hit.height)) delete-return gap \(String(format: "%.2f", gapDR))"
                      + " space drawn \(f(sp.visible.width)) letter \(f(q.visible.width))x\(f(q.visible.height)) hit \(f(q.hit.width))x\(f(q.hit.height)) min hit h \(f(minHit))")
            }
        }
    }
}
