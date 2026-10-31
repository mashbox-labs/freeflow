import XCTest
@testable import FreeFlowKit

/// Per-word time of the autocorrect decision and of the space key's main-thread work, over the held-out words.
/// On the Mac this is Mac CPU time, not a phone. The same test runs on an iOS simulator or device through xcodebuild:
///   TEST_RUNNER_FFAC_DATA=<data dir> xcodebuild test -scheme FreeFlowKit \
///     -destination 'platform=iOS Simulator,name=<sim>' -only-testing:FreeFlowKitTests/AutocorrectTimingTests
/// (debug build unless the scheme's test action uses Release). In the keyboard, the FFAC log lines give the same numbers
/// per space press (category "autocorrect", debug level).
final class AutocorrectTimingTests: XCTestCase {
    private static var build: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static var machine: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return "Mac CPU (\(String(cString: buf)))"
        #else
        return "iOS \(ProcessInfo.processInfo.operatingSystemVersionString) (simulator or device: see the destination)"
        #endif
    }

    /// The prototype's quantile: sorted(a)[min(n - 1, int(p * n))].
    private func stats(_ a: [Double]) -> [String: Double] {
        guard !a.isEmpty else { return [:] }
        let s = a.sorted()
        let q = { (p: Double) in s[min(s.count - 1, Int(p * Double(s.count)))] }
        let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        return ["n": Double(s.count), "median": median, "p99": q(0.99), "max": s.last!]
    }

    private func fmt(_ d: [String: Double]) -> String {
        guard let n = d["n"] else { return "none" }
        return String(format: "n %d median %.4f p99 %.4f max %.3f ms", Int(n), d["median"]!, d["p99"]!, d["max"]!)
    }

    /// Wall time (what a person feels) and this thread's CPU time (excludes time the scheduler gave to others), ms.
    private struct Clock {
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var elapsed: (wall: Double, cpu: Double) {
            (Double(DispatchTime.now().uptimeNanoseconds - wall) / 1e6, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6)
        }
    }

    private final class Series {
        var wall: [Double] = [], cpu: [Double] = []
        func add(_ e: (wall: Double, cpu: Double)) { wall.append(e.wall); cpu.append(e.cpu) }
    }

    func testPerWordTimeHeldout() throws {
        let fx = try ACFixture.load()
        let e = fx.engine
        let words = try fx.typos("heldout").map(\.typo) + fx.stays("heldout").map(\.token)

        // Word list load (read + parse + trie), three fresh loads.
        let loads = Series()
        for _ in 0..<3 {
            let c = Clock()
            _ = try AutocorrectLexicon(contentsOf: fx.lexiconURL)
            loads.add(c.elapsed)
        }
        let fileBytes = (try FileManager.default.attributesOfItem(atPath: fx.lexiconURL.path)[.size] as? Int) ?? 0

        // 1) The decision alone, one call per word (as the prototype timed it), split like the prototype:
        //    known = guarded or in the word list; unknown = reaches the candidate search.
        func decisions() -> (known: Series, unknown: Series) {
            let known = Series(), unknown = Series()
            for w in words {
                let isUnknown = e.needsLookup(w, sentenceInitial: false)
                let c = Clock()
                _ = e.correct(w)
                (isUnknown ? unknown : known).add(c.elapsed)
            }
            return (known, unknown)
        }
        for w in ["warmup", "recieve", "teh"] { _ = e.correct(w) }
        let first = decisions()

        // 2) The space key's main-thread work with the lookup done while the word was typed (the keyboard's path).
        let typer = AutocorrectTyper(engine: e)
        let spaceCached = Series(), spaceKnown = Series()
        for w in words {
            let ctx = "so " + w
            typer.didType(contextBefore: ctx)
            typer.drainLookups()
            let c = Clock()
            _ = typer.space(contextBefore: ctx)
            let el = c.elapsed
            typer.reset()
            if typer.lastSpace?.path == .cached { spaceCached.add(el) } else { spaceKnown.add(el) }
        }

        // 3) The space key when the background answer is not ready: looked up on the spot, capped at syncBudgetMs
        //    of wall time (then the word is kept).
        let cold = AutocorrectTyper(engine: e)
        let spaceSync = Series()
        var timedOut = 0
        for w in words where e.needsLookup(w, sentenceInitial: false) {
            let ctx = "so " + w
            let c = Clock()
            _ = cold.space(contextBefore: ctx)
            spaceSync.add(c.elapsed)
            if cold.lastSpace?.path == .timedOut { timedOut += 1 }
            cold.reset()
        }

        // 4) The decision loop again, last: if it is slower now, the machine (not the code path) slowed down.
        let again = decisions()

        func both(_ s: Series) -> [String: Any] { ["wall": stats(s.wall), "thread_cpu": stats(s.cpu)] }
        let r: [String: Any] = [
            "machine": Self.machine, "build": Self.build,
            "qos": String(describing: qos_class_self().rawValue),
            "lexicon": ["words": e.lexicon.wordCount, "nodes": e.lexicon.nodeCount, "memory_MB": Double(e.lexicon.memoryBytes) / 1e6,
                        "file_MB": Double(fileBytes) / 1e6, "load_ms": both(loads)],
            "decision_known_ms": both(first.known), "decision_unknown_ms": both(first.unknown),
            "space_main_thread_cached_ms": both(spaceCached), "space_main_thread_known_or_guarded_ms": both(spaceKnown),
            "space_main_thread_not_ready_ms": both(spaceSync), "space_not_ready_timed_out": timedOut,
            "decision_unknown_again_ms": both(again.unknown), "decision_known_again_ms": both(again.known),
            "sync_budget_ms": cold.syncBudgetMs,
        ]
        func line(_ name: String, _ s: Series) {
            print("FFAC-TIMING \(name): wall \(fmt(stats(s.wall))) | thread CPU \(fmt(stats(s.cpu)))")
        }
        print("FFAC-TIMING \(Self.machine), \(Self.build) build, QoS class \(qos_class_self().rawValue)")
        print("FFAC-TIMING word list: \(e.lexicon.wordCount) words, \(e.lexicon.nodeCount) trie nodes, \(String(format: "%.2f", Double(e.lexicon.memoryBytes) / 1e6)) MB in memory, file \(String(format: "%.2f", Double(fileBytes) / 1e6)) MB")
        line("load", loads)
        line("decision, known words", first.known)
        line("decision, unknown words", first.unknown)
        line("space main thread, looked up while typing", spaceCached)
        line("space main thread, known or guarded", spaceKnown)
        line("space main thread, answer not ready (cap \(cold.syncBudgetMs) ms wall, timed out \(timedOut))", spaceSync)
        line("decision again at the end, unknown words", again.unknown)
        fx.write("ffac_swift_timing_\(Self.build).json", r)
        XCTAssertEqual(first.known.wall.count + first.unknown.wall.count, words.count)
    }
}
