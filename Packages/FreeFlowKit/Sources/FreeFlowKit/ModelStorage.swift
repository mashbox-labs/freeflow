import Foundation

/// Free space on this device, as the Models page shows it.
public struct DiskSpace: Equatable, Sendable {
    /// What iOS will make room for when the user asks for it (volumeAvailableCapacityForImportantUsage): the number
    /// Settings > General > Storage is closest to.
    public let freeBytes: Int64
    /// The volume's size; 0 when iOS does not say.
    public let totalBytes: Int64
    /// True when a UI test set the free space (simulator only, FF_SIM_FREE_DISK_GB) to stand for a full device.
    public let fromTest: Bool

    public init(freeBytes: Int64, totalBytes: Int64, fromTest: Bool = false) {
        self.freeBytes = freeBytes; self.totalBytes = totalBytes; self.fromTest = fromTest
    }

    /// This device now. In the simulator FF_SIM_FREE_DISK_GB (decimal GB) replaces the Mac's free space, so a test can
    /// show the page as a nearly full iPad sees it (a test iPad had 6.75 GB free of 128 GB on 2026-10-29).
    public static func current() -> DiskSpace {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        #if targetEnvironment(simulator)
        if let gb = ProcessInfo.processInfo.environment["FF_SIM_FREE_DISK_GB"].flatMap(Double.init), gb >= 0 {
            let totalGB = ProcessInfo.processInfo.environment["FF_SIM_TOTAL_DISK_GB"].flatMap(Double.init) ?? 128
            return DiskSpace(freeBytes: Int64(gb * 1e9), totalBytes: Int64(totalGB * 1e9), fromTest: true)
        }
        #endif
        return DiskSpace(freeBytes: free, totalBytes: total)
    }

    /// "6.75 GB" (decimal, like iOS Settings): two decimals under 10 GB, one under 100, none above; MB under 1 GB.
    public static func format(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        if b < 1e9 { return String(format: "%.0f MB", b / 1e6) }
        let gb = b / 1e9
        if gb < 10 { return String(format: "%.2f GB", gb) }
        if gb < 100 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f GB", gb)
    }

    public var freeLine: String {
        totalBytes > 0 ? "\(Self.format(freeBytes)) free of \(Self.format(totalBytes))" : "\(Self.format(freeBytes)) free"
    }
}

/// Whether a download fits, and whether it would leave the device too full. Real users run near full (a test iPad:
/// 6.75 GB free of 128 GB), so Free Flow says so before it starts, never after a failed download.
public enum DiskBudget {
    /// Below this much free space after a download, Free Flow asks first.
    public static let reserveBytes: Int64 = 1_500_000_000
    /// Room a download needs beyond its own files (the file being written, checks), as the app has required since build 1.
    public static let workBytes: Int64 = 200_000_000

    public enum Check: Equatable, Sendable {
        /// Fits and leaves at least the reserve.
        case fine(leftBytes: Int64)
        /// Fits, but leaves less than the reserve: ask before starting.
        case tight(leftBytes: Int64)
        /// Does not fit at all: no download.
        case noRoom(needBytes: Int64, freeBytes: Int64)
    }

    /// `stagedBytes` = files of this model already downloaded and checked by an earlier, interrupted try (they are kept).
    public static func check(downloadBytes: Int64, freeBytes: Int64, stagedBytes: Int64 = 0) -> Check {
        let need = max(0, downloadBytes - stagedBytes)
        if freeBytes < need + workBytes { return .noRoom(needBytes: need + workBytes, freeBytes: freeBytes) }
        let left = freeBytes - need
        return left < reserveBytes ? .tight(leftBytes: left) : .fine(leftBytes: left)
    }

