import Foundation

/// Speech model loads, one per model. A caller asking for a model that is already loading waits for that same load.
/// A caller asking for a different model starts its load at once and becomes the model wanted (the pick); a load that
/// ends after a newer pick asks `isWanted` and lets its model go instead of putting it in use.
///
/// Why: the first launch after an app update, Core ML prepares the model again for the new build, so loading takes
/// much longer than usual, and parallel loads of the same model made it slower still (build 18: one load per model).
/// Build 22 (seen on an iPhone on build 19): a different model no longer waited for the running load.
/// Build 23 (seen on a Mac: two models preparing at the same time): ONE load at a time again. Core ML
/// cannot stop a Neural Engine prepare once it has started, so two at once means two models in memory and two prepares
/// sharing the Neural Engine. A different model now waits for the load in flight; that load, no longer the pick, lets
/// its model go (Transcriber), and only then does the next one start. A caller that is no longer the pick when its turn
/// comes is told so (`isWanted`) and loads nothing. Recordings made meanwhile are kept for the pick (DictationEngine).
public actor LoadGate {
    /// Build 24 (seen on an iPad: Ultra's prepare at 1862 s and Bark stuck behind it): a load can be given a limit
    /// (`expired`, asked every half second while it runs). Core ML cannot stop a Neural Engine prepare, so a load past
    /// its limit is abandoned: it leaves the gate (the next load starts), its caller gets TimedOut, and whatever it
    /// builds later is let go (`isLive`). `abandon` does the same on request (Abandoned), for a load that iOS
    /// suspended in the background.
    public struct TimedOut: Error, Equatable { public let id: String; public init(id: String) { self.id = id } }
    public struct Abandoned: Error, Equatable { public let id: String; public init(id: String) { self.id = id } }

    private var running: [String: Task<Double, Error>] = [:]
    private var tokens: [String: Int] = [:]
    private var dropped: Set<Int> = []
    /// The model picked last. A load of any other model that ends after this pick lets its model go.
    public private(set) var wanted: String?
    public private(set) var started = 0

    public init() {}

    /// Runs `load` for `id` unless a load of `id` is already running, in which case it waits for that one. With `want`
    /// (a pick) `id` becomes the model wanted; without it (the one-time build after a download) nothing changes.
    public func run(_ id: String, want: Bool = true, _ load: @escaping @Sendable () async throws -> Double) async throws -> Double {
        try await run(id, want: want, expired: nil) { _ in try await load() }
    }

    /// The same, with a limit and the load's token (`isLive(token)` is false once the load was abandoned).
    public func run(_ id: String, want: Bool = true, expired: (@Sendable () async -> Bool)?,
                    _ load: @escaping @Sendable (Int) async throws -> Double) async throws -> Double {
        if want { wanted = id }
        if let task = running[id], let token = tokens[id] { return try await watch(task, id: id, token: token, expired: expired) }
        // Wait for the load in flight (any model) to end or be abandoned. Others may queue too: re-check after each.
        while let (otherID, other) = running.first {
            await ended(other, id: otherID)
            if running[otherID] == other { running[otherID] = nil; tokens[otherID] = nil }
            if let task = running[id], let token = tokens[id] { return try await watch(task, id: id, token: token, expired: expired) }
        }
        started += 1
        let token = started
        let task = Task { try await load(token) }
        running[id] = task
        tokens[id] = token
        mostAtOnce = max(mostAtOnce, running.count)
        defer { if running[id] == task { running[id] = nil; tokens[id] = nil } }
        return try await watch(task, id: id, token: token, expired: expired)
    }

    /// False once the load with this token was abandoned (timed out or on request): it must not put its model in use.
    public func isLive(_ token: Int) -> Bool { !dropped.contains(token) }

    /// Abandons the load of `id` in flight, if any: its caller gets Abandoned and the next load may start.
    public func abandon(_ id: String) {
        guard let token = tokens[id] else { return }
        dropped.insert(token)
        running[id] = nil
        tokens[id] = nil
    }

    private func timedOut(_ id: String, _ token: Int) {
        if tokens[id] == token { abandon(id) } else { dropped.insert(token) }
    }

    /// The load's result, unless it is abandoned or passes its limit first.
    private func watch(_ task: Task<Double, Error>, id: String, token: Int, expired: (@Sendable () async -> Bool)?) async throws -> Double {
        let once = Once<Double>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            once.set(continuation)
            Task {
                do { once.resume(.success(try await task.value)) } catch { once.resume(.failure(error)) }
            }
            Task { [weak self] in
                while !once.done {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !once.done else { return }
                    if await !self.isLive(token) { once.resume(.failure(Abandoned(id: id))); return }
                    if let expired, await expired() {
                        await self.timedOut(id, token)
                        once.resume(.failure(TimedOut(id: id)))
                        return
                    }
                }
            }
        }
    }

    /// Returns when `task` has ended or left the gate (abandoned).
    private func ended(_ task: Task<Double, Error>, id: String) async {
        let once = Once<Double>()
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            once.set(continuation)
            Task { _ = try? await task.value; once.resume(.success(0)) }
            Task { [weak self] in
                while !once.done {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self else { return }
                    if await self.running[id] != task { once.resume(.success(0)); return }
                }
            }
        }
    }

    /// The model already in use is the pick again (loads of others in flight let theirs go).
    public func want(_ id: String) { wanted = id }

    public func isWanted(_ id: String) -> Bool { wanted == id }

    /// The most loads that were ever in flight at once (build 23: always 1).
    public private(set) var mostAtOnce = 0

    /// Models with a load in flight.
    public var inFlight: [String] { running.keys.sorted() }
}

/// A continuation resumed once, by whichever of its racers ends first.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func set(_ c: CheckedContinuation<T, Error>) { lock.lock(); continuation = c; lock.unlock() }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished, let c = continuation else { lock.unlock(); return }
        finished = true; continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}
