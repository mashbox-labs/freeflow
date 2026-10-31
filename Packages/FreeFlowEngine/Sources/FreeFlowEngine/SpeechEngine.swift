import Foundation
import FreeFlowSpeech

/// On-device speech-to-text over llama.cpp + whisper.cpp sharing one ggml (FreeFlowSpeech.xcframework).
/// Two kinds of model: Parakeet TDT (.bin) and Liquid LFM audio GGUFs with their audio projector.
///
/// Metal in the foreground, CPU in the background: iOS refuses GPU work from a backgrounded app, so each call
/// names its backend. If it differs from the loaded one, the model is reloaded on that backend (Parakeet loads in
/// about 0.1-0.3 s). A Metal failure (for example the app went to the background mid-call) reloads on the CPU and
/// retries once. One call at a time; the lock serialises callers.
public final class SpeechEngine: @unchecked Sendable {
    public enum Kind: Sendable, Equatable {
        case parakeet
        case audioLLM(projectorPath: String, systemPrompt: String)
    }

    public enum Backend: String, Sendable, Equatable { case cpu, metal }

    public struct EngineError: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Transcript: Sendable {
        public let text: String
        public let computeSeconds: Double
        public let backend: Backend
        /// Seconds spent loading the model for this call (0 when it was already loaded on this backend).
        public let loadSeconds: Double
    }

    public static var systemInfo: String { String(cString: ff_engine_system_info()) }

