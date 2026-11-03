import CoreML
import FluidAudio
import FreeFlowEngine
import FreeFlowKit
import Foundation
import UIKit
import WhisperKit
import os

private let pacedLog = Logger(subsystem: FF.subsystem, category: "cpu")

/// Runs the chosen speech model on this device. Core ML models (the Neural Engine on iPhone and iPad): Parakeet
/// through FluidAudio, Whisper through WhisperKit. C++ models (FreeFlowEngine, llama.cpp + whisper.cpp Parakeet on
/// one ggml): Metal while the app is active, the CPU otherwise, since iOS refuses GPU work from a background app.
/// No audio leaves the process.
actor Transcriber {
    static let shared = Transcriber()
    private var parakeet: AsrManager?
    private var whisper: WhisperKit?
    private var ane: WhisperANE?
    private var cpp: SpeechEngine?
    private var loadedID: String?
    private var decoderLayers = 2
    /// Memory the loaded model added to this process (phys_footprint after its load minus after the previous model was
    /// unloaded). Switching models frees it, so the Models screen adds it back to what iOS says the app can still use.
    private(set) var loadedBytes: UInt64 = 0

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FreeFlow/Models")
    }

    /// Model files. The first Parakeet ("medium") stays where FluidAudio expects it, so installed copies keep
    /// working; every other model, whatever its engine, has its own folder.
    static func directory(for id: String) -> URL {
        if id == "medium" { return AsrModels.defaultCacheDirectory(for: .v3) }
        return root.appendingPathComponent(id + "/model")
    }

    /// Build 23 (FluidAudio v0.18.0): the FluidAudio version each Parakeet-family model decodes with. Each loads from its
    /// own folder (AsrModels.loadLocal), so no folder has to carry FluidAudio's cache name. Bark 3.0 Pro is Conway
    /// Research's full Core ML build on Ultra's component contract.
    static func parakeetVersion(_ id: String) -> AsrModelVersion? {
        switch id {
        case "medium": return .v3
        case "parakeet-ultra", "bark-3-pro": return .ultra
        case "parakeet-redux": return .redux
        case "phonon-2": return .phonon2
        case "bark-3.0-clean": return .bark3Clean
        default: return nil
        }
    }

    /// Build 23: a model published as .mlpackage files (Bark 3.0 Pro) is compiled for this device once, before its first
    /// load: each package becomes the .mlmodelc FluidAudio loads, in the same folder, and the package is then removed
    /// (the compiled copy replaces it; 1.2 GB not kept twice). Conway's vocabulary file is copied, bytes unchanged, under
    /// the name FluidAudio reads. Nothing to do once compiled.
    static func compilePackages(in directory: URL) async throws {
        let fm = FileManager.default
        let packages = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".mlpackage") }.sorted()
        for name in packages {
            let package = directory.appendingPathComponent(name)
            let compiledURL = directory.appendingPathComponent((name as NSString).deletingPathExtension + ".mlmodelc")
            if !fm.fileExists(atPath: compiledURL.path) {
                let temporary = try await MLModel.compileModel(at: package)
                try? fm.removeItem(at: compiledURL.appendingPathExtension("part"))
                try fm.moveItem(at: temporary, to: compiledURL.appendingPathExtension("part"))
                try fm.moveItem(at: compiledURL.appendingPathExtension("part"), to: compiledURL)
            }
            try fm.removeItem(at: package)
        }
        let vocabulary = directory.appendingPathComponent("parakeet_vocab.json")
        let v3Vocabulary = directory.appendingPathComponent("parakeet_v3_vocab.json")
        if !fm.fileExists(atPath: vocabulary.path), fm.fileExists(atPath: v3Vocabulary.path) {
            try fm.copyItem(at: v3Vocabulary, to: vocabulary)
        }
    }

    static func tokenizerDirectory(for id: String) -> URL { root.appendingPathComponent(id + "/tokenizer") }

    var currentID: String? { loadedID }

    /// Marker for the crash-loop guard: written before each GGUF load or run, removed when it returns (CppCrashGuard).
    static let crashGuard = CppCrashGuard(url: root.deletingLastPathComponent().appendingPathComponent("cpp-in-progress.json"))

    /// Loads in flight, one per model (LoadGate). Build 22: a newer pick never waits for an older load.
    private let gate = LoadGate()
    /// Dictations running on the model in use. Letting that model go waits for them: a switch lets a dictation finish.
    private var running = 0

    /// A load that ended after a different model was picked; its model was let go.
    struct Superseded: Error, LocalizedError {
        let id: String
        var errorDescription: String? { "A different speech model was picked while this one was loading." }
    }

    /// The model in use is not the one this dictation was meant for (the pick changed in between). Nothing ran.
    struct ModelChanged: Error, LocalizedError {
        let expected: String
        let loaded: String?
        var errorDescription: String? { "The speech model changed during this dictation." }
    }

    /// What one load made, before it is put in use or let go.
    private enum Built {
        case cpp(SpeechEngine), parakeet(AsrManager, layers: Int), whisper(WhisperKit), ane(WhisperANE)

        func close() async {
            switch self {
            case .cpp(let engine): engine.close()
            case .parakeet(let manager, _): await manager.cleanup()
            case .whisper, .ane: break    // let go with its last reference
            }
        }
    }

    /// Loads a model for dictation; returns the seconds it took (0 when it is already in use). The model in use is let
    /// go first, so at most one speech model is resident. Build 22: a different model picked while this one
    /// loads starts at once; this load then ends with Superseded and its model is let go (build 19 made the newer pick
    /// wait for the whole load, minutes for a first Neural Engine build, until a relaunch).
    func load(_ id: String, limit: ActiveLimit? = nil) async throws -> Double {
        if loadedID == id { await gate.want(id); return 0 }
        return try await gate.run(id, expired: limit.map { l in { l.expired() } }) { [self] token in
            try await self.loadNow(id, build: false, token: token)
        }
    }

    /// Build 24: gives up on the load of `id` in flight (iOS suspended it in the background and it did not come back).
    /// Its caller gets LoadGate.Abandoned; whatever it builds later is let go.
    func abandon(_ id: String) async { await gate.abandon(id) }

    /// The one-time Neural Engine build right after a download: Core ML builds the model for this device on
    /// its first load and keeps the result, so the model is loaded once and let go; its next load takes about a second.
    /// The model in use is let go first (one resident model) and comes back with its next load. If this model is picked
    /// while it builds, the build becomes its load.
    func prepare(_ id: String, limit: ActiveLimit? = nil) async throws -> Double {
        if loadedID == id { return 0 }
        return try await gate.run(id, want: false, expired: limit.map { l in { l.expired() } }) { [self] token in
            try await self.loadNow(id, build: true, token: token)
        }
    }

    private func loadNow(_ id: String, build: Bool, token: Int) async throws -> Double {
        if loadedID == id { return 0 }
        // Build 23: it waited for another load and is no longer the pick: load nothing.
        if !build, !(await gate.isWanted(id)) { throw Superseded(id: id) }
        await release(for: id)
        let before = DeviceProfile.footprintBytes()
        let start = Date()
        let built: Built
        if let model = ModelCatalog.model(id), model.engine.isCpp {
            Self.crashGuard.begin(id, .load)
            defer { Self.crashGuard.end() }
            built = .cpp(try await Self.loadCpp(model, directory: Self.directory(for: id), backend: Self.backendNow()))
        } else if ModelCatalog.model(id)?.engine == .whisperANE {
            // Our Whisper build: every length bucket on the Mac; with one function per bucket an iPhone or iPad loads
            // two (10 s and the 30 s window), since the Neural Engine keeps a copy of the weights per function. A
            // one-program build (manifest one_program) holds one copy, so every device loads every bucket.
            #if targetEnvironment(macCatalyst)
            var buckets: [Int]? = nil
            #else
            var buckets: [Int]? = [10, 30]
            #endif
            // Test builds: FF_ANE_BUCKETS=10,30 measures the phone's bucket set on the Mac.
            var forced = false
            if let env = ProcessInfo.processInfo.environment["FF_ANE_BUCKETS"] { buckets = env.split(separator: ",").compactMap { Int($0) }; forced = true }
            let directory = Self.directory(for: id)
            let pick = buckets, force = forced
            built = .ane(try await Task.detached(priority: .userInitiated) { try WhisperANE(directory: directory, buckets: pick, forced: force) }.value)
        } else if ModelCatalog.model(id)?.engine == .parakeetV3 {
            let directory = Self.directory(for: id)
            try await Self.compilePackages(in: directory)
            let models = id == "medium"
                ? try await AsrModels.load(from: directory, version: .v3)
                : try AsrModels.loadLocal(from: directory, version: Self.parakeetVersion(id) ?? .ultra)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            built = .parakeet(manager, layers: await manager.decoderLayerCount)
        } else {
            let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            let config = WhisperKitConfig(modelFolder: Self.directory(for: id).path,
                                          tokenizerFolder: Self.tokenizerDirectory(for: id),
                                          computeOptions: compute, verbose: false, logLevel: .error,
                                          prewarm: false, load: true, download: false)
            built = .whisper(try await WhisperKit(config))
        }
        let seconds = Date().timeIntervalSince(start)
        // Build 24: a load abandoned meanwhile (past its limit, or suspended) never puts its model in use.
        guard await gate.isLive(token) else {
            await built.close()
            NSLog("FFMODEL %@ ended after it was abandoned (%.2fs): let go", id, seconds)
            throw LoadGate.Abandoned(id: id)
        }
        guard await gate.isWanted(id) else {
            await built.close()
            NSLog("FFMODEL %@ %@ load=%.2fs footprintMB=%llu", build ? "built (one time), let go:" : "drop (not the pick now):", id,
                  seconds, DeviceProfile.footprintBytes() >> 20)
            if build { return seconds }
            throw Superseded(id: id)
        }
        await release(for: id)        // a model put in use while this one loaded
        switch built {
        case .cpp(let engine): cpp = engine
        case .parakeet(let manager, let layers): parakeet = manager; decoderLayers = layers
        case .whisper(let kit): whisper = kit
        case .ane(let engine): ane = engine
        }
        loadedID = id
        let after = DeviceProfile.footprintBytes()
        loadedBytes = after > before ? after - before : 0
        return seconds
    }

    /// Lets the model in use go (its memory and its Neural Engine program), after any dictation running on it ends.
    private func release(for next: String) async {
        guard let current = loadedID, current != next else { return }
        while running > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard loadedID == current else { return }      // changed while the dictation finished
        let before = DeviceProfile.footprintBytes()
        let oldParakeet = parakeet, oldCpp = cpp
        parakeet = nil
        whisper = nil
        ane = nil
        cpp = nil
        loadedID = nil
        loadedBytes = 0
        await oldParakeet?.cleanup()
        oldCpp?.close()
        NSLog("FFMODEL release %@ for=%@ footprintMB before=%llu after=%llu", current, next.isEmpty ? "none" : next,
              before >> 20, DeviceProfile.footprintBytes() >> 20)
    }

    func unload() async {
        await release(for: "")
    }

    /// Metal only while the app is active; inactive or background runs on the CPU (no GPU work at all).
    @MainActor static func backendNow() -> SpeechEngine.Backend {
        #if targetEnvironment(simulator)
        // The simulator always runs the C++ engine on the CPU. Its Metal device is not the phone's: ggml picks its
        // buffer path from MTLDevice.hasUnifiedMemory (ggml-metal-device.m:1271, use_shared_buffers). iPhones, iPads
        // and Apple silicon Macs report unified memory, so ggml copies weights into shared buffers with memcpy. The
        // simulator's device does not (measured 10-29: "Apple iOS simulator GPU" hasUnifiedMemory=0, an
        // Apple M5 Mac hasUnifiedMemory=1), so ggml wraps the caller's pointer with
        // newBufferWithBytesNoCopy (ggml_metal_buffer_set_tensor) and the simulator's Metal driver traps on it:
        // SIGTRAP in _xpc_shmem_create_with_prot <- MTLSimDevice newBufferWithLength:options:pointer:copyBytes:
        // deallocator: <- ggml_metal_buffer_set_tensor <- parakeet_model_load (crash reports
        // on an iOS 26.5 simulator on macOS 26.5.1, 2026-10-29).
        // The real Metal path is tested on Apple silicon instead (My Mac, Designed for iPad).
        return .cpu
        #else
        return UIApplication.shared.applicationState == .active ? .metal : .cpu
        #endif
    }

    private static func loadCpp(_ model: SpeechModel, directory: URL, backend: SpeechEngine.Backend) async throws -> SpeechEngine {
        guard let file = model.modelFile else { throw FFError("\(model.name) has no model file in the catalog.") }
        let kind: SpeechEngine.Kind
        if model.engine == .ggmlAudioLLM {
            guard let projector = model.projectorFile else { throw FFError("\(model.name) has no audio projector in the catalog.") }
            kind = .audioLLM(projectorPath: directory.appendingPathComponent(projector).path,
                             systemPrompt: model.systemPrompt ?? "Perform ASR.")
        } else {
            kind = .parakeet
        }
        let path = directory.appendingPathComponent(file).path
        return try await Task.detached(priority: .userInitiated) {
            try SpeechEngine(modelPath: path, kind: kind, preload: backend)
        }.value
    }

    @MainActor static func isBackground() -> Bool {
        UIApplication.shared.applicationState != .active
    }

    /// The C++ engine with Free Flow in the background stays under iOS's background CPU limit (80% of one core over
    /// 60 s; cpu_resource_fatal killed build 8 on an iPad, 10-29). Apple: "Identifying the cause of common crashes"
    /// (EXC_RESOURCE CPU), WWDC20 "Why is my app getting killed?", and "Preparing your UI to run in the background"
    /// (no GPU work in the background). One thread (no spinning helpers), the same pieces the engine cuts (30 s at
    /// quiet points, so the text is identical to one call), and before each piece CpuMeter waits until this process's
    /// CPU over the last 60 s plus the piece's expected cost fits in 50% of one core.
    static func paced(_ cpp: SpeechEngine, _ samples: [Float]) async throws -> (text: String, reload: Double) {
        let rate = 16_000.0
        var text = "", reload = 0.0
        var costPerSecond = 0.5          // CPU s per audio s; measured after each piece
        let meter = CpuMeter.shared
        let pieces = SpeechEngine.pieces(of: samples)
        for (i, range) in pieces.enumerated() {
            let audio = Double(range.count) / rate
            let cost = min(costPerSecond * audio, meter.allowed * 0.5)
            var waited = 0.0
            while true {
                let w = meter.wait(cost: cost)
                if w <= 0 { break }
                let step = min(w, 2)
                try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                waited += step
            }
            let c0 = CpuMeter.processCPU()
            let piece = Array(samples[range])
            let r = try await Task.detached(priority: .utility) { try cpp.transcribe(piece, backend: .cpu, threads: 1) }.value
            reload += r.loadSeconds
            let spent = CpuMeter.processCPU() - c0
            if r.loadSeconds == 0 { costPerSecond = max(0.05, spent / max(audio, 0.5)) }
            meter.sample()
            pacedLog.notice("FFPACED piece \(i + 1, privacy: .public)/\(pieces.count, privacy: .public) audio=\(audio, format: .fixed(precision: 1), privacy: .public)s cpu=\(spent, format: .fixed(precision: 2), privacy: .public)s waited=\(waited, format: .fixed(precision: 0), privacy: .public)s load=\(r.loadSeconds, format: .fixed(precision: 2), privacy: .public)s")
            text = SpeechEngine.join(text, r.text, kind: cpp.kind)
        }
        return (text, reload)
    }

    /// Paces Parakeet Core ML's long-audio chunks while Free Flow is in the background, the way `paced` paces C++:
    /// FluidAudio's chunks (about 15 s each) run one at a time instead of 4 at once, and before each one CpuMeter waits
    /// until this process's CPU over the last 60 s plus the chunk's expected cost fits in 50% of one core. The cost per
    /// audio second is measured from the chunk before. On a device the encoder runs on the Neural Engine, so the CPU
    /// cost and the waits should be small; the simulator has no Neural Engine and runs it all on the CPU. FluidAudio's
    /// own chunks and decoding, so the text is the same as unpaced. In the foreground nothing changes.
    final class CoreMLPacer: ChunkPacer, @unchecked Sendable {
        private let lock = NSLock()
        private var costPerSecond = 0.5          // CPU s per audio s; measured after each chunk
        private var last: (cpu: Double, audio: Double)?
        private var chunks = 0, waitedTotal = 0.0

        func pacing() async -> Bool {
            let background = await Transcriber.isBackground()
            if !background { lock.withLock { last = nil } }
            return background
        }

        func beforeChunk(audioSeconds: Double) async throws {
            let meter = CpuMeter.shared
            let allowed = meter.allowed
            let now = CpuMeter.processCPU()
            let (cost, spent): (Double, Double) = lock.withLock {
                var spent = -1.0
                if let last {
                    spent = now - last.cpu
                    costPerSecond = max(0.05, spent / max(last.audio, 0.5))
                }
                return (min(costPerSecond * audioSeconds, allowed * 0.5), spent)
            }
            var waited = 0.0
            while true {
                let w = meter.wait(cost: cost)
                if w <= 0 { break }
                let step = min(w, 2)
                try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                waited += step
            }
            meter.sample()
            let n: Int = lock.withLock {
                last = (CpuMeter.processCPU(), audioSeconds)
                chunks += 1
                waitedTotal += waited
                return chunks
            }
            pacedLog.notice("FFPACED coreml chunk \(n, privacy: .public) audio=\(audioSeconds, format: .fixed(precision: 1), privacy: .public)s prevcpu=\(spent, format: .fixed(precision: 2), privacy: .public)s waited=\(waited, format: .fixed(precision: 0), privacy: .public)s")
        }

        func logSummary(audioSeconds: Double) {
            let (n, w) = lock.withLock { (chunks, waitedTotal) }
            guard n > 0 else { return }
            pacedLog.notice("FFPACED coreml done chunks=\(n, privacy: .public) audio=\(audioSeconds, format: .fixed(precision: 0), privacy: .public)s waited=\(w, format: .fixed(precision: 0), privacy: .public)s")
        }
    }

    /// 16 kHz mono in, text out. `words` = the dictionary: the Core ML models lean toward them while they decode
    /// (Parakeet: decode-time boost on its top-K; Whisper: the words as its prompt). The C++ models have no
    /// decode-time hook yet, so they ignore the words. Nothing rewrites text after decoding.
    /// `timings`: each word with its time in the recording, for smart paragraphs. Only Parakeet on Core ML has them
    /// (FluidAudio's token timings); Whisper runs without timestamps and the C++ engine returns text only, so empty.
    /// `expect`: the model this dictation is for; if another is in use (the pick changed), ModelChanged and nothing runs.
    func transcribe(_ samples: [Float], words: [String] = [], expect: String? = nil) async throws -> (text: String, timings: [TimedWord]) {
        if let expect, loadedID != expect { throw ModelChanged(expected: expect, loaded: loadedID) }
        // The dictionary goes only to a model whose engine uses it (the same flag draws the card label).
        let words = loadedID.flatMap { ModelCatalog.model($0) }?.usesDictionary == true ? words : []
        running += 1
        defer { running -= 1 }
        if let cpp {
            Self.crashGuard.begin(loadedID ?? "", .run)
            defer { Self.crashGuard.end() }
            let backend = await Self.backendNow()
            if await Self.isBackground() {
                let paced = try await Self.paced(cpp, samples)
                await MainActor.run { ModelManager.shared.noteEngine(backend: "cpu", reloadSeconds: paced.reload) }
                return (paced.text.trimmingCharacters(in: .whitespacesAndNewlines), [])
            }
            var result = try await Task.detached(priority: .userInitiated) { try cpp.transcribe(samples, backend: backend) }.value
            var reload = result.loadSeconds
            // iOS can refuse Metal work once the app leaves the foreground, and ggml reports that only on its next
            // compute, so a Metal run that ends with the app no longer active is not trusted: it runs again on the CPU.
            if result.backend == .metal, await Self.backendNow() != .metal {
                result = try await Task.detached(priority: .userInitiated) { try cpp.transcribe(samples, backend: .cpu) }.value
                reload += result.loadSeconds
            }
            let used = result.backend.rawValue, reloaded = reload
            await MainActor.run { ModelManager.shared.noteEngine(backend: used, reloadSeconds: reloaded) }
            return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        if let parakeet {
            let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
            var audio = samples
            if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }
            vocabularyWords = await parakeet.prepareCustomVocabulary(words)
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            // Long audio in the background: FluidAudio's chunks run one at a time under the CPU budget (CoreMLPacer).
            let pacer = CoreMLPacer()
            await parakeet.setChunkPacer(pacer)
            let result: ASRResult
            do {
                // Build 23: Parakeet keeps to the same language where FluidAudio takes one (its 25 languages).
                let covered = Set(ModelCatalog.model(loadedID ?? "")?.languageCodes ?? ["en"])
                let pinned = Language(rawValue: await MainActor.run { Self.pinnedLanguage(supported: covered, automaticAllowed: false) } ?? "en")
                result = try await parakeet.transcribe(audio, decoderState: &state, language: pinned)
            } catch {
                await parakeet.setChunkPacer(nil)
                throw error
            }
            await parakeet.setChunkPacer(nil)
            pacer.logSummary(audioSeconds: Double(audio.count) / 16_000.0)
            vocabularyFlips = await parakeet.customVocabularyFlips
            let timings = buildWordTimings(from: result.tokenTimings ?? []).map { TimedWord($0.word, start: $0.startTime, end: $0.endTime) }
            return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), timings)
        }
        if let ane {
            // Our Whisper build: the setting's language, or Automatic (nil: detected once per dictation, 2026-11-03).
            let supported = ane.languageCodes
            let language = await MainActor.run { Self.pinnedLanguage(supported: supported, automaticAllowed: true) }
            vocabularyWords = 0
            vocabularyFlips = 0
            let text = try await Task.detached(priority: .userInitiated) { try ane.transcribe(samples, language: language) }.value
            lastLanguage = ane.lastLanguage
            let t = ane.lastTimings
            NSLog("FFMODEL whisper-ane lang=%@ bucket=%ds fallback=%d audio=%.1fs mel=%.0fms enc=%.0fms prefill=%.0fms dec=%.0fms total=%.0fms",
                  (language ?? "auto:") + (language == nil ? ane.lastLanguage : ""), ane.lastBucket, ane.lastFallback ? 1 : 0, Double(samples.count) / 16_000, (t["mel"] ?? 0) * 1000,
                  (t["encoder"] ?? 0) * 1000, (t["prefill"] ?? 0) * 1000, (t["decoder"] ?? 0) * 1000, (t["total"] ?? 0) * 1000)
            return (text, [])
        }
        if let whisper {
            // Build 23: one language for every window. WhisperKit with no language guessed it again for
            // each 30 s window and at each fallback temperature (sampled, so at random); one English dictation came out
            // Korean, then Spanish, then English. Pinned: the setting's language (the device's by default), or, with
            // Automatic, one guess from the start of this dictation used for all of it. Task: transcribe, never translate.
            // Build 26: the languages are the model's own (catalog), Whisper's full set when it lists none;
            // Automatic only when chosen; an unknown device language is English, never a guess (SpeechLanguage.pinned).
            let supported = whisper.textDecoder.isModelMultilingual
                ? ModelCatalog.languages(of: ModelCatalog.model(loadedID ?? ""), whisper: Constants.languageCodes) : ["en"]
            var language = await MainActor.run { Self.pinnedLanguage(supported: supported) }
            if language == nil {
                language = try? await whisper.detectLangauge(audioArray: samples).language   // WhisperKit spells it so
            }
            if language == nil || !supported.contains(language!) { language = supported.contains("en") ? "en" : supported.sorted().first }
            lastLanguage = language ?? "unknown"
            // Timestamps on (build 23, measured 10-31: off, a window Whisper ended early lost its tail, 189 of 280 words on a
            // 90 s clip; on, 293), so WhisperKit seeks from the last segment instead of skipping the rest of the window.
            var options = DecodingOptions(task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
                                          detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false)
            options.promptTokens = Self.whisperPrompt(words, tokenizer: whisper.tokenizer)
            vocabularyWords = options.promptTokens == nil ? 0 : words.count
            vocabularyFlips = 0
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            return (results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        throw FFError("No model is loaded.")
    }

    /// The language the last Whisper transcription was pinned to (for the measurement log).
    private(set) var lastLanguage = ""

    /// Settings > Speech language: nil = Automatic.
    @MainActor static func speechLanguage(supported: Set<String> = Constants.languageCodes) -> String? {
        SpeechLanguage.resolve(stored: UserDefaults.standard.string(forKey: SpeechLanguage.key),
                               preferred: Locale.preferredLanguages, supported: supported)
    }

    /// Build 26: the language the decoder is told (nil only when the person chose Automatic on a multilingual model).
    @MainActor static func pinnedLanguage(supported: Set<String>, automaticAllowed: Bool = true) -> String? {
        SpeechLanguage.pinned(stored: UserDefaults.standard.string(forKey: SpeechLanguage.key),
                              preferred: Locale.preferredLanguages, supported: supported, automaticAllowed: automaticAllowed)
    }

    /// Build 26: the languages a catalog model can be pinned to (Whisper: its full set).
    nonisolated static func languages(of id: String) -> Set<String> {
        ModelCatalog.languages(of: ModelCatalog.model(id), whisper: Constants.languageCodes)
    }

    /// The Settings list for the model in use: code and name, by name (build 23 listed Parakeet's 25 for every model).
    nonisolated static func languageChoices(for id: String) -> [(code: String, name: String)] {
        languages(of: id).map { (code: $0, name: Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.name < $1.name }
    }

    /// Dictionary words for the last transcription that the model actually used, and (Parakeet) how many decode steps
    /// they changed. For the measurement log only; never words.
    private(set) var vocabularyWords = 0
    private(set) var vocabularyFlips = 0

    /// Whisper's own way to know words: they go in as the previous-text prompt (OpenAI's "prompting" for uncommon
    /// spellings). Capped at 200 tokens (the decoder takes up to 224); the newest words are kept.
    static func whisperPrompt(_ words: [String], tokenizer: WhisperTokenizer?) -> [Int]? {
        guard !words.isEmpty, let tokenizer else { return nil }
        let ids = tokenizer.encode(text: " " + words.joined(separator: ", "))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return ids.isEmpty ? nil : Array(ids.suffix(200))
    }

    /// How Core ML plans to run each operation of every model file (Neural Engine, GPU or CPU),
    /// counted from MLComputePlan. This is Core ML's own plan, not a guess.
    static func computePlan(directory: URL) async -> [String: Int] {
        var counts: [String: Int] = [:]
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.pathExtension == "mlmodelc" {
            guard let plan = try? await MLComputePlan.load(contentsOf: url, configuration: config),
                  case .program(let program) = plan.modelStructure,
                  let main = program.functions["main"] else { continue }
            for op in main.block.operations {
                switch plan.deviceUsage(for: op)?.preferred {
                case .some(.cpu): counts["CPU", default: 0] += 1
                case .some(.gpu): counts["GPU", default: 0] += 1
                case .some(.neuralEngine): counts["Neural Engine", default: 0] += 1
                default: break
                }
            }
        }
        return counts
    }

    static var availableDevices: [String] {
        MLModel.availableComputeDevices.map { device -> String in
            switch device {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .neuralEngine: return "Neural Engine"
            @unknown default: return "Other"
            }
        }
    }
}
