import CoreGraphics
import XCTest
@testable import FreeFlowKit

/// Build 18 (2026-10-30): Apple's keyboard in full. The #+= page, the field layouts, the pads, long-press
/// variants, capitals, the double-space period and the return label.
final class KeyPagesTests: XCTestCase {
    static let widths: [(Double, Bool)] = [375, 393, 402, 420, 440].map { ($0, false) } + [744, 1024].map { ($0, true) }

    private func keys(_ kind: KeyLayoutKind, _ w: Double, pad: Bool, page: KeyPage, field: KeyField) -> (keys: [KeySlot], h: Double) {
        let h = KeyboardLayouts.height(width: w, isPad: pad)
        return (KeyboardLayouts.keys(kind, width: w, height: h, isPad: pad, scale: pad ? 2 : 3, page: page, field: field), h)
    }

    private func pages(for field: KeyField) -> [KeyPage] {
        field.firstPage.isPad ? (field == .phonePad ? [.pad, .padSymbols] : [.pad]) : [.letters, .numbers, .symbols]
    }

    /// Every page in every field and layout: each point belongs to exactly one key, ids are unique, taps are 44 pt tall.
    func testEveryPageTiles() {
        for kind in KeyLayoutKind.allCases {
            for (w, pad) in Self.widths {
                for field in KeyField.allCases {
                    for page in pages(for: field) {
                        let (ks, h) = keys(kind, w, pad: pad, page: page, field: field)
                        let tag = "\(kind) \(w) \(field) \(page)"
                        XCTAssertEqual(Set(ks.map(\.id)).count, ks.count, "\(tag) duplicate ids")
                        for k in ks { XCTAssertGreaterThanOrEqual(k.hit.height, 44, "\(tag) \(k.id) hit height") }
                        var y = 0.37
                        outer: while y < h {
                            var x = 0.41
                            while x < w {
                                let n = ks.filter { $0.contains(CGPoint(x: x, y: y)) }.count
                                if n != 1 { XCTFail("\(tag) point \(x),\(y): \(n) keys"); break outer }
                                x += 2.5
                            }
                            y += 2.5
                        }
                    }
                }
            }
        }
    }

    /// Apple's #+= page and its z row: the page key where shift is, . , ? ! ' between z and m, delete in the corner.
    func testSymbolsPageIsApples() {
        let (ks, _) = keys(.classic, 420, pad: false, page: .symbols, field: .text)
        let ids = Set(ks.map(\.id))
        for c in "[]{}#%^*+=_\\|~<>€£¥•.,?!'" { XCTAssertTrue(ids.contains(String(c)), "missing \(c)") }
        XCTAssertTrue(ids.contains("more")); XCTAssertTrue(ids.contains("abc123")); XCTAssertTrue(ids.contains("delete"))
        let (letters, _) = keys(.classic, 420, pad: false, page: .letters, field: .text)
        let more = ks.first { $0.id == "more" }!, shift = letters.first { $0.id == "shift" }!
        XCTAssertEqual(more.visible, shift.visible, "the page key sits where shift is")
        let dot = ks.first { $0.id == "." }!, apos = ks.first { $0.id == "'" }!
        let z = letters.first { $0.id == "z" }!, m = letters.first { $0.id == "m" }!
        XCTAssertEqual(dot.visible.minX, z.visible.minX, accuracy: 1e-9)
        XCTAssertEqual(apos.visible.maxX, m.visible.maxX, accuracy: 1e-9)
    }

    /// The bottom row per field: email @ and ., URL . / .com and no space, twitter @ and #, web search .
    func testFieldBottomRows() {
        for (field, want) in [(KeyField.email, ["bx:@", "bx:."]), (.url, ["bx:.", "bx:/", "bx:.com"]), (.twitter, ["bx:@", "bx:#"]), (.webSearch, ["bx:."])] {
            let (ks, _) = keys(.classic, 420, pad: false, page: .letters, field: field)
            let bottom = ks.filter { $0.id.hasPrefix("bx:") }.sorted { $0.visible.minX < $1.visible.minX }.map(\.id)
            XCTAssertEqual(bottom, want, "\(field)")
            XCTAssertEqual(ks.contains { $0.id == "space" }, field != .url, "\(field) space")
        }
        XCTAssertEqual(KeyFaceState(stylePill: "x").shown("bx:.com"), ".com")
    }