    /// Performance cores, capped at 4 (more threads stopped helping on the Mac bench).
    public static var defaultThreads: Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 { return min(value, 4) }
        return Int32(min(ProcessInfo.processInfo.activeProcessorCount, 4))
    }

    public let modelPath: String
    public let kind: Kind
    public let threads: Int32
    private var engine: OpaquePointer?
    private var loadedBackend: Backend?
    private var loadedThreads: Int32 = 0
    private var closed = false
    private let lock = NSLock()

    public init(modelPath: String, kind: Kind, threads: Int32 = SpeechEngine.defaultThreads, preload: Backend? = nil) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else { throw EngineError(description: "model not found") }
        if case let .audioLLM(projector, _) = kind, !FileManager.default.fileExists(atPath: projector) {
            throw EngineError(description: "audio projector not found")
        }
        self.modelPath = modelPath
        self.kind = kind
        self.threads = threads
        ff_engine_set_logging(0)
        if let preload {
            lock.lock(); defer { lock.unlock() }
            _ = try load(preload, threads: threads)
        }
    }

    deinit { if let engine { ff_engine_free(engine) } }

    /// Input rate the loaded model expects (16 kHz for every model we ship).
    public var sampleRate: Int { Int(lock.withLock { engine.map { ff_engine_sample_rate($0) } ?? 16_000 }) }

    /// Transcribe one utterance of mono Float32 samples at `sampleRate`.
    /// `threads`: CPU threads for this call (nil = the engine's default). A different count reloads the model.
    public func transcribe(_ samples: [Float], backend: Backend, threads: Int32? = nil) throws -> Transcript {
        guard !samples.isEmpty else { return Transcript(text: "", computeSeconds: 0, backend: backend, loadSeconds: 0) }
        lock.lock(); defer { lock.unlock() }
        if closed { throw EngineError(description: "the speech model was unloaded") }
        var load = 0.0
        let want = threads ?? self.threads
        if loadedBackend != backend || loadedThreads != want { load = try self.load(backend, threads: want) }
        var used = backend
        var result = run(samples)
        if result.status == -2, backend == .metal {
            load += try self.load(.cpu, threads: want)
            used = .cpu
            result = run(samples)
        }
        if result.status == -4 {
            throw EngineError(description: "This model could not finish this recording, so no text was kept. The recording is in History: retry it with Parakeet.")
        }
        guard result.status == 0 else { throw EngineError(description: "transcription failed (status \(result.status))") }
        return Transcript(text: result.text, computeSeconds: result.seconds, backend: used, loadSeconds: load)
    }

    /// Frees the model for good: later calls throw instead of loading it again (the app switched or deleted models).
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let engine { ff_engine_free(engine) }
        engine = nil
        loadedBackend = nil
        closed = true
    }

    /// Frees the model (for example on a memory warning). The next call loads it again.
    public func unload() {
        lock.lock(); defer { lock.unlock() }
        if let engine { ff_engine_free(engine) }
        engine = nil
        loadedBackend = nil
    }

    private func load(_ backend: Backend, threads: Int32) throws -> Double {
        if let engine { ff_engine_free(engine) }
        engine = nil
        loadedBackend = nil
        let start = Date()
        var params = ff_engine_default_params()
        params.use_gpu = backend == .metal ? 1 : 0
        params.n_threads = threads
        loadedThreads = threads
        var message = [CChar](repeating: 0, count: 512)
        let loaded: OpaquePointer? = modelPath.withCString { model in
            params.model_path = model
            switch kind {
            case .parakeet:
                params.kind = Int32(FF_KIND_PARAKEET.rawValue)
                return ff_engine_load(&params, &message, message.count)
            case let .audioLLM(projector, prompt):
                params.kind = Int32(FF_KIND_AUDIO_LLM.rawValue)
                return projector.withCString { proj in
                    prompt.withCString { sys in
                        params.mmproj_path = proj
                        params.system_prompt = sys
                        return ff_engine_load(&params, &message, message.count)
                    }
                }
            }
        }
        guard let loaded else { throw EngineError(description: String(cString: message)) }
        engine = loaded
        loadedBackend = backend
        return Date().timeIntervalSince(start)
    }

    private func run(_ samples: [Float]) -> (status: Int32, text: String, seconds: Double) {
        guard let engine else { return (-1, "", 0) }
        var text: UnsafePointer<CChar>?
        var timings = ff_timings()
        let status = samples.withUnsafeBufferPointer { buf in
            ff_engine_transcribe(engine, buf.baseAddress, Int32(buf.count), &text, &timings)
        }
        guard status == 0, let text else { return (status, "", 0) }
        return (0, String(cString: text), timings.compute_ms / 1000)
    }

    /// Joins piece texts exactly as ff_engine_transcribe does over the same pieces: Parakeet ends every segment with a
    /// newline; the audio LLM puts one space before a piece when the text so far ends in neither space nor newline.
    public static func join(_ text: String, _ piece: String, kind: Kind) -> String {
        if case .audioLLM = kind, let last = text.last, last != " ", last != "\n", !piece.isEmpty { return text + " " + piece }
        return text + piece
    }

    /// Where the engine cuts a long recording into pieces (audio over 30 s, at quiet points): one range per piece.
    public static func pieces(of samples: [Float], sampleRate: Int = 16_000) -> [Range<Int>] {
        let n = samples.withUnsafeBufferPointer { ff_engine_split($0.baseAddress, Int32($0.count), Int32(sampleRate), nil, 0) }
        guard n > 0 else { return [] }
        var starts = [Int32](repeating: 0, count: Int(n))
        _ = samples.withUnsafeBufferPointer { ff_engine_split($0.baseAddress, Int32($0.count), Int32(sampleRate), &starts, n) }
        let bounds = starts.map(Int.init) + [samples.count]
        return (0..<Int(n)).map { bounds[$0]..<bounds[$0 + 1] }
    }

    /// Reads a 16-bit PCM or Float32 WAV the same way the Mac CLI does (tests and file import).
    public static func readWAV(_ path: String) throws -> (samples: [Float], sampleRate: Int) {
        var count: Int32 = 0, rate: Int32 = 0, channels: Int32 = 0
        guard let pointer = ff_wav_read(path, &count, &rate, &channels) else { throw EngineError(description: "not a readable WAV") }
        defer { ff_free(pointer) }
        return (Array(UnsafeBufferPointer(start: pointer, count: Int(count))), Int(rate))
    }
}
