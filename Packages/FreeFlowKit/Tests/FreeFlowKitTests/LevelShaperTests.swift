import XCTest
@testable import FreeFlowKit

final class LevelShaperTests: XCTestCase {
    private func rms(db: Float) -> Float { pow(10, db / 20) }

    func testNoiseFloorStaysAtTheBottom() {
        XCTAssertEqual(LevelShaper.target(rms: rms(db: -60)), 0)
        XCTAssertEqual(LevelShaper.target(rms: rms(db: -50)), 0, accuracy: 1e-6)
        XCTAssertEqual(LevelShaper.target(rms: 0), 0)
        XCTAssertEqual(LevelShaper.target(rms: rms(db: -6)), 1)
    }

    func testMoreRangeBetweenQuietAndLoudThanTheOldMap() {
        let quiet: Float = -40, normal: Float = -25, loud: Float = -15
        let new = (LevelShaper.target(rms: rms(db: quiet)), LevelShaper.target(rms: rms(db: normal)), LevelShaper.target(rms: rms(db: loud)))
        XCTAssertEqual(new.0, 0.12, accuracy: 0.01)
        XCTAssertEqual(new.1, 0.51, accuracy: 0.01)
        XCTAssertEqual(new.2, 0.88, accuracy: 0.01)
        let oldSpread = Levels.normalise(rms: rms(db: loud)) - Levels.normalise(rms: rms(db: quiet))
        XCTAssertGreaterThan(new.2 - new.0, oldSpread + 0.15, "quiet vs loud reads more clearly than before")
    }

    func testMonotonic() {
        var prev: Float = -1
        for db in stride(from: Float(-70), through: 0, by: 0.5) {
            let v = LevelShaper.target(rms: rms(db: db))
            XCTAssertGreaterThanOrEqual(v, prev, "\(db) dB")
            prev = v
        }
    }

    func testFastAttackSlowerRelease() {
        var s = LevelShaper()
        let up = s.next(rms: rms(db: -15))
        XCTAssertGreaterThanOrEqual(up, 0.6, "one chunk (~43 ms) reaches most of a loud level")
        for _ in 0..<5 { _ = s.next(rms: rms(db: -15)) }
        let top = s.level
        let down = s.next(rms: 0)
        XCTAssertGreaterThanOrEqual(down, top * 0.75, "one chunk of silence only starts the fall")
        for _ in 0..<20 { _ = s.next(rms: 0) }
        XCTAssertLessThan(s.level, 0.02, "about a second of silence brings the bars back down")
    }
}
