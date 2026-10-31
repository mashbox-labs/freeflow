import XCTest
@testable import FreeFlowKit

final class KeyboardProofTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kbproof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAWriteThatLandsIsProofEvenWhenTheFlagSaysOff() throws {
        let dir = try folder()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(KeyboardProof.record(flag: false, at: when, in: dir))
        let proof = try XCTUnwrap(KeyboardProof.read(in: dir))
        XCTAssertEqual(proof.seen, when)
        XCTAssertFalse(proof.flag)
    }

    func testNoGroupFolderMeansNoProof() {
        XCTAssertFalse(KeyboardProof.record(flag: true, in: nil))
        XCTAssertNil(KeyboardProof.read(in: nil))
    }

    func testAFolderTheKeyboardCannotWriteIsNoProof() throws {
        let dir = try folder()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        XCTAssertFalse(KeyboardProof.record(flag: true, in: dir))
        XCTAssertNil(KeyboardProof.read(in: dir))
    }

    func testClearForgetsIt() throws {
        let dir = try folder()
        XCTAssertTrue(KeyboardProof.record(flag: true, in: dir))
        KeyboardProof.clear(in: dir)
        XCTAssertNil(KeyboardProof.read(in: dir))
    }
}
