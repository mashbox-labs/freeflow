import XCTest
@testable import FreeFlowKit

final class LoadGateTests: XCTestCase {
    private actor Counter {
        var n = 0
        func bump() -> Int { n += 1; return n }
    }

    /// Five dictate presses while the model is still loading start ONE load, and all five get its result.
    func testPressesDuringASlowLoadShareOneLoad() async throws {
        let gate = LoadGate(), loads = Counter()
        let results = try await withThrowingTaskGroup(of: Double.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await gate.run("medium") {
                        _ = await loads.bump()
                        try await Task.sleep(nanoseconds: 300_000_000)   // a slow first load
                        return 0.3
                    }
                }
            }
            return try await group.reduce(into: [Double]()) { $0.append($1) }
        }
        let n = await loads.n
        XCTAssertEqual(n, 1, "parallel loads of the same model")
        XCTAssertEqual(results, [0.3, 0.3, 0.3, 0.3, 0.3])
    }

    private actor Live {
        var now = 0, most = 0
        func enter() { now += 1; most = max(most, now) }
        func leave() { now -= 1 }
    }

    /// Build 23 (small and large prepared at once): a newer pick waits for the load in flight, which learns
    /// it is no longer the pick (and lets its model go); never two loads at once.
    func testNewerPickWaitsAndTheOlderLoadIsNotThePick() async throws {
        let gate = LoadGate(), live = Live()
        let slow = Task { try await gate.run("large") { await live.enter(); try await Task.sleep(nanoseconds: 600_000_000); await live.leave(); return 2 } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let quick = try await gate.run("whisper-small-f16") { await live.enter(); await live.leave(); return 0.1 }
        XCTAssertEqual(quick, 0.1)
        let large = await gate.isWanted("large"), small = await gate.isWanted("whisper-small-f16")
        XCTAssertFalse(large, "the older load must let its model go")
        XCTAssertTrue(small)
        _ = try await slow.value
        let most = await live.most, gateMost = await gate.mostAtOnce
        XCTAssertEqual(most, 1, "two loads ran at once")
        XCTAssertEqual(gateMost, 1)
    }

    /// Build 23: a download finishes (its one-time build, want: false) while the pick is loading, and again while a
    /// build is running and a pick is waiting: every load runs alone, in turn, and the pick ends up wanted.
    func testDownloadFinishingDuringAnotherPrepareWaitsItsTurn() async throws {
        let gate = LoadGate(), live = Live()
        func work(_ v: Double) -> @Sendable () async throws -> Double {
            { await live.enter(); try await Task.sleep(nanoseconds: 200_000_000); await live.leave(); return v }
        }
        let pick = Task { try await gate.run("large", work(1)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let build = Task { try await gate.run("small", want: false, work(2)) }       // download done during the pick's prepare
        try await Task.sleep(nanoseconds: 30_000_000)
        let newPick = Task { try await gate.run("whisper-small-f16", work(3)) }     // and a new pick behind both
        let results = try await [pick.value, build.value, newPick.value]
        XCTAssertEqual(results, [1, 2, 3])
        let most = await live.most, gateMost = await gate.mostAtOnce
        XCTAssertEqual(most, 1, "a prepare started while another was running")
        XCTAssertEqual(gateMost, 1)
        let wanted = await gate.wanted
        XCTAssertEqual(wanted, "whisper-small-f16", "the build after a download is never the pick")
    }

    /// The one-time build after a download (want: false) is not a pick; picking that model during the build joins it.
    func testBuildIsNotAPickUntilPicked() async throws {
        let gate = LoadGate(), loads = Counter()
        let build = Task { try await gate.run("large", want: false) { _ = await loads.bump(); try await Task.sleep(nanoseconds: 300_000_000); return 1 } }
        try await Task.sleep(nanoseconds: 30_000_000)
        let before = await gate.isWanted("large")
        XCTAssertFalse(before)
        let picked = try await gate.run("large") { _ = await loads.bump(); return 9 }
        XCTAssertEqual(picked, 1, "picking during the build joins it")
        let n = await loads.n
        XCTAssertEqual(n, 1)
        let after = await gate.isWanted("large")
        XCTAssertTrue(after)
        _ = try await build.value
    }

    /// A failed load is not cached: the next press tries again.
    func testFailedLoadRetries() async throws {
        struct Boom: Error {}
        let gate = LoadGate()
        do { _ = try await gate.run("medium") { throw Boom() }; XCTFail("should throw") } catch {}
        let v = try await gate.run("medium") { 1.5 }
        XCTAssertEqual(v, 1.5)
    }

    private final class Flag: @unchecked Sendable { var on = false; var token = 0 }

    /// Build 24 (seen on an iPad: a prepare that never ended held every later load): a load past its limit is
    /// abandoned. Its caller gets TimedOut at once, the next load starts, and the abandoned load is no longer live.
    func testAHungLoadTimesOutAndTheNextLoadRuns() async throws {
        let gate = LoadGate(), limit = Flag()
        let token = Flag()
        let hung = Task { () -> Result<Double, Error> in
            do {
                return .success(try await gate.run("parakeet-ultra", expired: { limit.on }) { t in
                    token.token = t; token.on = true
                    try await Task.sleep(nanoseconds: 60_000_000_000)     // a prepare that does not come back
                    return 1
                })
            } catch { return .failure(error) }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let next = Task { try await gate.run("bark-3.0-clean") { 2 } }           // Bark, put in use behind it
        try await Task.sleep(nanoseconds: 300_000_000)
        limit.on = true
        let result = await hung.value
        guard case .failure(let error) = result else { return XCTFail("the hung load returned") }
        XCTAssertEqual(error as? LoadGate.TimedOut, LoadGate.TimedOut(id: "parakeet-ultra"))
        let bark = try await next.value
        XCTAssertEqual(bark, 2, "the load behind the hung one never ran")
        XCTAssertTrue(token.on)
        let live = await gate.isLive(token.token)
        XCTAssertFalse(live, "a timed-out load must not put its model in use")
        let wanted = await gate.wanted
        XCTAssertEqual(wanted, "bark-3.0-clean")
    }

    /// Build 24: a load abandoned on request (iOS suspended it in the background) ends with Abandoned, and a new load of
    /// the same model runs fresh.
    func testAbandonedLoadEndsAndRunsAgain() async throws {
        let gate = LoadGate(), loads = Counter()
        let first = Task { () -> Error? in
            do { _ = try await gate.run("bark-3-pro", expired: { false }) { _ in _ = await loads.bump(); try await Task.sleep(nanoseconds: 60_000_000_000); return 1 }; return nil }
            catch { return error }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.abandon("bark-3-pro")
        let error = await first.value
        XCTAssertEqual(error as? LoadGate.Abandoned, LoadGate.Abandoned(id: "bark-3-pro"))
        let again = try await gate.run("bark-3-pro", expired: { false }) { _ in _ = await loads.bump(); return 3 }
        XCTAssertEqual(again, 3)
        let n = await loads.n
        XCTAssertEqual(n, 2)
    }
}
