import CoreGraphics
import XCTest
@testable import FreeFlowKit

/// Build 37: the style key only does something with Apple Intelligence cleanup on. Off, the action row is
/// the hide key in the style key's place and Dictate unchanged; every other key stays exactly where it was.
final class StyleKeyTests: XCTestCase {
    private func keys(_ kind: KeyLayoutKind, _ w: Double, pad: Bool, styleKey: Bool, page: KeyPage? = nil) -> [KeySlot] {
        let h = KeyboardLayouts.height(width: w, isPad: pad)
        return KeyboardLayouts.keys(kind, width: w, height: h, isPad: pad, scale: pad ? 2 : 3, page: page, styleKey: styleKey)
    }

    func testNoStyleKeyWithCleanupOff() {
        for (pad, widths) in [(false, KeyLayoutsTests.phoneWidths), (true, KeyLayoutsTests.padWidths)] {
            for w in widths {
                for kind in KeyLayoutKind.allCases {
                    let page: KeyPage? = pad ? .pad : nil
                    let on = keys(kind, w, pad: pad, styleKey: true, page: page), off = keys(kind, w, pad: pad, styleKey: false, page: page)
                    let t = "\(kind) \(w) pad \(pad)"
                    XCTAssertNotNil(on.first { $0.id == "style" }, t)
                    XCTAssertNil(off.first { $0.id == "style" }, t)
                    let hideOn = on.first { $0.id == "hide" }!, hideOff = off.first { $0.id == "hide" }!
                    let micOn = on.first { $0.id == "mic" }!, micOff = off.first { $0.id == "mic" }!
                    if pad {  // build 38: hide takes the style key's place (and the gap); Dictate keeps its exact frame
                        XCTAssertEqual(hideOff.hit, hideOn.hit.union(on.first { $0.id == "style" }!.hit), t)
                        XCTAssertGreaterThan(hideOff.visible.width, hideOn.visible.width + 40, t)
                        XCTAssertEqual(micOff.hit, micOn.hit, t); XCTAssertEqual(micOff.visible, micOn.visible, t)
                    } else {  // iPhone: build 37's row, hide 84 pt, Dictate the rest
                        XCTAssertEqual(hideOff.hit.width, 84, accuracy: 0.5, t)
                        XCTAssertGreaterThan(micOff.hit.width, micOn.hit.width, t)
                        XCTAssertEqual(hideOff.hit.width + micOff.hit.width, w, accuracy: 1e-6, t)
                    }
                    // nothing else moves
                    let rest = { (ks: [KeySlot]) in ks.filter { $0.kind != .action } }
                    XCTAssertEqual(rest(off).map(\.id), rest(on).map(\.id), t)
                    for (a, b) in zip(rest(off), rest(on)) { XCTAssertEqual(a.hit, b.hit, t + " " + a.id); XCTAssertEqual(a.visible, b.visible, t + " " + a.id) }
                }
            }
        }
    }

    func testNotMirroredYetShowsTheKey() {
        let saved = SharedSession.writerOn
        defer { SharedSession.writerOn = saved }
        SharedSession.writerOn = nil
        XCTAssertTrue(SharedSession.styleKeyShown)
        SharedSession.writerOn = false
        XCTAssertFalse(SharedSession.styleKeyShown)
        SharedSession.writerOn = true
        XCTAssertTrue(SharedSession.styleKeyShown)
    }
}
