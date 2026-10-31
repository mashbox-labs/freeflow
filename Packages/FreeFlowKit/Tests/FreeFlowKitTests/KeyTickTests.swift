import XCTest
@testable import FreeFlowKit

final class KeyTickTests: XCTestCase {
    func testOffPlaysNothing() {
        for kind in KeyTick.Kind.allCases { XCTAssertTrue(KeyTick.events(kind, level: .off, gap: 1).isEmpty) }
    }

    func testKeyClassesDiffer() {
        let letter = KeyTick.design(.letter)[0], space = KeyTick.design(.space)[0], enter = KeyTick.design(.enter)[0]
        XCTAssertGreaterThan(letter.sharpness, space.sharpness, "letters are crisper than space")
        XCTAssertLessThan(space.intensity, letter.intensity, "space is softer")
        XCTAssertGreaterThan(enter.intensity, letter.intensity, "return is firmer")
        XCTAssertEqual(KeyTick.design(.mic).count, 2, "the mic has its own two-part click")
    }

    func testLevelsOrderAndClamp() {
        let i = KeyTick.Level.allCases.dropFirst().map { KeyTick.events(.letter, level: $0, gap: 1)[0].intensity }
        XCTAssertEqual(i, i.sorted())
        XCTAssertLessThanOrEqual(KeyTick.events(.mic, level: .strong, gap: 1, sizeFactor: 1.25)[0].intensity, 1)
    }

    func testFastTypingIsLighter() {
        XCTAssertEqual(KeyTick.paceFactor(gap: 0.5), 1)
        XCTAssertEqual(KeyTick.paceFactor(gap: 0.12), 1, accuracy: 1e-9)
        XCTAssertEqual(KeyTick.paceFactor(gap: 0.03), 0.55)
        XCTAssertLessThan(KeyTick.paceFactor(gap: 0.06), KeyTick.paceFactor(gap: 0.10))
    }

    func testOneReportedSizeMeansFixedClicks() {
        var s = ContactSizes()
        for _ in 0..<40 { s.add(radius: 20.9, tolerance: 5.2, force: 0) }
        XCTAssertFalse(s.varies)
        XCTAssertEqual(s.factor(for: 20.9), 1)
        XCTAssertEqual(s.forceSeen, 0)
    }

    func testSizesWithinToleranceDoNotScale() {
        var s = ContactSizes()
        for i in 0..<40 { s.add(radius: i % 2 == 0 ? 20 : 22, tolerance: 5, force: 0) }
        XCTAssertFalse(s.varies, "a 2 pt spread under a 5 pt tolerance is noise")
    }

    func testRealSpreadScales() {
        var s = ContactSizes()
        for i in 0..<60 { s.add(radius: [20.9, 31.4, 41.8][i % 3], tolerance: 5.2, force: 0) }
        XCTAssertTrue(s.varies)
        XCTAssertEqual(s.factor(for: 20.9), 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.factor(for: 41.8), 1.25, accuracy: 1e-9)
        XCTAssertEqual(s.factor(for: 31.4), 1.0, accuracy: 0.01)
    }

    func testKeepsOnlyRecentAndSkipsZero() {
        var s = ContactSizes(recent: [0, 10, 12], capacity: 4)
        XCTAssertEqual(s.recent, [10, 12])
        for r in [14.0, 16, 18, 0] { s.add(radius: r, tolerance: 1, force: 0) }
        XCTAssertEqual(s.recent, [12, 14, 16, 18])
        XCTAssertEqual(s.touches, 4)
    }
}