    /// The line on a model's card, or nil when the download leaves plenty of room.
    public static func warning(_ check: Check, device: String) -> String? {
        switch check {
        case .fine:
            return nil
        case .tight(let left):
            return "Leaves \(DiskSpace.format(left)) free on this \(device). We suggest keeping at least \(DiskSpace.format(reserveBytes)) free."
        case .noRoom(let need, let free):
            return "Needs \(DiskSpace.format(need)) free. This \(device) has \(DiskSpace.format(free)). Delete a model or free up space first."
        }
    }
}

/// Downloads and checks a model's files, then puts them in place in one step. Nothing touches a model's folder until
/// every file of every part has arrived and matched its sha256, so a failed, cancelled or partial download never
/// changes the model in use (or an older copy of the same model). Files that did arrive and match stay in a
/// ".partial" folder beside the model, and the next try skips them.
public enum ModelInstaller {
    public struct FileEntry: Sendable {
        public let path: String
        public let sha256: String
        public let size: Int64
        public init(path: String, sha256: String, size: Int64) { self.path = path; self.sha256 = sha256; self.size = size }
    }

    /// One folder's worth of files (the model, or its tokenizer).
    public struct Part: Sendable {
        public let directory: URL
        public let files: [FileEntry]
        /// Where each file comes from (path inside the part -> URL).
        public let source: @Sendable (String) -> URL?
        public init(directory: URL, files: [FileEntry], source: @escaping @Sendable (String) -> URL?) {
            self.directory = directory; self.files = files.sorted { $0.path < $1.path }; self.source = source
        }
        public var staging: URL { directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".partial") }
    }

    public struct InstallError: Error, LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Bytes already downloaded for these parts (files in their .partial folders). With `hash`, only files that match
    /// their sha256 count; without, files of the right size (cheap, for the free-space check; install() still checks).
    public static func stagedBytes(_ parts: [Part], hash: ((URL) throws -> String)?) -> Int64 {
        var n: Int64 = 0
        for part in parts {
            for f in part.files {
                let url = part.staging.appendingPathComponent(f.path)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                      size.int64Value == f.size else { continue }
                if let hash, (try? hash(url)) != f.sha256 { continue }
                n += f.size
            }
        }
        return n
    }

    /// `fetch(source, destination)` writes one file to `destination` (replacing it); `progress(bytesDone)` is called as
    /// files complete and with `fetch`'s own partial counts through `partial`.
    public static func install(_ parts: [Part],
                               fetch: (URL, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void,
                               hash: @escaping @Sendable (URL) throws -> String,
                               progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        var done: Int64 = 0
        // 1. Every file of every part into its .partial folder, each checked against its sha256.
        for part in parts {
            for f in part.files {
                let destination = part.staging.appendingPathComponent(f.path)
                if fm.fileExists(atPath: destination.path), (try? hash(destination)) == f.sha256 {
                    done += f.size
                    progress(done)
                    continue
                }
                guard let url = part.source(f.path) else { throw InstallError("Bad file name \(f.path)") }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = done
                try await fetch(url, destination) { written in progress(base + written) }
                let got = try await Task.detached(priority: .userInitiated) { try hash(destination) }.value
                guard got == f.sha256 else {
                    try? fm.removeItem(at: destination)
                    throw InstallError("Checksum mismatch in \(f.path). Nothing was installed.")
                }
                done += f.size
                progress(done)
            }
        }
        // 2. All parts are complete and checked: swap each into place, keeping the old copy until the new one is there.
        for part in parts {
            try fm.createDirectory(at: part.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = part.directory.deletingLastPathComponent().appendingPathComponent(part.directory.lastPathComponent + ".old")
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
            let hadOld = fm.fileExists(atPath: part.directory.path)
            if hadOld { try fm.moveItem(at: part.directory, to: old) }
            do {
                try fm.moveItem(at: part.staging, to: part.directory)
            } catch {
                if hadOld { try? fm.moveItem(at: old, to: part.directory) }
                throw error
            }
            if hadOld { try? fm.removeItem(at: old) }
            var url = part.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
