import XCTest
@testable import FreeFlowKit

final class LevelFeedTests: XCTestCase {
    /// 48 kHz input with 2,048-frame buffers = 23.4 levels a second; build 8 published twice per level.
    func testUIAndKeyboardSnapshotsAreAtMost10PerSecond() {
        var feed = LevelFeed()
        var ui = 0, shared = 0, asked = 0
        let rate = 48_000.0 / 2048
        for i in 0..<Int(rate * 60) {
            let out = feed.push(Float(i % 10) / 10, now: Double(i) / rate, appActive: true, keyboardShowing: { asked += 1; return true })
            if out.ui != nil { ui += 1 }
            if out.shared != nil { shared += 1 }
        }
        XCTAssertLessThanOrEqual(ui, 601)
        XCTAssertGreaterThanOrEqual(ui, 450)
        XCTAssertLessThanOrEqual(shared, 601)
        XCTAssertEqual(asked, shared, "keyboard presence is read only when a write is due")
    }

    func testNothingForTheUIWhileTheAppIsNotActive() {
        var feed = LevelFeed()
        for i in 0..<2000 {
            XCTAssertNil(feed.push(0.5, now: Double(i) * 0.02, appActive: false, keyboardShowing: { false }).ui)
        }
    }

    func testNoKeyboardWritesWhileTheKeyboardIsHidden() {
        var feed = LevelFeed()
        for i in 0..<2000 {
            XCTAssertNil(feed.push(0.5, now: Double(i) * 0.02, appActive: true, keyboardShowing: { false }).shared)
        }
    }

    func testRingKeepsTheLastLevelsOldestFirst() {
        var feed = LevelFeed(count: 4)
        for (i, v) in [Float(1), 2, 3, 4, 5, 6].enumerated() { _ = feed.push(v, now: Double(i), appActive: false, keyboardShowing: { false }) }
        XCTAssertEqual(feed.snapshot, [3, 4, 5, 6])
        feed.reset()
        XCTAssertEqual(feed.snapshot, [0, 0, 0, 0])
    }

    func testKeyboardPresence() {
        let now = Date()
        XCTAssertTrue(KeyboardPresence.isShowing(upAt: now.addingTimeInterval(-0.6), now: now))
        XCTAssertFalse(KeyboardPresence.isShowing(upAt: now.addingTimeInterval(-3), now: now))
        XCTAssertFalse(KeyboardPresence.isShowing(upAt: nil, now: now))
    }
}

final class CpuBudgetTests: XCTestCase {
    func testIdleHistoryLetsWorkStart() {
        var b = CpuBudget(limit: 0.5)
        for t in 0...60 { b.record(t: Double(t), cpu: Double(t) * 0.05) }
        XCTAssertEqual(b.wait(t: 60, cpu: 3, cost: 10), 0)
    }

    func testABusyMinuteMakesWorkWait() {
        var b = CpuBudget(limit: 0.5)
        for t in 0...60 { b.record(t: Double(t), cpu: Double(t)) }   // one core, 100%
        XCTAssertGreaterThan(b.wait(t: 60, cpu: 60, cost: 5), 0)
    }

    func testAnEmptyHistoryIsCountedAtTheLimit() {
        let b = CpuBudget(limit: 0.5)
        XCTAssertEqual(b.used(t: 100, cpu: 7), b.allowed)
    }

    /// Simulated C++ fallback in the background: 1 thread, pieces of 30 s audio costing 0.4 CPU s per audio second,
    /// 5% base load (capture, disk). With the budget the worst trailing 60 s stays under 60% of a core; without it
    /// the same work runs at ~100%.
    func testPacedPiecesStayUnderTheMarginOverAnHour() {
        var b = CpuBudget(limit: 0.5)
        var t = 0.0, cpu = 0.0
        var trace: [(Double, Double)] = []
        func tick(_ dt: Double, busy: Bool) {
            var left = dt
            while left > 0 {
                let s = min(0.5, left)
                t += s; cpu += s * (busy ? 1.0 : 0.05); left -= s
                b.record(t: t, cpu: cpu); trace.append((t, cpu))
            }
        }
        tick(60, busy: false)
        for _ in 0..<120 {
            let cost = 30 * 0.4
            while true {
                let w = b.wait(t: t, cpu: cpu, cost: cost)
                if w <= 0 { break }
                tick(min(w, 5), busy: false)
            }
            tick(cost, busy: true)
        }
        var worst = 0.0
        var j = 0
        for i in 0..<trace.count {
            while trace[j].0 < trace[i].0 - 60 { j += 1 }
            if trace[i].0 - trace[j].0 >= 59 { worst = max(worst, (trace[i].1 - trace[j].1) / (trace[i].0 - trace[j].0)) }
        }
        XCTAssertLessThan(worst, 0.6, "worst 60 s window \(worst)")
        XCTAssertGreaterThan(worst, 0.4, "the budget should still be used")
    }
}
