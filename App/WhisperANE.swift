import Compression
import CoreML
import Foundation

/// Whisper large-v3-turbo on the Neural Engine, our own Core ML build:
/// MelSpectrogram (CPU) -> AudioEncoder (ANE, one function per length bucket, emits the cross-attention K/V of the 4
/// decoder layers) -> TextDecoder (ANE, stateful self-attention K/V, one function per bucket for 1 and 8 tokens).
/// Greedy decoding with Whisper's suppress lists; the length-bucket ladder with OpenAI's compression-ratio fallback
/// (gzip ratio > 2.4 or the token cap -> decode again on the 30 s window). Same algorithm as our reference
/// runner.
final class WhisperANE {
    struct Manifest: Decodable {
        let model: String
        let buckets: [Int]
        let d_model: Int
        let ctx: Int
        let vocab: Int
        let verify_s: Int
        let sot: Int
        let eot: Int
        let transcribe: Int
        let notimestamps: Int
        let lang_ids: [String: Int]
        let suppress: [Int]
        let begin_suppress: [Int]
        /// true: AudioEncoder and TextDecoder are each ONE function with enumerated input shapes (every bucket, 1 and
        /// 8 tokens). The Neural Engine then keeps one copy of the weights instead of one per function.
        let one_program: Bool?
    }

    let directory: URL
    let manifest: Manifest
    let buckets: [Int]
    let onePrograms: Bool
    private var mels: [Int: MLModel] = [:], encoders: [Int: MLModel] = [:], dec1: [Int: MLModel] = [:], decK: [Int: MLModel] = [:]
    private let embed: [Float16], positions: [Float16]
    private let idToToken: [Int: String]
    private let unicodeToByte: [Character: UInt8]
    /// Token cap per window.
    let maxTokens = 440
    /// Seconds of the last run, per stage, for the log.
    private(set) var lastTimings: [String: Double] = [:]
    private(set) var lastBucket = 0
    private(set) var lastFallback = false
    private(set) var lastLanguage = ""

