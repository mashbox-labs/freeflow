import Foundation
import XCTest
@testable import FreeFlowKit

/// A stand-in for the keyboard's text document proxy, as iOS hands it over (Objective-C, identifier may be nil).
private final class FakeProxy: NSObject {
    @objc dynamic var documentIdentifier: NSUUID?
    init(_ id: NSUUID?) { documentIdentifier = id }
}

final class FieldIdentityTests: XCTestCase {
    func testNilIdentifierIsNoFieldAndDoesNotTrap() {
        XCTAssertNil(FieldIdentity.read(FakeProxy(nil)))
    }

    func testIdentifierIsRead() {
        let id = UUID()
        XCTAssertEqual(FieldIdentity.read(FakeProxy(id as NSUUID)), id)
    }

    func testObjectWithoutTheGetterIsNoField() {
        XCTAssertNil(FieldIdentity.read(NSObject()))
    }
}
