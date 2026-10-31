import XCTest
@testable import FreeFlowKit

/// Build 9: History > Recent recordings says why a recording stopped, also after a Retry, and a full disk is named.
final class StopReasonTests: XCTestCase {
    private func store() throws -> ClipStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ff-stop-\(UUID().uuidString)")
        return ClipStore(folder: dir)
    }

    func testAClipClosedByAKillKeepsItsReasonAfterRetry() throws {
        let s = try store()
        let w = try XCTUnwrap(s.begin())
        w.append([Float](repeating: 0.1, count: 16_000 * 3))
        _ = w.close()
        let closed = try XCTUnwrap(s.close(w.id, status: .unfinished, reason: ClipReason.closed, seconds: 3))
        XCTAssertEqual(closed.whyStopped, ClipReason.closed)
        s.update(w.id) { $0.status = .transcribed; $0.reason = ""; $0.text = "hello" }
        XCTAssertEqual(s.clip(w.id)?.whyStopped, ClipReason.closed, "the reason survives a Retry")
    }

    func testAFullDiskStopsTheSavedCopyAndSaysSo() throws {
        let s = try store()
        let w = try XCTUnwrap(s.begin())
        w.append([Float](repeating: 0.1, count: 16_000))
        w.flush()                       // the first second is on disk before the disk "fills"
        w.failNextWrite = true
        w.append([Float](repeating: 0.1, count: 16_000))
        w.append([Float](repeating: 0.1, count: 16_000))
        XCTAssertTrue(w.writeFailed)
        let seconds = w.close()
        XCTAssertEqual(seconds, 1, accuracy: 0.01, "the file keeps what was written before the disk filled")
    }
}
