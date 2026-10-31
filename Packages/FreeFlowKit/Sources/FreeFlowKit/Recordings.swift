import Foundation

// Never lose audio. While you dictate, the audio also goes to a file in the app's own folder, a chunk at a time,
// so an X tap, a call, Siri, leaving the app, a crash or the app being killed can't lose it. The file stays on
// this device: it is left out of iCloud and device backups, and nothing in Free Flow sends it anywhere. A
// dictation that finishes deletes its file at once; one that didn't finish waits in History > Recent recordings
// (Retry, Delete) until it is deleted or reaches the age set in Settings > Privacy.

/// 16 kHz mono 16-bit PCM WAV that stays readable when it is cut off: the header's two sizes are rewritten
/// after every chunk, and the reader trusts the bytes on disk over the header.
public enum WAV {
    public static let headerBytes = 44
    public static let rate = 16_000

    public static func header(dataBytes: Int, rate: Int = rate) -> Data {
        var d = Data(capacity: headerBytes)
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        tag("RIFF"); u32(36 + dataBytes); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        tag("data"); u32(dataBytes)
        return d
    }

    static func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }

    /// Float samples (-1...1) to 16-bit little-endian PCM.
    public static func pcm16(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { pcm16($0) }
    }

    /// The same, written straight into the one Data it returns (no intermediate [Int16]).
    public static func pcm16(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                let v = max(-1, min(1, samples[i]))
                out[i] = Int16((v * 32_767).rounded()).littleEndian
            }
        }
        return data
    }

    /// The RIFF and data sizes written in the header, or nil when the file is not one of ours.
    public static func headerSizes(_ url: URL) -> (riff: Int, data: Int)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: headerBytes), d.count == headerBytes, isOurs(d) else { return nil }
        return (Int(u32(d, 4)), Int(u32(d, 40)))
    }

    /// Every whole sample on disk, whatever the header says (a file cut mid-write loses at most half a sample).
    public static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= headerBytes, isOurs(data) else { throw ClipError.notAClip }
        let n = (data.count - headerBytes) / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: headerBytes + i * 2, as: Int16.self))
                out[i] = Float(v) / 32_767
            }
        }
        return out
    }

    /// Rewrites the header from the bytes on disk and drops a trailing half sample. Returns the data bytes.
    @discardableResult
    public static func repair(_ url: URL) throws -> Int {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let size = Int(try h.seekToEnd())
        guard size >= headerBytes else { throw ClipError.notAClip }
        let body = (size - headerBytes) / 2 * 2
        if headerBytes + body != size { try h.truncate(atOffset: UInt64(headerBytes + body)) }
        try h.seek(toOffset: 0)
        try h.write(contentsOf: header(dataBytes: body))
        try h.synchronize()
        return body
    }

    private static func isOurs(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(16))
        return b.count >= 16 && b[0..<4] == [0x52, 0x49, 0x46, 0x46] && b[8..<16] == [0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20]
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        let b = [UInt8](d[d.startIndex + at ..< d.startIndex + at + 4])
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}

public enum ClipError: Error { case notAClip, cannotCreate }

