import FreeFlowKit
import XCTest

/// The Mac's one leading space before a pasted dictation.
final class LeadingSpaceTests: XCTestCase {
    func testAfterAWordOrPunctuation() {
        XCTAssertEqual(LeadingSpace.apply(before: "d", to: "Hello"), " Hello")
        XCTAssertEqual(LeadingSpace.apply(before: ".", to: "Hello"), " Hello")
        XCTAssertEqual(LeadingSpace.apply(before: "😀", to: "hi"), " hi")
    }

    func testNoSpace() {
        XCTAssertEqual(LeadingSpace.apply(before: nil, to: "Hello"), "Hello", "unreadable or start of the field: as today")
        XCTAssertEqual(LeadingSpace.apply(before: " ", to: "Hello"), "Hello")
        XCTAssertEqual(LeadingSpace.apply(before: "\t", to: "Hello"), "Hello")
        XCTAssertEqual(LeadingSpace.apply(before: "\n", to: "Hello"), "Hello")
        XCTAssertEqual(LeadingSpace.apply(before: "\r\n", to: "Hello"), "Hello")
        XCTAssertEqual(LeadingSpace.apply(before: "\u{00A0}", to: "Hello"), "Hello", "no-break space is whitespace")
        XCTAssertEqual(LeadingSpace.apply(before: "d", to: " Hello"), " Hello", "already starts with a space: once only")
        XCTAssertEqual(LeadingSpace.apply(before: "d", to: "\nHello"), "\nHello")
        XCTAssertEqual(LeadingSpace.apply(before: "d", to: ""), "")
    }

    func testNothingElseChanges() {
        XCTAssertEqual(LeadingSpace.apply(before: "x", to: "hello, world"), " hello, world")
    }
}