    /// `buckets`: the length buckets to load (nil = all in the manifest). With one function per bucket, each encoder
    /// function keeps its own compiled copy of the weights on the Neural Engine, so an iPhone loads fewer. A one-program
    /// build holds one copy for every bucket, so it loads them all unless `forced` (the FF_ANE_BUCKETS test switch).
    init(directory: URL, buckets wanted: [Int]? = nil, forced: Bool = false, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        self.directory = directory
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        onePrograms = manifest.one_program == true
        let all = manifest.buckets
        let limit = onePrograms && !forced ? nil : wanted
        var use = limit.map { w in all.filter { w.contains($0) } } ?? all
        if use.isEmpty || !use.contains(all.last!) { use.append(all.last!) }   // the full window is always there (fallback)
        buckets = use.sorted()
        func f16(_ name: String) throws -> [Float16] {
            let d = try Data(contentsOf: directory.appendingPathComponent(name))
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        }
        embed = try f16("embed_tokens.f16")
        positions = try f16("embed_positions.f16")
        let vocab = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("vocab.json"))) as? [String: Int] ?? [:]
        var inv: [Int: String] = [:]
        for (k, v) in vocab { inv[v] = k }
        idToToken = inv
        // GPT-2 bytes_to_unicode, inverted.
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs, n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var u2b: [Character: UInt8] = [:]
        for (b, c) in zip(bs, cs) { u2b[Character(Unicode.Scalar(c)!)] = UInt8(b) }
        unicodeToByte = u2b
        func load(_ package: String, _ function: String?, _ units: MLComputeUnits) throws -> MLModel {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units
            cfg.functionName = function
            return try MLModel(contentsOf: directory.appendingPathComponent(package), configuration: cfg)
        }
        for b in buckets {
            mels[b] = try load("MelSpectrogram.mlmodelc", "mel_\(b)s", .cpuOnly)
            if onePrograms {
                // One instance per input shape: instances of the same program share its one Neural Engine copy, and
                // an instance that keeps one shape never reconfigures between calls (a shared one was 18-33% slower).
                encoders[b] = try load("AudioEncoder.mlmodelc", nil, computeUnits)
                dec1[b] = try load("TextDecoder.mlmodelc", nil, computeUnits)
                decK[b] = try load("TextDecoder.mlmodelc", nil, computeUnits)
            } else {
                encoders[b] = try load("AudioEncoder.mlmodelc", "enc_\(b)s", computeUnits)
                dec1[b] = try load("TextDecoder.mlmodelc", "dec_\(b)s_s1", computeUnits)
                decK[b] = try load("TextDecoder.mlmodelc", "dec_\(b)s_s\(manifest.verify_s)", computeUnits)
            }
        }
    }

    var languageCodes: Set<String> { Set(manifest.lang_ids.keys) }

    /// Transcribes 16 kHz mono samples (up to 30 s; longer audio is cut into 30 s pieces) in `language` (a Whisper
    /// code). Greedy, the smallest bucket that fits first, the 30 s window again when the text looks degenerate.
    /// `language` nil = Automatic: Whisper's language detection on the first piece, then that language for the whole
    /// dictation (never re-guessed per window). The language used is in lastLanguage.
    func transcribe(_ samples: [Float], language: String?) throws -> String {
        var language = language
        let window = buckets.last! * 16_000
        var pieces: [String] = []
        var timings: [String: Double] = [:]
        var start = 0
        lastFallback = false
        while start < samples.count || pieces.isEmpty {
            let piece = Array(samples[start..<min(start + window, samples.count)])
            let bucket = buckets.first { piece.count <= $0 * 16_000 } ?? buckets.last!
            var (ids, t, used) = try run(piece, bucket: bucket, language: language)
            language = used; lastLanguage = used
            var text = decode(ids)
            if bucket != buckets.last!, compressionRatio(text) > 2.4 || ids.count >= maxTokens {
                let again = try run(piece, bucket: buckets.last!, language: language)    // the language just used
                for (k, v) in again.t { t[k, default: 0] += v }
                ids = again.ids; text = decode(ids); lastFallback = true
            }
            lastBucket = bucket
            for (k, v) in t { timings[k, default: 0] += v }
            pieces.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            start += window
        }
        lastTimings = timings
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func array(_ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    }

    /// fp16 [1, R, 1, T] with a padded row stride -> contiguous, one memcpy per row.
    private func packRows(_ m: MLMultiArray) throws -> MLMultiArray {
        let shape = m.shape.map(\.intValue), strides = m.strides.map(\.intValue)
        guard m.dataType == .float16, shape.count == 4, shape[0] == 1, shape[2] == 1, strides[3] == 1 else { return try contiguous(m) }
        let R = shape[1], T = shape[3]
        let out = try array(shape, .float16)
        let src = m.dataPointer.bindMemory(to: Float16.self, capacity: R * strides[1])
        let dst = out.dataPointer.bindMemory(to: Float16.self, capacity: R * T)
        if strides[1] == T { memcpy(dst, src, R * T * 2) } else { for r in 0..<R { memcpy(dst + r * T, src + r * strides[1], T * 2) } }
        return out
    }

    /// A contiguous fp16 copy (Neural Engine outputs can carry padded strides).
    private func contiguous(_ m: MLMultiArray) throws -> MLMultiArray {
        let shape = m.shape.map(\.intValue), strides = m.strides.map(\.intValue)
        let out = try array(shape, .float16)
        let dst = out.dataPointer.bindMemory(to: Float16.self, capacity: m.count)
        var idx = [Int](repeating: 0, count: shape.count)
        let src16 = m.dataType == .float16 ? m.dataPointer.bindMemory(to: Float16.self, capacity: 1) : nil
        let src32 = m.dataType == .float32 ? m.dataPointer.bindMemory(to: Float.self, capacity: 1) : nil
        for i in 0..<m.count {
            var off = 0
            for k in 0..<shape.count { off += idx[k] * strides[k] }
            dst[i] = src16?[off] ?? Float16(src32?[off] ?? 0)
            var k = shape.count - 1
            while k >= 0 { idx[k] += 1; if idx[k] < shape[k] { break }; idx[k] = 0; k -= 1 }
        }
        return out
    }

    private func inputs(_ tokens: [Int], position p0: Int, width S: Int, cross: MLMultiArray) throws -> MLDictionaryFeatureProvider {
        let C = manifest.d_model, CTX = manifest.ctx
        let x = try array([1, C, 1, S], .float16), mask = try array([1, 1, S, CTX], .float16), wr = try array([S, CTX], .float16)
        let xp = x.dataPointer.bindMemory(to: Float16.self, capacity: C * S)
        let mp = mask.dataPointer.bindMemory(to: Float16.self, capacity: S * CTX)
        let wp = wr.dataPointer.bindMemory(to: Float16.self, capacity: S * CTX)
        for j in 0..<S {
            let t = j < tokens.count ? tokens[j] : manifest.eot
            let p = min(p0 + j, CTX - 1)
            for c in 0..<C { xp[c * S + j] = Float16(Float(embed[t * C + c]) + Float(positions[p * C + c])) }
            for k in 0..<CTX { mp[j * CTX + k] = k <= p ? 0 : -10000; wp[j * CTX + k] = k == p ? 1 : 0 }
        }
        return try MLDictionaryFeatureProvider(dictionary: ["x": x, "cross_kv": cross, "mask": mask, "wr": wr])
    }

    private func argmax(_ logits: MLMultiArray, column j: Int, first: Bool) -> Int {
        let V = manifest.vocab, strides = logits.strides.map(\.intValue)
        let p = logits.dataPointer.bindMemory(to: Float16.self, capacity: 1)
        var l = [Float](repeating: 0, count: V)
        for v in 0..<V { l[v] = Float(p[v * strides[1] + j * strides[3]]) }
        for s in manifest.suppress where s < V { l[s] = -.infinity }
        if first { for s in manifest.begin_suppress where s < V { l[s] = -.infinity } }
        var best = 0, bestV = -Float.infinity
        for (i, v) in l.enumerated() where v > bestV { bestV = v; best = i }
        return best
    }

    private func run(_ audio: [Float], bucket b: Int, language: String?) throws -> (ids: [Int], t: [String: Double], lang: String) {
        let tA = Date()
        let N = b * 16_000
        let ain = try array([1, N], .float32)
        let ap = ain.dataPointer.bindMemory(to: Float.self, capacity: N)
        for i in 0..<N { ap[i] = i < audio.count ? audio[i] : 0 }
        guard let mel = try mels[b]!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": ain])).featureValue(for: "mel")?.multiArrayValue
        else { throw FFError("Whisper: no mel output") }
        let mel16 = try contiguous(mel)
        let tB = Date()
        guard let encoded = try encoders[b]!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": mel16])).featureValue(for: "cross_kv")?.multiArrayValue
        else { throw FFError("Whisper: no encoder output") }
        // The encoder pads each cross_kv row (stride 512 for 500 frames); a one-program decoder would repack that on
        // every token, so pack it once here (a memcpy per row, 1-4 ms).
        let cross = onePrograms ? try packRows(encoded) : encoded
        let tC = Date()
        let state = dec1[b]!.makeState()
        var code: String, p0 = 0, prompt: [Int]
        if let language {
            guard let lang = manifest.lang_ids[language] else { throw FFError("Whisper: unknown language \(language)") }
            code = language
            prompt = [manifest.sot, lang, manifest.transcribe, manifest.notimestamps]
        } else {
            // Language detection as OpenAI's Whisper does it: the start token alone, then the most likely language token.
            guard let o0 = try dec1[b]!.prediction(from: inputs([manifest.sot], position: 0, width: 1, cross: cross), using: state)
                .featureValue(for: "logits")?.multiArrayValue else { throw FFError("Whisper: no logits") }
            let st = o0.strides.map(\.intValue), lp = o0.dataPointer.bindMemory(to: Float16.self, capacity: 1)
            var best = ("en", -Float.infinity)
            for (c, id) in manifest.lang_ids where id < manifest.vocab {
                let v = Float(lp[id * st[1]]); if v > best.1 { best = (c, v) }
            }
            code = best.0
            p0 = 1
            prompt = [manifest.lang_ids[code]!, manifest.transcribe, manifest.notimestamps]
        }
        var ids: [Int] = []
        guard let o = try decK[b]!.prediction(from: inputs(prompt, position: p0, width: manifest.verify_s, cross: cross), using: state)
            .featureValue(for: "logits")?.multiArrayValue else { throw FFError("Whisper: no logits") }
        var t = argmax(o, column: prompt.count - 1, first: true)
        let tD = Date()
        var p = p0 + prompt.count
        while t != manifest.eot, ids.count < maxTokens, p < manifest.ctx - 1 {
            ids.append(t)
            try autoreleasepool {
                guard let o1 = try dec1[b]!.prediction(from: inputs([t], position: p, width: 1, cross: cross), using: state)
                    .featureValue(for: "logits")?.multiArrayValue else { throw FFError("Whisper: no logits") }
                t = argmax(o1, column: 0, first: false)
            }
            p += 1
        }
        let tE = Date()
        return (ids, ["mel": tB.timeIntervalSince(tA), "encoder": tC.timeIntervalSince(tB), "prefill": tD.timeIntervalSince(tC),
                      "decoder": tE.timeIntervalSince(tD), "total": tE.timeIntervalSince(tA)], code)
    }

    /// Byte-level BPE decode of the text tokens (every special token is dropped).
    func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for i in ids where i < manifest.eot {
            guard let tok = idToToken[i] else { continue }
            for ch in tok { if let b = unicodeToByte[ch] { bytes.append(b) } }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// OpenAI's compression-ratio check (transcribe.py: zlib on the UTF-8 text). The Compression framework gives the
    /// raw deflate stream; zlib's 6 framing bytes are added so the ratio matches the reference runner's.
    func compressionRatio(_ s: String) -> Double {
        let src = Array(s.utf8)
        guard !src.isEmpty else { return 0 }
        let cap = src.count + 64
        var dst = [UInt8](repeating: 0, count: cap)
        let n = src.withUnsafeBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                compression_encode_buffer(dp.baseAddress!, cap, sp.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return 0 }
        return Double(src.count) / Double(n + 6)
    }
}