/// One open recording. Chunks are written on the writer's own queue, so the audio thread never waits on the disk.
/// Each write goes straight to the file (no app-side buffer), so a killed app loses nothing already written.
public final class ClipWriter: @unchecked Sendable {
    public let id: UUID
    public let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: FF.subsystem + ".clip", qos: .userInitiated)
    private var bytes = 0          // on `queue`
    private var closed = false     // on `queue`
    private var failed = false     // on `queue`: a full disk stops the file, never the dictation
    /// Tests only: the next write fails the way a full disk does.
    var failNextWrite = false
    /// A write failed (full disk): the file stops at what was written; the dictation goes on in memory.
    public var writeFailed: Bool { queue.sync { failed } }

    init(id: UUID, url: URL, attributes: [FileAttributeKey: Any]) throws {
        let fm = FileManager.default
        // With the protection class when the platform takes it; a plain file otherwise (never lose the clip over it).
        guard fm.createFile(atPath: url.path, contents: WAV.header(dataBytes: 0), attributes: attributes)
                || fm.createFile(atPath: url.path, contents: WAV.header(dataBytes: 0)) else {
            throw ClipError.cannotCreate
        }
        self.id = id
        self.url = url
        handle = try FileHandle(forWritingTo: url)
    }

    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// From the audio thread: one Data (the 16-bit chunk, handed to the writer's queue) and one positioned write per
    /// chunk. The header's sizes are written on flush and close only: a recording killed in between is rebuilt from
    /// the bytes on disk at the next launch (ClipStore.recover, WAV.repair), and WAV.read never trusts the header.
    /// Build 9 rewrote both sizes after every chunk: three seeks and three writes per buffer.
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let data = WAV.pcm16(samples)
        queue.async { [self] in
            guard !closed, !failed else { return }
            if failNextWrite { failNextWrite = false; failed = true; return }
            let offset = off_t(WAV.headerBytes + bytes)
            let written = data.withUnsafeBytes { pwrite(handle.fileDescriptor, $0.baseAddress, $0.count, offset) }
            if written == data.count { bytes += data.count } else { failed = true }
        }
    }

    /// Tests: waits for the queued chunks without writing the header (what a kill mid-recording leaves).
    func waitForWrites() { queue.sync {} }

    private func writeSizes() throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: WAV.le32(36 + bytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: WAV.le32(bytes))
    }

    /// Waits for every queued chunk, writes the header's sizes and asks the system to put it on storage.
    public func flush() {
        queue.sync {
            guard !closed else { return }
            try? writeSizes()
            try? handle.synchronize()
        }
    }

    /// Finishes the file. Returns its length in seconds.
    @discardableResult
    public func close() -> Double {
        queue.sync {
            if !closed {
                closed = true
                try? writeSizes()
                try? handle.synchronize()
                try? handle.close()
            }
            return Double(bytes / 2) / Double(WAV.rate)
        }
    }
}

public enum ClipStatus: String, Codable, Sendable {
    /// Being written now (found at launch: the app was killed or crashed mid-recording).
    case recording
    /// Being turned into text (found at launch: the app ended before the text was written).
    case transcribing
    /// A call, Siri, another app or a lost microphone stopped it.
    case interrupted
    /// The X: the paste was cancelled, the audio kept.
    case cancelled
    /// Free Flow ended before it finished (crash, killed, out of memory).
    case unfinished
    /// The model could not turn it into text.
    case failed
    /// Build 23: made while the picked model was still being prepared. Kept, and transcribed by the model in use the
    /// moment it is ready, with no Retry needed (`reason` = that model's name).
    case waiting
    /// Turned into text from Recent recordings; the text is kept with it.
    case transcribed
}

/// Why a recording stopped, in plain words for the list.
/// Build 23 (after a wrong-language dictation that could not be retried): the LAST finished dictation's audio stays
/// on this device for 10 minutes or until the next dictation, whichever comes first, with Retry in History; then it is
/// deleted as before. `keepAudio` is the one switch.
public enum LastDictation {
    public static let keepAudio = true
    public static let keepFor: TimeInterval = 600
    /// The clip's reason while it is kept.
    public static let reason = "Your last dictation"
    public static func isExpired(_ clip: Clip, now: Date) -> Bool {
        clip.reason == reason && clip.status == .transcribed && now > clip.createdAt.addingTimeInterval(clip.seconds + keepFor)
    }
}

public enum ClipReason {
    public static let interruption = "Stopped by a call or another app"
    /// Build 23: Apple Intelligence's version left out a large share of what was said, so the text as heard was used.
    public static let writerLeftOut = "Apple Intelligence left out words, so the text as heard was used"
    public static let routeLost = "Stopped when the microphone changed"
    public static let audioReset = "Stopped when iOS restarted its audio"
    public static let cancelled = "You tapped X"
    public static let sessionEnded = "Stopped when the mic session ended"
    public static let closed = "Free Flow closed before it finished"
    public static let diskFull = "Storage full: the saved copy stopped early"
}

