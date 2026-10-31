import CoreML
import Foundation
import FreeFlowKit
import FreeFlowRules

/// Scores each word of an English line with the probability that it is a disfluency, by class:
/// reparandum (the words a speaker abandoned or corrected), filler sound, editing term ("I mean", "no wait"),
/// discourse marker ("you know", "well"). Runs on the device with Core ML; nothing leaves the phone.
public final class DisfluencyTagger: DisfluencyScorer, @unchecked Sendable {
    public static let shared = DisfluencyTagger()

    private let lock = NSLock()
    private var model: MLModel?
    private var wordPiece: WordPiece?
    private var loadFailed = false
    /// Class order of the model's output, from tagger.json.
    private var labels: [String] = ["O", "R", "F", "E", "D"]
    public private(set) var thresholds: [String: Float] = [:]
    public let maxLength = 256

    public init() {}

    /// Loads the model once. Safe to call early (e.g. when the app becomes active) to hide the load time.
    @discardableResult
    public func load(computeUnits: MLComputeUnits = .all) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if model != nil { return true }
        if loadFailed { return false }
        do {
            guard let m = Bundle.module.url(forResource: "DisfluencyTagger", withExtension: "mlmodelc"),
                  let v = Bundle.module.url(forResource: "vocab", withExtension: "txt"),
                  let c = Bundle.module.url(forResource: "tagger", withExtension: "json") else { loadFailed = true; return false }
            let config = MLModelConfiguration(); config.computeUnits = computeUnits
            model = try MLModel(contentsOf: m, configuration: config)
            wordPiece = try WordPiece(vocabURL: v)
            if let j = try JSONSerialization.jsonObject(with: Data(contentsOf: c)) as? [String: Any] {
                labels = j["labels"] as? [String] ?? labels
                thresholds = (j["thresholds"] as? [String: Double] ?? [:]).mapValues(Float.init)
            }
            return true
        } catch { loadFailed = true; return false }
    }

    /// Per-word class probabilities keyed by label ("R", "F", "E", "D"; "O" = keep). nil if the model is unavailable.
    public func scores(words: [String]) -> [[String: Float]]? {
        guard !words.isEmpty, load() else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let model, let wordPiece else { return nil }
        let (ids, first) = wordPiece.encode(words, maxLength: maxLength)
        let n = ids.count
        // One line at a time, no padding, so the model needs no attention mask.
        guard let idArr = try? MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32) else { return nil }
        for i in 0..<n { idArr[i] = NSNumber(value: ids[i]) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": idArr]),
              let out = try? model.prediction(from: input),
              let logits = out.featureValue(for: "logits")?.multiArrayValue else { return nil }
        let k = labels.count
        return first.map { idx -> [String: Float] in
            guard let idx else { return ["O": 1] }
            var row = [Float](repeating: 0, count: k)
            for c in 0..<k { row[c] = logits[[0, NSNumber(value: idx), NSNumber(value: c)] as [NSNumber]].floatValue }
            let m = row.max() ?? 0
            let e = row.map { expf($0 - m) }; let s = e.reduce(0, +)
            var d: [String: Float] = [:]
            for c in 0..<k { d[labels[c]] = e[c] / s }
            return d
        }
    }

    public func threshold(for level: CleanupLevel) -> Float {
        thresholds[level.rawValue] ?? 0.5
    }
}