    func testPads() {
        for field in [KeyField.numberPad, .decimalPad, .phonePad] {
            let (ks, _) = keys(.classic, 402, pad: false, page: .pad, field: field)
            for d in "0123456789" { XCTAssertNotNil(ks.first { $0.id == String(d) }, "\(field) \(d)") }
            XCTAssertNotNil(ks.first { $0.id == "delete" })
            XCTAssertNotNil(ks.first { $0.id == "mic" }, "the Dictate row stays on top")
        }
        XCTAssertNotNil(keys(.classic, 402, pad: false, page: .pad, field: .decimalPad).keys.first { $0.id == "." })
        XCTAssertNotNil(keys(.classic, 402, pad: false, page: .pad, field: .phonePad).keys.first { $0.id == "padmore" })
        let sym = keys(.classic, 402, pad: false, page: .padSymbols, field: .phonePad).keys
        for c in ["+", "*", "#"] { XCTAssertNotNil(sym.first { $0.id == c }, c) }
    }

    func testFieldFromKeyboardType() {
        XCTAssertEqual(KeyField(keyboardType: 0), .text)
        XCTAssertEqual(KeyField(keyboardType: 2).firstPage, .numbers)
        XCTAssertEqual(KeyField(keyboardType: 3), .url)
        XCTAssertEqual(KeyField(keyboardType: 4).firstPage, .pad)
        XCTAssertEqual(KeyField(keyboardType: 5), .phonePad)
        XCTAssertEqual(KeyField(keyboardType: 6), .text)
        XCTAssertEqual(KeyField(keyboardType: 7), .email)
        XCTAssertEqual(KeyField(keyboardType: 8), .decimalPad)
        XCTAssertEqual(KeyField(keyboardType: 11), .numberPad)
    }

    func testReturnLabels() {
        XCTAssertNil(ReturnKeyLabel.text(0))
        XCTAssertEqual(ReturnKeyLabel.text(1), "go")
        XCTAssertEqual(ReturnKeyLabel.text(6), "search")
        XCTAssertEqual(ReturnKeyLabel.text(7), "send")
        XCTAssertEqual(ReturnKeyLabel.text(9), "done")
        XCTAssertFalse(ReturnKeyLabel.prominent(0)); XCTAssertFalse(ReturnKeyLabel.prominent(4)); XCTAssertTrue(ReturnKeyLabel.prominent(1))
    }

    func testAutoCapital() {
        XCTAssertTrue(AutoCapital.wantsShift(before: "", mode: 2))
        XCTAssertTrue(AutoCapital.wantsShift(before: "Hi. ", mode: 2))
        XCTAssertTrue(AutoCapital.wantsShift(before: "Really?  ", mode: 2))
        XCTAssertTrue(AutoCapital.wantsShift(before: "line\n", mode: 2))
        XCTAssertFalse(AutoCapital.wantsShift(before: "Hi there ", mode: 2))
        XCTAssertFalse(AutoCapital.wantsShift(before: "Hi.", mode: 2))
        XCTAssertFalse(AutoCapital.wantsShift(before: "", mode: 0))
        XCTAssertTrue(AutoCapital.wantsShift(before: "one ", mode: 1))
        XCTAssertFalse(AutoCapital.wantsShift(before: "one", mode: 1))
        XCTAssertTrue(AutoCapital.wantsShift(before: "abc", mode: 3))
    }

    func testDoubleSpace() {
        XCTAssertTrue(DoubleSpace.makesPeriod(before: "see you "))
        XCTAssertTrue(DoubleSpace.makesPeriod(before: "at 4 "))
        XCTAssertFalse(DoubleSpace.makesPeriod(before: "see you"))
        XCTAssertFalse(DoubleSpace.makesPeriod(before: "see you.  "))
        XCTAssertFalse(DoubleSpace.makesPeriod(before: "done. "))
        XCTAssertFalse(DoubleSpace.makesPeriod(before: " "))
    }

