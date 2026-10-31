import XCTest
@testable import FreeFlowKit

/// The Mac's fn hotkey (FnGesture): hold to talk, quick taps, hands-free by double press or fn+Space, Esc, shortcuts.
final class FnGestureTests: XCTestCase {
    func testHoldTalksAndInsertsOnRelease() {
        var g = FnGesture()
        XCTAssertEqual(g.fnPressed(at: 0), .start)
        XCTAssertEqual(g.mode, .holding)
        XCTAssertEqual(g.fnReleased(at: 1.2), .stopAndInsert)
        XCTAssertEqual(g.mode, .idle)
    }

    func testPressUnderHalfASecondInsertsNothing() {
        var g = FnGesture()
        XCTAssertEqual(g.fnPressed(at: 0), .start)
        XCTAssertEqual(g.fnReleased(at: 0.3), .cancel)
        XCTAssertEqual(g.mode, .idle)
    }

    func testDoublePressStartsHandsFreeAndThePressAfterStops() {
        var g = FnGesture()
        XCTAssertEqual(g.fnPressed(at: 0), .start)
        XCTAssertEqual(g.fnReleased(at: 0.1), .cancel)
        XCTAssertEqual(g.fnPressed(at: 0.3), .startHandsFree)
        XCTAssertEqual(g.fnReleased(at: 0.4), .none)
        XCTAssertEqual(g.mode, .handsFree)
        XCTAssertEqual(g.fnPressed(at: 6), .none)
        XCTAssertEqual(g.fnReleased(at: 6.1), .stopAndInsert)
        XCTAssertEqual(g.mode, .idle)
    }

    func testThirdQuickPressAfterDoublePressCancels() {
        var g = FnGesture()
        _ = g.fnPressed(at: 0); _ = g.fnReleased(at: 0.1)
        XCTAssertEqual(g.fnPressed(at: 0.3), .startHandsFree)
        _ = g.fnReleased(at: 0.4)
        XCTAssertEqual(g.fnPressed(at: 0.6), .cancel)
        XCTAssertEqual(g.fnReleased(at: 0.7), .none)
        XCTAssertEqual(g.mode, .idle)
    }

    func testSlowSecondPressIsAnotherHold() {
        var g = FnGesture()
        _ = g.fnPressed(at: 0); _ = g.fnReleased(at: 0.1)
        XCTAssertEqual(g.fnPressed(at: 0.9), .start)
        XCTAssertEqual(g.mode, .holding)
        XCTAssertEqual(g.fnReleased(at: 2), .stopAndInsert)
    }

    func testPressRightAfterAnInsertIsNotADoublePress() {
        var g = FnGesture()
        _ = g.fnPressed(at: 0)
        XCTAssertEqual(g.fnReleased(at: 1.0), .stopAndInsert)
        XCTAssertEqual(g.fnPressed(at: 1.2), .start)
        XCTAssertEqual(g.mode, .holding)
    }

    func testFnSpaceGoesHandsFreeAndFnSpaceAgainStops() {
        var g = FnGesture()
        XCTAssertEqual(g.fnPressed(at: 0), .start)
        let first = g.keyPressed(.space, at: 0.3)
        XCTAssertEqual(first.action, .becomeHandsFree)
        XCTAssertTrue(first.swallow)
        XCTAssertEqual(g.fnReleased(at: 0.5), .none)
        XCTAssertEqual(g.mode, .handsFree)
        XCTAssertEqual(g.fnPressed(at: 5), .none)
        let second = g.keyPressed(.space, at: 5.1)
        XCTAssertEqual(second.action, .stopAndInsert)
        XCTAssertTrue(second.swallow)
        XCTAssertEqual(g.fnReleased(at: 5.2), .none)
        XCTAssertEqual(g.mode, .idle)
    }

    func testFnWithAnotherKeyIsAShortcutNotDictation() {
        var g = FnGesture()
        XCTAssertEqual(g.fnPressed(at: 0), .start)
        let arrow = g.keyPressed(.other, at: 0.1)
        XCTAssertEqual(arrow.action, .cancel)
        XCTAssertFalse(arrow.swallow)
        XCTAssertEqual(g.fnReleased(at: 0.2), .none)
        XCTAssertEqual(g.mode, .idle)
    }

    func testShortcutDuringHandsFreeDoesNotStopIt() {
        var g = FnGesture()
        _ = g.fnPressed(at: 0); _ = g.fnReleased(at: 0.1)
        _ = g.fnPressed(at: 0.3); _ = g.fnReleased(at: 0.4)
        XCTAssertEqual(g.fnPressed(at: 3), .none)
        XCTAssertEqual(g.keyPressed(.other, at: 3.1).action, .none)
        XCTAssertEqual(g.fnReleased(at: 3.2), .none)
        XCTAssertEqual(g.mode, .handsFree)
    }

    func testTypingWithoutFnDuringHandsFreeGoesThrough() {
        var g = FnGesture()
        _ = g.fnPressed(at: 0); _ = g.fnReleased(at: 0.1)
        _ = g.fnPressed(at: 0.3); _ = g.fnReleased(at: 0.4)
        let typed = g.keyPressed(.space, at: 2)
        XCTAssertEqual(typed.action, .none)
        XCTAssertFalse(typed.swallow)
        XCTAssertEqual(g.mode, .handsFree)
    }

    func testEscapeCancelsAndIsKeptFromTheAppOnlyWhileRecording() {
        var g = FnGesture()
        let idle = g.keyPressed(.escape, at: 0)
        XCTAssertEqual(idle.action, .none)
        XCTAssertFalse(idle.swallow)
        _ = g.fnPressed(at: 1)
        let esc = g.keyPressed(.escape, at: 1.5)
        XCTAssertEqual(esc.action, .cancel)
        XCTAssertTrue(esc.swallow)
        XCTAssertEqual(g.fnReleased(at: 2), .none)
        XCTAssertEqual(g.mode, .idle)
    }

    func testFnWithOtherModifiersIsIgnored() {
        var g = FnGesture()
        XCTAssertEqual(g.fnPressed(at: 0, otherModifiers: true), .none)
        XCTAssertEqual(g.fnReleased(at: 1), .none)
        XCTAssertEqual(g.mode, .idle)
    }

    func testRepeatedDownWithoutUpChangesNothing() {
        var g = FnGesture()
        XCTAssertEqual(g.fnPressed(at: 0), .start)
        XCTAssertEqual(g.fnPressed(at: 0.2), .none)
        XCTAssertEqual(g.fnReleased(at: 1), .stopAndInsert)
    }

    func testResetEndsHandsFreeFromThePill() {
        var g = FnGesture()
        _ = g.fnPressed(at: 0); _ = g.fnReleased(at: 0.1)
        _ = g.fnPressed(at: 0.3); _ = g.fnReleased(at: 0.4)
        g.reset()
        XCTAssertEqual(g.mode, .idle)
        XCTAssertEqual(g.fnPressed(at: 5), .start)
    }
}
