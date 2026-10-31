import CoreML
import FluidAudio
import Foundation
import WhisperKit

// asrbench --model medium|small|large --data DIR --split dev|heldout|all --out FILE.jsonl
// Same calls as App/Transcriber.swift: Parakeet v3 through FluidAudio, Whisper through WhisperKit
// with temperature 0, language detection on, no timestamps.
struct Clip: Decodable { let id: String; let split: String }

let args = CommandLine.arguments
func arg(_ key: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: key), i + 1 < args.count { return args[i + 1] }
    return fallback
}
let model = arg("--model", "medium")
let data = URL(fileURLWithPath: arg("--data", NSHomeDirectory() + "/Developer/freeflow-clean-data"))
let split = arg("--split", "all")
let outPath = arg("--out", "asr-\(model).jsonl")
// Build 23: the app's dictionary prompt (--words "A, B"), language ("auto" = the old per-window guess, "once" = one guess
// per clip, else a code) and Whisper timestamps (--timestamps 1: WhisperKit's long-form seek), as in App/Transcriber.swift.
let words = arg("--words", "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
let languageArg = arg("--language", "en")
let timestamps = arg("--timestamps", "0") == "1"
func whisperPrompt(_ words: [String], tokenizer: WhisperTokenizer?) -> [Int]? {
    guard !words.isEmpty, let tokenizer else { return nil }
    let ids = tokenizer.encode(text: " " + words.joined(separator: ", ")).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    return ids.isEmpty ? nil : Array(ids.suffix(200))
}
let modelsDir = data.appendingPathComponent("models")

let manifest = try String(contentsOf: data.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
let clips = try manifest.split(separator: "\n").map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
    .filter { split == "all" || $0.split == split }

let loadStart = Date()
var parakeet: AsrManager?
var layers = 2
var whisper: WhisperKit?
var unified: UnifiedAsrManager?
// Build 23: the Parakeet family, each from models/<id> with the FluidAudio version the app uses (App/Transcriber.swift).
// Build 23 (FluidAudio v0.18.0): each model loads from its own folder, as the app does (AsrModels.loadLocal), offline.
let parakeetFamily: [String: AsrModelVersion] = [
    "medium": .v3, "parakeet-ultra": .ultra, "parakeet-redux": .redux, "phonon-2": .phonon2, "bark-3.0-clean": .bark3Clean,
    "bark-3-pro": .ultra]
/// As App/Transcriber.compilePackages: .mlpackage files compiled once into .mlmodelc next to them, the package removed,
/// Conway's vocabulary copied (bytes unchanged) under the name FluidAudio reads.
func compilePackages(in directory: URL) async throws {
    let fm = FileManager.default
    for name in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter({ $0.hasSuffix(".mlpackage") }).sorted() {
        let package = directory.appendingPathComponent(name)
        let compiledURL = directory.appendingPathComponent((name as NSString).deletingPathExtension + ".mlmodelc")
        if !fm.fileExists(atPath: compiledURL.path) {
            let t0 = Date()
            let temporary = try await MLModel.compileModel(at: package)
            try fm.moveItem(at: temporary, to: compiledURL)
            FileHandle.standardError.write("compiled \(name) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n".data(using: .utf8)!)
        }
        try fm.removeItem(at: package)
    }
    let vocabulary = directory.appendingPathComponent("parakeet_vocab.json")
    let v3Vocabulary = directory.appendingPathComponent("parakeet_v3_vocab.json")
    if !fm.fileExists(atPath: vocabulary.path), fm.fileExists(atPath: v3Vocabulary.path) { try fm.copyItem(at: v3Vocabulary, to: vocabulary) }
}
ModelHub.offlineMode = true      // as the app: never fetch, a missing file throws
let neuralEngine = MLModelConfiguration()
neuralEngine.computeUnits = .cpuAndNeuralEngine
if let version = parakeetFamily[model] {
    let dir = modelsDir.appendingPathComponent(model == "medium" ? "parakeet-tdt-0.6b-v3" : model)
    FileHandle.standardError.write("from \(dir.path)\n".data(using: .utf8)!)
    try await compilePackages(in: dir)
    let models = try AsrModels.loadLocal(from: dir, version: version)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    layers = await manager.decoderLayerCount
    parakeet = manager
} else if model == "nemotron-unified" {
    // NVIDIA Nemotron Labs Unified ASR 0.6B, offline 15 s encoder (fp16), language prompt pinned like the others.
    let code = languageArg == "auto" || languageArg == "once" ? "auto" : languageArg
    let manager = UnifiedAsrManager(configuration: neuralEngine,
                                    config: UnifiedConfig(family: .nemotronMultilingual(NemotronUnifiedLanguage(rawValue: code) ?? .en)),
                                    encoderPrecision: .fp16)
    try await manager.loadModels(from: modelsDir.appendingPathComponent(model))
    unified = manager
} else {
    let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
    let config = WhisperKitConfig(modelFolder: modelsDir.appendingPathComponent("\(model)/model").path,
                                  tokenizerFolder: modelsDir.appendingPathComponent("\(model)/tokenizer"),
                                  computeOptions: compute, verbose: false, logLevel: .error,
                                  prewarm: false, load: true, download: false)
    whisper = try await WhisperKit(config)
}
FileHandle.standardError.write("loaded \(model) in \(String(format: "%.2f", Date().timeIntervalSince(loadStart))) s; \(clips.count) clips\n".data(using: .utf8)!)

let converter = AudioConverter()
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
for clip in clips {
    let samples = try converter.resampleAudioFile(data.appendingPathComponent("wav/\(clip.id).wav"))
    let start = Date()
    var text = ""
    var langs = ""
    if let unified {
        text = try await unified.transcribe(samples)
        langs = "no-dictionary"
    } else if let parakeet {
        var audio = samples
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: layers)
        _ = await parakeet.prepareCustomVocabulary(words)
        let pinned = languageArg == "auto" || languageArg == "once" ? nil : Language(rawValue: languageArg)
        text = try await parakeet.transcribe(audio, decoderState: &state, language: pinned).text
        langs = await parakeet.customVocabularyDebug      // build 23: what the dictionary boost did (steps, candidates, flips)
    } else if let whisper {
        var options: DecodingOptions
        if languageArg == "auto" {      // build 22: no language, guessed per window and per fallback temperature
            options = DecodingOptions(task: .transcribe, temperature: 0, detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: !timestamps)
        } else {
            var language: String? = languageArg
            if languageArg == "once" { language = try? await whisper.detectLangauge(audioArray: samples).language }
            options = DecodingOptions(task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true, detectLanguage: false,
                                      skipSpecialTokens: true, withoutTimestamps: !timestamps)
        }
        options.promptTokens = whisperPrompt(words, tokenizer: whisper.tokenizer)
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        text = results.map(\.text).joined(separator: " ")
        // Which language each 30 s window ran in (the build 22 bug: Korean, Spanish, English in one dictation).
        langs = results.map(\.language).joined(separator: ",")
    }
    let row: [String: Any] = ["id": clip.id, "split": clip.split, "model": model,
                              "text": text.trimmingCharacters(in: .whitespacesAndNewlines),
                              "audio_s": Double(samples.count) / 16_000, "proc_s": Date().timeIntervalSince(start),
                              "langs": langs, "words": words.count, "language": languageArg, "timestamps": timestamps]
    out.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    out.write("\n".data(using: .utf8)!)
}
try out.close()
FileHandle.standardError.write("done \(model)\n".data(using: .utf8)!)