    /// Apple's panels (iOS 27.2 simulator holds): the key's own character included and selected first.
    func testCallouts() {
        let e = KeyCallouts.panel("e", page: .letters, upper: false)!
        XCTAssertEqual(e.options, ["ë", "é", "e", "è", "ê", "ě", "ẽ", "ē", "ė", "ę"])
        XCTAssertEqual(e.options[e.base], "e")
        let a = KeyCallouts.panel("a", page: .letters, upper: false)!
        XCTAssertEqual(a.rows.count, 2); XCTAssertEqual(a.options[a.base], "a"); XCTAssertEqual(a.baseColumn, 0)
        XCTAssertTrue(KeyCallouts.variants("n", page: .letters, upper: false).contains("ñ"))
        XCTAssertTrue(KeyCallouts.variants("c", page: .letters, upper: false).contains("ç"))
        XCTAssertTrue(KeyCallouts.variants("s", page: .letters, upper: false).contains("ß"))
        let S = KeyCallouts.panel("s", page: .letters, upper: true)!
        XCTAssertFalse(S.options.contains("SS"), "no two-letter capital"); XCTAssertEqual(S.options[S.base], "S")
        let I = KeyCallouts.panel("i", page: .letters, upper: true)!
        XCTAssertEqual(I.options.filter { $0 == "I" }.count, 1, "the capital of ı is I: shown once")
        XCTAssertEqual(I.options[I.base], "I")
        XCTAssertNil(KeyCallouts.panel("q", page: .letters, upper: false))
        for id in ["p", "f", "j", "x", "v", "b", "m"] { XCTAssertNil(KeyCallouts.panel(id, page: .letters, upper: false), id) }
        let k = KeyCallouts.panel("k", page: .letters, upper: false)!
        XCTAssertEqual(k.options, ["ķ", "k"]); XCTAssertEqual(k.base, 1, "Apple puts k on the right of its panel")
        XCTAssertEqual(KeyCallouts.panel("t", page: .letters, upper: true)!.options, ["T", "Ț", "Ť", "Þ"])
        XCTAssertNil(KeyCallouts.panel("e", page: .numbers, upper: false))
        let d = KeyCallouts.panel("$", page: .numbers, upper: false)!
        XCTAssertEqual(d.options, ["₽", "¥", "€", "$", "¢", "£", "₩"]); XCTAssertEqual(d.base, 3)
        // the panel stays inside the keyboard, above the key; the key's own character sits over the key when there is room
        for id in ["e", "a", "o", "u", "l", "y"] {
            let p = KeyCallouts.panel(id, page: .letters, upper: false)!
            for x in [3.0, 200.0, 380.0] {
                let key = CGRect(x: x, y: 120, width: 35, height: 45)
                let g = CalloutGeometry.layout(key: key, panel: p, width: 420)
                XCTAssertEqual(g.cells.count, p.options.count)
                XCTAssertGreaterThanOrEqual(g.panel.minX, 2); XCTAssertLessThanOrEqual(g.panel.maxX, 418)
                XCTAssertGreaterThanOrEqual(g.panel.minY, 2); XCTAssertLessThan(g.panel.maxY, key.minY)
                XCTAssertEqual(CalloutGeometry.selected(at: CGPoint(x: g.cells[1].midX, y: g.cells[1].midY), cells: g.cells), 1)
            }
        }
        // our e key on the 420 pt iPhone Air (MKEY frames): e's own cell covers the key's middle, as Apple's does
        let ek = CGRect(x: 89, y: 65, width: 35.33, height: 45)
        let g = CalloutGeometry.layout(key: ek, panel: e, width: 420)
        XCTAssertTrue(g.cells[e.base].minX <= ek.midX && ek.midX <= g.cells[e.base].maxX, "e's own cell over the e key")
    }
}
