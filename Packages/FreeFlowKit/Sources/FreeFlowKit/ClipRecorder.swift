import Foundation
#if os(iOS)
import AVFAudio
#endif

/// The audio-session notifications iOS posts, by name (macOS, where the unit tests also run, has no AVAudioSession).
public enum AudioSessionNote {
    #if os(iOS)
    public static let interruption = AVAudioSession.interruptionNotification
    public static let routeChange = AVAudioSession.routeChangeNotification
    public static let mediaReset = AVAudioSession.mediaServicesWereResetNotification
    public static let mediaLost = AVAudioSession.mediaServicesWereLostNotification
    public static let typeKey = AVAudioSessionInterruptionTypeKey
    public static let optionKey = AVAudioSessionInterruptionOptionKey
    #else
    public static let interruption = Notification.Name("AVAudioSessionInterruptionNotification")
    public static let routeChange = Notification.Name("AVAudioSessionRouteChangeNotification")
    public static let mediaReset = Notification.Name("AVAudioSessionMediaServicesWereResetNotification")
    public static let mediaLost = Notification.Name("AVAudioSessionMediaServicesWereLostNotification")
    public static let typeKey = "AVAudioSessionInterruptionTypeKey"
    public static let optionKey = "AVAudioSessionInterruptionOptionKey"
    #endif
    /// AVAudioSession.InterruptionType.began / .ended and InterruptionOptions.shouldResume raw values.
    public static let began: UInt = 1
    public static let ended: UInt = 0
    public static let shouldResume: UInt = 1
}

/// Writes the dictation in progress to a clip and closes it cleanly when something else takes the audio.
/// It listens to the notifications itself, on the thread that posts them, so the clip is closed the moment
/// a call starts, before anything else reacts, and the audio up to the call is kept.
public final class ClipRecorder: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        /// A clip was closed and kept, with how it ended.
        case saved(UUID, ClipStatus)
        /// The call (or Siri, or the other app) is over. `saved` is the clip it cut off, if one was recording.
        case interruptionEnded(saved: UUID?, shouldResume: Bool)
    }

    public let store: ClipStore
    /// Called on the main queue.
    public var onEvent: ((Event) -> Void)?
    private let center: NotificationCenter
    private let lock = NSLock()
    private var writer: ClipWriter?
    private var cutOff: UUID?
    private var tokens: [NSObjectProtocol] = []

    public init(store: ClipStore = .shared, center: NotificationCenter = .default) {
        self.store = store
        self.center = center
        tokens = [
            center.addObserver(forName: AudioSessionNote.interruption, object: nil, queue: nil) { [weak self] in self?.interruption($0) },
            // AirPods in or out: same clip, but put what we have on storage now.
            center.addObserver(forName: AudioSessionNote.routeChange, object: nil, queue: nil) { [weak self] _ in self?.flush() },
            center.addObserver(forName: AudioSessionNote.mediaReset, object: nil, queue: nil) { [weak self] _ in
                _ = self?.stop(.interrupted, reason: ClipReason.audioReset)
            },
            center.addObserver(forName: AudioSessionNote.mediaLost, object: nil, queue: nil) { [weak self] _ in
                _ = self?.stop(.interrupted, reason: ClipReason.audioReset)
            },
        ]
    }

    deinit { for t in tokens { center.removeObserver(t) } }

    /// The clip being recorded, if any.
    public var activeID: UUID? { lock.withLock { writer?.id } }

    /// Opens a new clip. Nil when storage refuses (full disk): the dictation still works from memory.
    @discardableResult
    public func start() -> UUID? {
        stop(.unfinished, reason: ClipReason.closed)
        guard let w = try? store.begin() else { return nil }
        lock.withLock { writer = w }
        return w.id
    }

    /// From the audio thread: queued to the writer, never waits on the disk.
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLock { writer }?.append(samples)
    }

    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    public func flush() {
        lock.withLock { writer }?.flush()
    }

    /// Closes the open clip with how it ended. Nil when nothing was open or it was too short to keep.
    @discardableResult
    public func stop(_ status: ClipStatus, reason: String = "") -> Clip? {
        let w: ClipWriter? = lock.withLock { defer { writer = nil }; return writer }
        guard let w else { return nil }
        let full = w.writeFailed
        let seconds = w.close()
        // A full disk stopped the saved copy early: that is why this clip is short (the dictation itself went on).
        if full { store.update(w.id) { $0.stoppedBecause = ClipReason.diskFull } }
        guard let clip = store.close(w.id, status: status, reason: reason, seconds: seconds) else { return nil }
        if status != .transcribing { emit(.saved(clip.id, clip.status)) }
        return clip
    }

    private func interruption(_ note: Notification) {
        let type = (note.userInfo?[AudioSessionNote.typeKey] as? NSNumber)?.uintValue
        let options = (note.userInfo?[AudioSessionNote.optionKey] as? NSNumber)?.uintValue ?? 0
        if type == AudioSessionNote.began {
            if let clip = stop(.interrupted, reason: ClipReason.interruption) { lock.withLock { cutOff = clip.id } }
        } else if type == AudioSessionNote.ended {
            let saved: UUID? = lock.withLock { defer { cutOff = nil }; return cutOff }
            emit(.interruptionEnded(saved: saved, shouldResume: options & AudioSessionNote.shouldResume != 0))
        }
    }

    private func emit(_ event: Event) {
        if Thread.isMainThread { onEvent?(event) } else { DispatchQueue.main.async { self.onEvent?(event) } }
    }
}
