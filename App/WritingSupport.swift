import Foundation
import FreeFlowKit
import UIKit

// Deadline moved to FreeFlowKit (AppleRewrite.swift) so the keyboard can use it.

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

/// Build 33: the slow-cleanup question (CleanupSpeed), shown in the app only while it is in front; a slow
/// run recorded in the background is asked about the next time Free Flow is opened. Its own small object, so the
/// root view does not observe the engine.
@MainActor
final class CleanupAsk: ObservableObject {
    static let shared = CleanupAsk()
    @Published var asking = false

    func check() {
        guard !asking, UIApplication.shared.applicationState == .active else { return }
        if CleanupSpeed.takeAsk(cleanupOn: WriterChoice.resolved != .off) { asking = true }
    }

    /// "Turn off cleanup" flips the same setting as Settings > Writing > Clean up with Apple Intelligence.
    func answer(turnOff: Bool) {
        if turnOff { WriterChoice.stored = .off }
        asking = false
    }
}

#if canImport(FoundationModels)
import FoundationModels
import UIKit

/// Background-writing measurement, off unless the app is launched with -ffBgProbe (Xcode or devicectl; never in normal use).
/// Once per process, the first time the app goes to the background, it calls Apple's model on a fixed transcript and
/// records every call: A) back to back (3 s apart) until Apple says rateLimited, then 2 more; B) one call each after
/// waiting 15, 30, 60, 120 and 240 s; C) one call per 20 s for the rest of the session. Each call is a new session and
/// one request, like one dictation piece. -ffBgProbeLong uses a 115-word transcript instead of 22 words (a token
/// budget would trip sooner). Lines go to the log (FFPROBE) and to bgprobe-<time>.jsonl in the App Group container.
/// The app stays alive in the background only while its mic session runs: start one before leaving the app.
@available(iOS 26.0, *)
@MainActor
enum BackgroundProbe {
    private static var started = false
    /// The launch argument, or the one-shot switch in Settings > Test build (TestFlight builds have no launch arguments).
    static let armKey = "bgprobe.armed"
    static var armed: Bool { ProcessInfo.processInfo.arguments.contains("-ffBgProbe") || UserDefaults.standard.bool(forKey: armKey) }

    static func install() {
        NSLog("FFPROBE installed; armed=%d", armed ? 1 : 0)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in start() }
        }
    }

    static let short = "so um I wanted to say that the meeting is moved to Thursday, no wait, Friday at ten and uh bring the slides"
    static let long = Array(repeating: "so um I think we should move the launch to next week because the build is not ready and uh the tests are still failing on the iPad,", count: 5).joined(separator: " ")

    private static func start() {
        guard !started, armed else { return }
        started = true
        UserDefaults.standard.set(false, forKey: armKey)   // one run per arming
        let text = ProcessInfo.processInfo.arguments.contains("-ffBgProbeLong") ? long : short
        let url = FF.containerURL.appendingPathComponent("bgprobe-\(Int(Date().timeIntervalSince1970)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let t0 = Date()
        Task.detached(priority: .utility) {
            var n = 0
            func one(_ phase: String) async -> Bool {
                n += 1
                let state = await MainActor.run { UIApplication.shared.applicationState.rawValue }   // 0 active, 2 background
                let s = LanguageModelSession(model: AppleRewrite.model, instructions: WritingPrompt.instructions(for: .formal))
                let t = Date()
                var ok = false, err = "", limited = false, reset: Double = -1
                do {
                    _ = try await s.respond(to: WritingPrompt.message(text), generating: WrittenText.self, includeSchemaInPrompt: true,
                                            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 600))
                    ok = true
                } catch {
                    err = String(describing: error)
                    let r = AppleRewrite.rateLimit(error); limited = r.limited
                    if let d = r.resetDate { reset = d.timeIntervalSinceNow }
                }
                let ms = Date().timeIntervalSince(t) * 1000
                let row: [String: Any] = ["n": n, "phase": phase, "t": Date().timeIntervalSince(t0), "ok": ok, "rateLimited": limited,
                                          "resetIn": reset, "ms": ms, "appState": state, "words": WritingReadout.words(text),
                                          "memMB": Double(DeviceProfile.footprintBytes()) / 1e6, "err": String(err.prefix(300))]
                NSLog("FFPROBE n=%d phase=%@ t=%.0fs ok=%d rl=%d reset-in=%.0f ms=%.0f state=%d words=%d err=%@", n, phase,
                      Date().timeIntervalSince(t0), ok ? 1 : 0, limited ? 1 : 0, reset, ms, state, WritingReadout.words(text), String(err.prefix(120)))
                WriteDiagnostics.note("probe", phase, row)
                if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); h.write(Data("\n".utf8)); try? h.close()
                }
                return limited
            }
            func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            // A: back to back until the limit, then 2 more (at most 40 calls).
            var limitedAt = 0
            for _ in 0..<40 {
                if await one("A") { limitedAt = n; break }
                await wait(3)
            }
            if limitedAt > 0 { for _ in 0..<2 { await wait(3); _ = await one("A+") } }
            // B: does waiting give it back?
            for gap in [15.0, 30, 60, 120, 240] { await wait(gap); _ = await one("B\(Int(gap))") }
            // C: one call per 20 s until the process is stopped.
            while true { await wait(20); _ = await one("C") }
        }
    }
}
#endif
