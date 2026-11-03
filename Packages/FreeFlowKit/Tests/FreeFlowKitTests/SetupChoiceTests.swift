import XCTest
@testable import FreeFlowKit

/// Build 38: the first-run page shows exactly two cards, the recommendation first. Build 39: our Whisper
/// first from 7.0 GiB (8 GB devices) with Parakeet Ultra second; below that Parakeet first, then Whisper where it fits,
/// else the best smaller model that fits.
final class SetupChoiceTests: XCTestCase {
    private func bytes(_ gib: Double) -> UInt64 { UInt64(gib * 1_073_741_824) }

    func testWhisperFirstWhereItRunsProperly() {
        for gib in [7.5, 11.2, 15.0] {
            XCTAssertEqual(ModelCatalog.setupChoices(memoryBytes: bytes(gib)).map(\.id), ["whisper-turbo-ane", "parakeet-ultra"], "\(gib)")
        }
    }

    func testParakeetFirstThenWhisperOn6GB() {
        XCTAssertEqual(ModelCatalog.setupChoices(memoryBytes: bytes(5.6)).map(\.id), ["parakeet-ultra", "whisper-turbo-ane"])
    }

    func testSmallDeviceStillTwoCards() {
        for gib in [2.8, 3.7, 4.6] {
            let c = ModelCatalog.setupChoices(memoryBytes: bytes(gib))
            XCTAssertEqual(c.count, 2, "\(gib): \(c.map(\.id))")
            XCTAssertEqual(c.first?.id, ModelCatalog.recommended(memoryBytes: bytes(gib)).id)
            XCTAssertEqual(c.first?.engine, .parakeetV3)
            XCTAssertFalse(c[1].engine.isWhisper)
            XCTAssertTrue(c.allSatisfy { $0.fits(memoryBytes: bytes(gib)) && !$0.engine.isCpp })
        }
    }

    func testRecommendedMatchesThePicker() {
        for gib in [3.7, 5.6, 7.5, 11.2] {
            XCTAssertEqual(ModelCatalog.recommended(memoryBytes: bytes(gib), language: "en").id, ModelCatalog.setupChoices(memoryBytes: bytes(gib)).first?.id, "\(gib)")
        }
    }
}
