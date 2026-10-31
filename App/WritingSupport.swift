import Foundation
import FreeFlowKit

/// Runs `work` on its own task and returns its result, or nil when `seconds` pass first (the task is then cancelled and
/// left to finish on its own). The caller never waits past the limit. (Kept from WritingLFM.swift, removed in build 18.)
enum Deadline {
    static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        guard seconds > 0 else { return nil }
        let first = FirstResult<T>()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            first.wait(c)
            let task = Task.detached(priority: .userInitiated) { first.finish(await work()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if first.finish(nil) { task.cancel() }
            }
        }
    }
}

private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    func wait(_ c: CheckedContinuation<T?, Never>) { lock.lock(); continuation = c; lock.unlock() }
    /// Resumes the caller with `value` if nothing did yet; true when this call did.
    @discardableResult func finish(_ value: T?) -> Bool {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}

/// The last cleanup's readout for the screen (display only: in memory, never logged, stored or sent).
@MainActor
final class WritingReadoutStore: ObservableObject {
    static let shared = WritingReadoutStore()
    @Published var last: WritingReadout?
    /// What the speech model heard for the last dictation, before the writer (shown on tap; in memory only).
    @Published var heard: String?
    /// Build 23: Apple Intelligence's version of the last dictation when it was not used because it left out words.
    @Published var notUsed: String?
}
