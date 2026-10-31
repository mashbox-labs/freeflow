import XCTest
@testable import FreeFlowKit

/// The keyboard opens Free Flow by a link name only Free Flow answers (a second install that also
/// claimed "freeflow" caught the iPad keyboard's link and opened on its setup page).
final class SchemeTests: XCTestCase {
    func testDictateLinkUsesOurSchemeAndOldLinksStillCount() {
        XCTAssertEqual(FF.dictateURL.scheme, FF.urlScheme)
        XCTAssertEqual(FF.dictateURL.host, "dictate")
        XCTAssertTrue(FF.isOurs(FF.dictateURL))
        XCTAssertTrue(FF.isOurs(URL(string: "freeflow://dictate")!))
        XCTAssertFalse(FF.isOurs(URL(string: "https://mashbox.gg")!))
    }

    func testBundleSchemeIsAValidURLScheme() {
        let scheme = "org.example.freeflow"
        XCTAssertNotNil(URL(string: scheme + "://dictate"))
        XCTAssertEqual(URL(string: scheme + "://dictate")?.scheme, scheme)
    }
}