public struct Clip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var status: ClipStatus
    public var reason: String
    public var seconds: Double
    public var text: String?
    public var model: String?
    /// The "Transcribe it?" question was answered (Transcribe or Later), so it isn't asked again.
    public var acknowledged: Bool
    /// Why the recording stopped, kept after a Retry (reason is reused for Retry errors). nil on clips from builds before 9.
    public var stoppedBecause: String?
    /// Build 23: Apple Intelligence's version when it was not used because it left out words (the safety net).
    public var written: String?

    /// The stop reason to show: stored, or (older clips) the status line for a clip that stopped by itself.
    public var whyStopped: String? {
        if let stoppedBecause, !stoppedBecause.isEmpty { return stoppedBecause }
        switch status {
        case .interrupted, .cancelled, .unfinished: return label
        default: return nil
        }
    }

    public init(id: UUID = UUID(), createdAt: Date, status: ClipStatus, reason: String = "", seconds: Double = 0,
                text: String? = nil, model: String? = nil, acknowledged: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.status = status; self.reason = reason; self.seconds = seconds
        self.text = text; self.model = model; self.acknowledged = acknowledged
    }

    /// Every recording that isn't being recorded or transcribed right now can be transcribed (again).
    public var canRetry: Bool { status != .recording && status != .transcribing }

    /// Asked once when the app is next in front: cut off by something other than you.
    public var needsPrompt: Bool { !acknowledged && (status == .interrupted || status == .unfinished) }

    public var label: String {
        switch status {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .interrupted: return reason.isEmpty ? ClipReason.interruption : reason
        case .cancelled: return ClipReason.cancelled
        case .unfinished: return ClipReason.closed
        case .failed: return reason.isEmpty ? "Couldn't transcribe" : "Couldn't transcribe: " + reason
        case .waiting: return "Saved. Free Flow writes this when \(reason.isEmpty ? "the speech model" : reason) is ready."
        case .transcribed:
            if reason == LastDictation.reason { return "Your last dictation · audio kept 10 min" }
            return reason == ClipReason.writerLeftOut ? "Transcribed as heard" : "Transcribed"
        }
    }

    public var promptTitle: String {
        switch status {
        case .unfinished: return "Free Flow closed before your recording finished. Transcribe it?"
        default:
            let why = (reason.isEmpty ? ClipReason.interruption : reason).replacingOccurrences(of: "Stopped", with: "stopped")
            return "Recording \(why). Transcribe it?"
        }
    }

    /// 0:07, 1:42, 1:02:05
    public var duration: String {
        let s = Int(seconds.rounded())
        return s >= 3_600 ? String(format: "%d:%02d:%02d", s / 3_600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// How long recordings that didn't finish are kept. Settings > Privacy.
public enum ClipRetention: Int, CaseIterable, Identifiable, Sendable {
    case never = 0, oneDay = 1, sevenDays = 7, thirtyDays = 30

    public static let standard = ClipRetention.sevenDays
    public static let key = "clipRetentionDays"
    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .never: return "Never"
        case .oneDay: return "1 day"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        }
    }

    /// "until you delete it" or "until you delete it or it is 7 days old"
    public var until: String { self == .never ? "until you delete it" : "until you delete it or it is \(title) old" }

    public static func stored(_ value: Int?) -> ClipRetention { value.flatMap(ClipRetention.init(rawValue:)) ?? standard }

    public static var current: ClipRetention {
        get { stored(UserDefaults.standard.object(forKey: key) as? Int) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    public func isExpired(_ created: Date, now: Date) -> Bool {
        self != .never && now.timeIntervalSince(created) >= Double(rawValue) * 86_400
    }
}

/// The recordings folder: one `<id>.wav` and one `<id>.json` per clip, in the app's own Application Support
/// (never the App Group, so the keyboard can't see audio). Thread-safe; `clips` publishes on the main queue.
public final class ClipStore: ObservableObject, @unchecked Sendable {
    public static let shared = ClipStore()

    /// Readable after the first unlock, also while locked, so a dictation that runs in the background with the
    /// screen locked keeps writing (with .complete, writes fail about 10 s after the lock).
    public static let protection = FileProtectionType.completeUntilFirstUserAuthentication
    /// Shorter than this there is nothing to transcribe ("Didn't catch that"), so it isn't kept.
    public static let minimumSeconds = 0.3

    public static var fileAttributes: [FileAttributeKey: Any] { [.protectionKey: protection] }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeFlow/Recordings", isDirectory: true)
    }

    @Published public private(set) var clips: [Clip] = []
    public let folder: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var byID: [UUID: Clip] = [:]

    public init(folder: URL = ClipStore.defaultFolder, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.now = now
        if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: Self.fileAttributes)) == nil {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        Self.protect(folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let clip = try? JSONDecoder().decode(Clip.self, from: data) { byID[clip.id] = clip }
        }
        publish()
    }

    // MARK: Reading

    public func clip(_ id: UUID) -> Clip? { lock.withLock { byID[id] } }

    /// Newest first.
    public func all() -> [Clip] { lock.withLock { Array(byID.values) }.sorted { $0.createdAt > $1.createdAt } }

    /// What History > Recent recordings lists: everything except the one being recorded.
    public func recent() -> [Clip] { all().filter { $0.status != .recording } }

    public func audioURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".wav") }
    private func recordURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    public func samples(_ id: UUID) throws -> [Float] { try WAV.read(audioURL(id)) }

    // MARK: Writing

    /// Opens a new clip: the record first, so a crash right after still finds it, then the audio file.
    public func begin() throws -> ClipWriter {
        let clip = Clip(createdAt: now(), status: .recording)
        try save(clip)
        let writer = try ClipWriter(id: clip.id, url: audioURL(clip.id), attributes: Self.fileAttributes)
        Self.protect(writer.url)
        set(clip)
        return writer
    }

    /// Records how a recording ended. Too short to hold speech: deleted instead, and nil returned.
    @discardableResult
    public func close(_ id: UUID, status: ClipStatus, reason: String, seconds: Double) -> Clip? {
        guard seconds >= Self.minimumSeconds else { delete(id); return nil }
        return update(id) {
            $0.status = status; $0.reason = reason; $0.seconds = seconds
            if status == .interrupted || status == .cancelled || status == .unfinished, $0.stoppedBecause == nil {
                $0.stoppedBecause = reason.isEmpty ? $0.label : reason
            }
        }
    }

    @discardableResult
    public func update(_ id: UUID, _ change: (inout Clip) -> Void) -> Clip? {
        guard var clip = clip(id) else { return nil }
        change(&clip)
        try? save(clip)
        set(clip)
        return clip
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(id))
        try? FileManager.default.removeItem(at: recordURL(id))
        lock.withLock { byID[id] = nil }
        publish()
    }

    /// Settings > Privacy > Delete all recordings. The one being recorded right now, if any, is left alone.
    public func deleteAll(except active: UUID? = nil) {
        for clip in all() where clip.id != active { delete(clip.id) }
    }

    // MARK: Launch

    /// At launch: a clip still marked recording or transcribing belongs to a run that ended without finishing
    /// (killed, crashed, out of memory). Its header is rebuilt from the bytes on disk and it is offered for Retry.
    /// Audio files with no record (killed between the two writes) are adopted the same way.
    @discardableResult
    public func recover(active: UUID? = nil) -> [Clip] {
        var found: [Clip] = []
        let known = Set(lock.withLock { Array(byID.keys) })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in files where url.pathExtension == "wav" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !known.contains(id), id != active else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now()
            set(Clip(id: id, createdAt: created, status: .recording))
        }
        for clip in all() where clip.id != active && (clip.status == .recording || clip.status == .transcribing) {
            guard let bytes = try? WAV.repair(audioURL(clip.id)) else { delete(clip.id); continue }
            let seconds = Double(bytes / 2) / Double(WAV.rate)
            if let fixed = close(clip.id, status: .unfinished, reason: ClipReason.closed, seconds: seconds) { found.append(fixed) }
        }
        return found
    }

    /// Deletes clips older than the retention window. Returns how many went.
    @discardableResult
    public func purge(_ retention: ClipRetention, active: UUID? = nil) -> Int {
        let at = now()
        let old = all().filter { $0.id != active && $0.status != .recording
            && (retention.isExpired($0.createdAt, now: at) || LastDictation.isExpired($0, now: at)) }
        old.forEach { delete($0.id) }
        return old.count
    }

    // MARK: Files

    private func save(_ clip: Clip) throws {
        let url = recordURL(clip.id)
        let data = try JSONEncoder().encode(clip)
        do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } catch { try data.write(to: url, options: .atomic) }
        Self.protect(url)
    }

    private func set(_ clip: Clip) {
        lock.withLock { byID[clip.id] = clip }
        publish()
    }

    /// Left out of iCloud and device backups, protection class set explicitly.
    static func protect(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        try? FileManager.default.setAttributes(fileAttributes, ofItemAtPath: url.path)
    }

    private func publish() {
        if Thread.isMainThread { clips = recent() } else { DispatchQueue.main.async { self.clips = self.recent() } }
    }
}
