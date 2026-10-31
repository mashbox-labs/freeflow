import Darwin
import Foundation
import XCTest
@testable import FreeFlowKit

/// What loading the bundled word list costs the keyboard: load time and memory (phys_footprint, the number iOS
/// holds an extension to). Run it ALONE so the process has done nothing else first:
///   FFAC_MEMORY=1 swift test -c release -Xswiftc -enable-testing --filter AutocorrectMemoryTests
/// Opt-in (FFAC_MEMORY=1), because inside a full test run earlier tests have already moved the process peak.
/// Writes ffac_list_memory.json to $FFAC_OUT (else the temporary folder).
final class AutocorrectMemoryTests: XCTestCase {
    struct Footprint { let now: Double; let peak: Double }   // MB (2^20 bytes)

    static func footprint() -> Footprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        precondition(kr == KERN_SUCCESS)
        return Footprint(now: Double(info.phys_footprint) / 1_048_576, peak: Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var highest: Double
        init(_ start: Double) { highest = start }
        var peak: Double { lock.lock(); defer { lock.unlock() }; return highest }
        func stop() { lock.lock(); running = false; lock.unlock() }
        func run() {
            while true {
                let f = AutocorrectMemoryTests.footprint().now
                lock.lock(); highest = max(highest, f); let go = running; lock.unlock()
                if !go { return }
                usleep(50)
            }
        }
    }

    func testBundledListLoadAndMemory() throws {
        guard ProcessInfo.processInfo.environment["FFAC_MEMORY"] == "1" else {
            throw XCTSkip("Opt-in: FFAC_MEMORY=1, run alone (see the comment above)")
        }
        let url = try ACFixture.bundledList()
        // A sampler thread catches the transient peak during the build; the kernel ledger keeps the process peak too.
        let before = Self.footprint()
        let sampler = Sampler(before.now)
        let thread = Thread { sampler.run() }
        thread.start()
        usleep(1_000)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let lexicon = try AutocorrectLexicon(contentsOf: url)
        let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let after = Self.footprint()
        sampler.stop()
        usleep(2_000)
        let sampled = sampler.peak
        let fileMB = Double((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_048_576
        let peakOver = max(after.peak, sampled) - before.now
        let result: [String: Any] = [
            "file_MB": fileMB, "words": lexicon.wordCount, "nodes": lexicon.nodeCount,
            "arrays_MB": Double(lexicon.memoryBytes) / 1_048_576, "load_ms": loadMs,
            "footprint_before_MB": before.now, "footprint_after_MB": after.now,
            "retained_MB": after.now - before.now,
            "ledger_peak_before_MB": before.peak, "ledger_peak_after_MB": after.peak,
            "sampled_peak_MB": sampled, "peak_over_before_MB": peakOver,
            "note": "MB = 2^20 bytes. peak_over_before = highest footprint seen during the load (ledger or sampler) minus the footprint just before it.",
        ]
        print(String(format: "FFAC-MEMORY load %.1f ms, footprint %.2f -> %.2f MB (retained %.2f MB), peak during load %.2f MB over before (ledger %.2f, sampled %.2f), arrays %.2f MB, file %.2f MB",
                     loadMs, before.now, after.now, after.now - before.now, peakOver,
                     after.peak - before.now, sampled - before.now, Double(lexicon.memoryBytes) / 1_048_576, fileMB))
        ACFixture.write("ffac_list_memory.json", result)
        withExtendedLifetime(lexicon) {}
    }
}
