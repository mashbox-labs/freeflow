import CryptoKit
import XCTest
@testable import FreeFlowKit

/// Low disk and safe installs: the warning before a download that would leave the device nearly full, and a failed
/// or partial download never touching the model in use (or an older copy of the same model).
final class ModelStorageTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Disk budget

    /// A nearly full iPad on 2026-10-29: 6.75 GB free of 128 GB.
    func testWarningOnNearlyFullIPad() {
        let free = Int64(6.75 * 1e9)
        // Parakeet Q4_0 (356 MB): plenty left.
        XCTAssertEqual(DiskBudget.check(downloadBytes: 355_615_679, freeBytes: free), .fine(leftBytes: free - 355_615_679))
        // A model that would leave 1.4 GB: ask first.
        let big = free - Int64(1.4 * 1e9)
        guard case .tight(let left) = DiskBudget.check(downloadBytes: big, freeBytes: free) else { return XCTFail("expected tight") }
        XCTAssertEqual(left, Int64(1.4 * 1e9))
        XCTAssertEqual(DiskBudget.warning(.tight(leftBytes: left), device: "iPad"),
                       "Leaves 1.40 GB free on this iPad. We suggest keeping at least 1.50 GB free.")
        XCTAssertNil(DiskBudget.warning(.fine(leftBytes: 5 * gb), device: "iPad"))
    }

    func testReserveBoundary() {
        // Leaves exactly 1.5 GB: fine. One byte more download: tight.
        XCTAssertEqual(DiskBudget.check(downloadBytes: gb, freeBytes: gb + DiskBudget.reserveBytes), .fine(leftBytes: DiskBudget.reserveBytes))
        XCTAssertEqual(DiskBudget.check(downloadBytes: gb + 1, freeBytes: gb + DiskBudget.reserveBytes),
                       .tight(leftBytes: DiskBudget.reserveBytes - 1))
    }

    func testNoRoomAtAll() {
        // 1.39 GB LFM3 on a device with 1.4 GB free: the files and the 200 MB working room do not fit.
        let check = DiskBudget.check(downloadBytes: 1_387_475_936, freeBytes: Int64(1.4 * 1e9))
        XCTAssertEqual(check, .noRoom(needBytes: 1_387_475_936 + DiskBudget.workBytes, freeBytes: Int64(1.4 * 1e9)))
        XCTAssertEqual(DiskBudget.warning(check, device: "iPhone"),
                       "Needs 1.59 GB free. This iPhone has 1.40 GB. Delete a model or free up space first.")
    }

    /// Files an interrupted try already downloaded and checked count as done.
    func testStagedBytesCount() {
        XCTAssertEqual(DiskBudget.check(downloadBytes: 2 * gb, freeBytes: 2 * gb, stagedBytes: 0),
                       .noRoom(needBytes: 2 * gb + DiskBudget.workBytes, freeBytes: 2 * gb))
        // 1.9 GB already here: 100 MB to go, 1.9 GB left.
        XCTAssertEqual(DiskBudget.check(downloadBytes: 2 * gb, freeBytes: 2 * gb, stagedBytes: Int64(1.9 * 1e9)),
                       .fine(leftBytes: Int64(1.9 * 1e9)))
        XCTAssertEqual(DiskBudget.check(downloadBytes: 2 * gb, freeBytes: Int64(1.6 * 1e9), stagedBytes: gb),
                       .tight(leftBytes: Int64(0.6 * 1e9)))
    }

    func testFormat() {
        XCTAssertEqual(DiskSpace.format(355_615_679), "356 MB")
        XCTAssertEqual(DiskSpace.format(Int64(6.75 * 1e9)), "6.75 GB")
        XCTAssertEqual(DiskSpace.format(Int64(58.6 * 1e9)), "58.6 GB")
        XCTAssertEqual(DiskSpace.format(128 * gb), "128 GB")
        XCTAssertEqual(DiskSpace(freeBytes: Int64(6.75 * 1e9), totalBytes: 128 * gb).freeLine, "6.75 GB free of 128 GB")
    }

    // MARK: Installs

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func shaFile(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A model folder on disk with its files, like one already downloaded and in use.
    private func makeInstalled(_ name: String, files: [String: String]) throws -> URL {
        let dir = root.appendingPathComponent(name + "/model")
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return dir
    }

    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = dir.resolvingSymlinksInPath().path
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in e where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return out
    }

    /// Serves files from memory; fails (like a dropped connection or a full disk) on the named file.
    private final class FakeServer: @unchecked Sendable {
        var bodies: [String: Data]
        var failOn: Set<String>
        var fetched: [String] = []
        init(_ bodies: [String: Data], failOn: Set<String> = []) { self.bodies = bodies; self.failOn = failOn }
        func fetch(_ url: URL, _ destination: URL, _ partial: @escaping @Sendable (Int64) -> Void) async throws {
            let name = url.lastPathComponent
            fetched.append(name)
            guard let body = bodies[name] else { throw URLError(.fileDoesNotExist) }
            if failOn.contains(name) {
                // Half the file arrives, then the transfer fails; a URLSession download never moves a half file into place.
                partial(Int64(body.count / 2))
                throw URLError(.networkConnectionLost)
            }
            try body.write(to: destination)
            partial(Int64(body.count))
        }
    }

    private func part(_ dir: URL, _ bodies: [String: Data]) -> ModelInstaller.Part {
        ModelInstaller.Part(directory: dir,
                            files: bodies.map { ModelInstaller.FileEntry(path: $0.key, sha256: sha($0.value), size: Int64($0.value.count)) },
                            source: { URL(string: "https://example.invalid/\($0)") })
    }

    private func install(_ parts: [ModelInstaller.Part], _ server: FakeServer) async throws {
        try await ModelInstaller.install(parts, fetch: { try await server.fetch($0, $1, $2) },
                                         hash: { try Self.shaFile($0) }, progress: { _ in })
    }

    /// The in-use model stays byte-for-byte the same when another model's download fails halfway.
    func testFailedDownloadLeavesActiveModelUntouched() async throws {
        let active = try makeInstalled("medium", files: ["Encoder.mlmodelc/weights/weight.bin": "active weights", "vocab.json": "{}"])
        let before = try snapshot(active)
        let other = root.appendingPathComponent("parakeet-gguf-q4_0/model")
        let bodies = ["a.bin": Data(repeating: 1, count: 1000), "b.bin": Data(repeating: 2, count: 1000)]
        let server = FakeServer(bodies, failOn: ["b.bin"])
        do {
            try await install([part(other, bodies)], server)
            XCTFail("the install should fail")
        } catch {}
        XCTAssertEqual(try snapshot(active), before, "the model in use changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path), "a half-downloaded model was put in place")
        // The file that did arrive and match is kept for the next try; the failed one is not.
        let staging = root.appendingPathComponent("parakeet-gguf-q4_0/model.partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("a.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("b.bin").path))
    }

    /// A bad checksum installs nothing and keeps the older copy of the same model.
    func testChecksumMismatchKeepsOlderCopy() async throws {
        let dir = try makeInstalled("small", files: ["AudioEncoder.mlmodelc/weight.bin": "old good copy"])
        let before = try snapshot(dir)
        let good = ["AudioEncoder.mlmodelc/weight.bin": Data("new copy".utf8)]
        let p = part(dir, good)
        let server = FakeServer(["weight.bin": Data("tampered".utf8)])
        do {
            try await install([p], server)
            XCTFail("a mismatched file must fail the install")
        } catch let e as ModelInstaller.InstallError {
            XCTAssertEqual(e.message, "Checksum mismatch in AudioEncoder.mlmodelc/weight.bin. Nothing was installed.")
        }
        XCTAssertEqual(try snapshot(dir), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.staging.appendingPathComponent("AudioEncoder.mlmodelc/weight.bin").path),
                       "the mismatched file was kept")
    }

    /// The tokenizer part failing after the model part arrived installs neither: no half model in place.
    func testTwoPartsInstallTogetherOrNotAtAll() async throws {
        let model = root.appendingPathComponent("whisper-tiny/model")
        let tok = root.appendingPathComponent("whisper-tiny/tokenizer")
        let server = FakeServer(["m.bin": Data(repeating: 7, count: 64), "tokenizer.json": Data("{}".utf8)], failOn: ["tokenizer.json"])
        do {
            try await install([part(model, ["m.bin": Data(repeating: 7, count: 64)]),
                               part(tok, ["tokenizer.json": Data("{}".utf8)])], server)
            XCTFail("should fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tok.path))
    }

    /// After a failure the next try fetches only what is missing, then puts everything in place.
    func testRetryResumesAndInstalls() async throws {
        let dir = root.appendingPathComponent("parakeet-gguf-q4_k/model")
        let bodies = ["a.bin": Data(repeating: 1, count: 300), "b.bin": Data(repeating: 2, count: 500)]
        let p = part(dir, bodies)
        let first = FakeServer(bodies, failOn: ["b.bin"])
        do { try await install([p], first); XCTFail("should fail") } catch {}
        XCTAssertEqual(ModelInstaller.stagedBytes([p], hash: { try Self.shaFile($0) }), 300)
        let second = FakeServer(bodies)
        try await install([p], second)
        XCTAssertEqual(second.fetched, ["b.bin"], "a.bin was already there and checked")
        XCTAssertEqual(try snapshot(dir), ["/a.bin": bodies["a.bin"]!, "/b.bin": bodies["b.bin"]!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.staging.path))
    }
}
