import CryptoKit
import FluidAudio
import FreeFlowKit
import Foundation

/// One pinned model in App/Resources/model-manifest.json (the same file the iPhone app ships).
struct ManifestModel: Decodable {
    struct File: Decodable { let sha256: String; let size: Int64 }
    let repo: String
    let subfolder: String
    let revision: String
    let bytes: Int64
    let files: [String: File]
}

/// The Mac app's speech model, downloaded and checked exactly as on iPhone (ModelInstaller: every file against the sha256
/// pinned in this build, at a pinned Hugging Face commit, put in place only when all of them match): Parakeet TDT 0.6B v3
/// on Core ML (FluidAudio), the iPhone app's default ("medium"). Writing is Apple's on-device model (MacWriter), which
/// macOS provides; build 18 has no writing model to download.
@MainActor
final class MacModels: ObservableObject {
    static let shared = MacModels()
    nonisolated static let speechID = "medium"

    enum Status: Equatable { case notDownloaded, downloading(Double), ready, failed(String) }

    @Published private(set) var status: [String: Status] = [:]
    let manifest: [String: ManifestModel]

    init() {
        let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json")
        manifest = url.flatMap { try? JSONDecoder().decode([String: ManifestModel].self, from: Data(contentsOf: $0)) } ?? [:]
        refresh()
    }

    /// ~/Library/Application Support/Free Flow/Models. Parakeet stays where FluidAudio loads it from.
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Free Flow/Models")
    }

    nonisolated static func directory(_ id: String) -> URL {
        id == speechID ? AsrModels.defaultCacheDirectory(for: .v3) : root.appendingPathComponent(id + "/model")
    }

    var speechReady: Bool { status[Self.speechID] == .ready }

    func bytes(_ id: String) -> Int64 { manifest[id]?.bytes ?? 0 }

    func refresh() {
        for id in [Self.speechID] {
            if case .downloading = status[id] { continue }
            let present = FileManager.default.fileExists(atPath: Self.directory(id).path)
            let verified = UserDefaults.standard.string(forKey: "verified.\(id)")
            status[id] = (present && verified != nil && verified == manifest[id]?.revision) ? .ready : .notDownloaded
        }
    }

    /// Marks a model checked without the download (the self-test, after it hashed every file itself).
    func markChecked(_ id: String) { status[id] = .ready }

    func parts(_ id: String) -> [ModelInstaller.Part] {
        guard let entry = manifest[id] else { return [] }
        let repo = entry.repo, revision = entry.revision
        let prefix = entry.subfolder.isEmpty ? "" : entry.subfolder + "/"
        return [ModelInstaller.Part(
            directory: Self.directory(id),
            files: entry.files.map { ModelInstaller.FileEntry(path: $0.key, sha256: $0.value.sha256, size: $0.value.size) },
            source: { path in
                let encoded = (prefix + path).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(encoded)")
            })]
    }

    @discardableResult
    func download(_ id: String) async -> Bool {
        guard let revision = manifest[id]?.revision else { status[id] = .failed("Not in this build."); return false }
        if case .downloading = status[id] { return false }
        let total = max(bytes(id), 1)
        let free = DiskSpace.current().freeBytes
        if free > 0, free < total + 1_000_000_000 {
            status[id] = .failed("Not enough free space: this needs \(Self.size(total)) plus 1 GB to spare.")
            return false
        }
        status[id] = .downloading(0)
        do {
            try await ModelInstaller.install(parts(id), fetch: { url, destination, written in
                try await FileDownloader().download(url, to: destination, progress: written)
            }, hash: { try MacModels.sha256(of: $0) }, progress: { done in
                Task { @MainActor in
                    if case .downloading = self.status[id] { self.status[id] = .downloading(min(1, Double(done) / Double(total))) }
                }
            })
            UserDefaults.standard.set(revision, forKey: "verified.\(id)")
            status[id] = .ready
            // Parakeet's first load compiles it for this machine's Neural Engine, which takes a while once (later loads are
            // quick): start it now, so the first dictation after setup doesn't wait for it.
            if id == Self.speechID { Task.detached(priority: .utility) { try? await MacTranscriber.shared.load() } }
            return true
        } catch {
            status[id] = .failed(error.localizedDescription)
            return false
        }
    }

    /// Every file of a model against its pinned sha256 (the self-test). nil = all match.
    nonisolated static func check(_ id: String, manifest: [String: ManifestModel]) -> String? {
        guard let entry = manifest[id] else { return "\(id) is not in the manifest" }
        let dir = directory(id)
        for (path, file) in entry.files.sorted(by: { $0.key < $1.key }) {
            let url = dir.appendingPathComponent(path)
            guard let got = try? sha256(of: url) else { return "\(path) missing" }
            if got != file.sha256 { return "\(path) sha256 mismatch" }
        }
        return nil
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.2f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}

/// One file download with byte progress; moves the file into place before returning.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: ((Int64) -> Void)?
    private var destination: URL!
    private var session: URLSession?

    func download(_ url: URL, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        self.destination = destination
        self.progress = progress
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(FFError("Download failed (HTTP \(http.statusCode)).")); return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch { finish(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
