import XCTest
@testable import FreeFlowEngine

/// Runs the engine on host files (the simulator reads the Mac's file system) and writes <name>.txt per file, so the
/// text can be compared byte for byte with the Mac CLI (build/ffasr) on the same files.
/// TEST_RUNNER_FF_KIND = parakeet | llm, TEST_RUNNER_FF_MODEL, TEST_RUNNER_FF_MMPROJ + TEST_RUNNER_FF_SYS (llm),
/// TEST_RUNNER_FF_WAVS = directory of 16 kHz mono WAVs, TEST_RUNNER_FF_OUT = output directory,
/// TEST_RUNNER_FF_THREADS (default 4), TEST_RUNNER_FF_BACKEND = cpu | metal (default cpu).
final class SpeechEngineTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    /// The paced background path (Transcriber.paced) transcribes the engine's own pieces one call each, on one thread,
    /// and joins them: the text must equal one call over the whole recording. FF_MODEL + FF_LONGWAV (> 30 s, 16 kHz).
    func testPiecewiseOneThreadEqualsOneCall() throws {
        guard let model = env["FF_MODEL"], let wav = env["FF_LONGWAV"] else { throw XCTSkip("set FF_MODEL and FF_LONGWAV") }
        let kind: SpeechEngine.Kind = env["FF_KIND"] == "llm"
            ? .audioLLM(projectorPath: env["FF_MMPROJ"] ?? "", systemPrompt: env["FF_SYS"] ?? "Perform ASR.")
            : .parakeet
        let audio = try SpeechEngine.readWAV(wav).samples
        let pieces = SpeechEngine.pieces(of: audio)
        XCTAssertGreaterThan(pieces.count, 1)
        let engine = try SpeechEngine(modelPath: model, kind: kind, threads: 4)
        let whole1 = try engine.transcribe(audio, backend: .cpu, threads: 1)
        var joined = ""
        var busy = 0.0
        for r in pieces {
            let t = try engine.transcribe(Array(audio[r]), backend: .cpu, threads: 1)
            busy += t.computeSeconds
            joined = SpeechEngine.join(joined, t.text, kind: kind)
        }
        XCTAssertEqual(joined, whole1.text, "pieces one by one == one call (1 thread)")
        let whole4 = try engine.transcribe(audio, backend: .cpu)
        print(String(format: "FFPIECES pieces=%d audio=%.1fs one_thread_whole=%.2fs one_thread_pieces=%.2fs four_threads=%.2fs same_text_1v4=%@",
                     pieces.count, Double(audio.count) / 16_000, whole1.computeSeconds, busy, whole4.computeSeconds,
                     whole4.text == whole1.text ? "yes" : "no"))
    }

    func testTranscribeFiles() throws {
        guard let model = env["FF_MODEL"], let wavs = env["FF_WAVS"], let out = env["FF_OUT"] else {
            throw XCTSkip("set TEST_RUNNER_FF_MODEL, TEST_RUNNER_FF_WAVS, TEST_RUNNER_FF_OUT")
        }
        let kind: SpeechEngine.Kind = env["FF_KIND"] == "llm"
            ? .audioLLM(projectorPath: env["FF_MMPROJ"] ?? "", systemPrompt: env["FF_SYS"] ?? "Perform ASR.")
            : .parakeet
        let threads = Int32(env["FF_THREADS"] ?? "4") ?? 4
        let backend = SpeechEngine.Backend(rawValue: env["FF_BACKEND"] ?? "cpu") ?? .cpu
        let engine = try SpeechEngine(modelPath: model, kind: kind, threads: threads)
        let outDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: wavs).filter { $0.hasSuffix(".wav") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var audio = 0.0, busy = 0.0, load = 0.0
        for name in files {
            let wav = try SpeechEngine.readWAV(URL(fileURLWithPath: wavs).appendingPathComponent(name).path)
            XCTAssertEqual(wav.sampleRate, 16_000)
            let result = try engine.transcribe(wav.samples, backend: backend)
            XCTAssertEqual(result.backend, backend)
            busy += result.computeSeconds
            load += result.loadSeconds
            audio += Double(wav.samples.count) / Double(wav.sampleRate)
            let txt = outDir.appendingPathComponent(String(name.dropLast(4)) + ".txt")
            try Data(result.text.utf8).write(to: txt)
        }
        let summary = String(format: "files %d audio_s %.2f compute_s %.2f rtfx %.2f load_s %.3f threads %d backend %@ | %@",
                             files.count, audio, busy, audio / busy, load, threads, backend.rawValue, SpeechEngine.systemInfo)
        try Data(summary.utf8).write(to: outDir.appendingPathComponent("SUMMARY.txt"))
        print(summary)
    }

    /// close(): after the app switches or deletes a model, a late call throws instead of loading the model again.
    /// FF_PK_MODEL = a Parakeet GGUF/bin.
    func testCloseStopsReload() throws {
        guard let model = env["FF_PK_MODEL"] else { throw XCTSkip("set TEST_RUNNER_FF_PK_MODEL") }
        let engine = try SpeechEngine(modelPath: model, kind: .parakeet)
        let second = [Float](repeating: 0, count: 16_000)
        XCTAssertNoThrow(try engine.transcribe(second, backend: .cpu))
        engine.close()
        XCTAssertThrowsError(try engine.transcribe(second, backend: .cpu)) { error in
            XCTAssertTrue("\(error)".contains("unloaded"), "\(error)")
        }
    }

    /// The cut points: up to 30 s is one piece; longer audio is cut inside its quiet gaps, every piece is 2-30 s, and the
    /// pieces cover every sample once.
    func testSplitCutsLongAudioInQuietGaps() {
        let sr = 16_000
        XCTAssertEqual(SpeechEngine.pieces(of: [Float](repeating: 0.1, count: 30 * sr)), [0..<(30 * sr)])
        // 75 s of a tone with 0.5 s of silence at 24 s and at 50 s.
        var audio = (0..<(75 * sr)).map { Float(0.3 * sin(Double($0) * 0.05)) }
        for gap in [24, 50] { for i in (gap * sr)..<(gap * sr + sr / 2) { audio[i] = 0 } }
        let pieces = SpeechEngine.pieces(of: audio)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.first?.lowerBound, 0)
        XCTAssertEqual(pieces.last?.upperBound, audio.count)
        for (a, b) in zip(pieces, pieces.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
        for p in pieces { XCTAssertTrue(p.count >= 2 * sr && p.count <= 30 * sr, "\(p)") }
        // each cut lands inside a silent gap
        for (cut, gap) in zip(pieces.dropFirst().map(\.lowerBound), [24, 50]) {
            XCTAssertTrue(cut >= gap * sr && cut <= gap * sr + sr / 2, "cut \(cut) not in the gap at \(gap) s")
        }
        // a 30.1 s clip never leaves a tiny tail
        let tail = SpeechEngine.pieces(of: [Float](repeating: 0.1, count: 30 * sr + sr / 10))
        XCTAssertTrue(tail.allSatisfy { $0.count >= 2 * sr }, "\(tail)")
    }

    /// A long recording comes back whole: the text equals its pieces transcribed one by one and joined, so nothing is
    /// dropped at a cut. FF_LONG_WAV (over 30 s) with FF_KIND/FF_MODEL (+ FF_MMPROJ, FF_SYS for an audio LLM).
    func testLongAudioComesBackWhole() throws {
        guard let model = env["FF_MODEL"], let long = env["FF_LONG_WAV"] else {
            throw XCTSkip("set TEST_RUNNER_FF_MODEL, TEST_RUNNER_FF_LONG_WAV")
        }
        let kind: SpeechEngine.Kind = env["FF_KIND"] == "llm"
            ? .audioLLM(projectorPath: env["FF_MMPROJ"] ?? "", systemPrompt: env["FF_SYS"] ?? "Perform ASR.")
            : .parakeet
        let engine = try SpeechEngine(modelPath: model, kind: kind)
        let wav = try SpeechEngine.readWAV(long)
        let pieces = SpeechEngine.pieces(of: wav.samples)
        XCTAssertGreaterThan(pieces.count, 1, "FF_LONG_WAV must be over 30 s")
        let whole = try engine.transcribe(wav.samples, backend: .cpu).text
        let joined = try pieces.map { try engine.transcribe(Array(wav.samples[$0]), backend: .cpu).text }
        let words = { (s: String) in s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) }
        XCTAssertEqual(words(whole), joined.flatMap(words))
        print("FFLONG pieces \(pieces.count) words \(words(whole).count)")
    }
}
