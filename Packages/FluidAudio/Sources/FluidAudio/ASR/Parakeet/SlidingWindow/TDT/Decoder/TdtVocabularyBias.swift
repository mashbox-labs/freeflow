import Foundation

// Free Flow change (not in upstream FluidAudio): decode-time custom vocabulary for Parakeet TDT v3.
//
// The v3 joint (JointDecisionv3) returns its top-K token ids and logits at every decode step. FluidAudio's
// shallow-fusion biaser (NemotronVocabularyBias, written for the Nemotron streaming decoder) says which tokens would
// continue a vocabulary term from the text decoded so far, and by how much to boost each one (its own defaults:
// 4.5 log-prob, terms of 3+ characters, word-anchored). Here the boosted best inside the top-K replaces the plain
// pick only when its logit plus boost beats the plain pick's logit. A token outside the top-K is never chosen, and
// nothing is rewritten after decoding: the words come out of the decoder itself.
final class TdtVocabularyBias: @unchecked Sendable {
    // One decode at a time uses this (AsrManager is an actor and decodes sequentially).
    private let bias: NemotronVocabularyBias
    private var boosts: [Int: Float]?
    let words: [String]
    private(set) var flips = 0
    /// Counters for the measurement log: steps seen, steps without top-K, steps with no candidate, plain pick outside the top-K, last K, last candidate count.
    var pickSeconds = 0.0
    var stepCount = 0, noTopK = 0, noCandidates = 0, plainOutside = 0, lastK = 0, lastCandidates = 0
    var debugLine: String { "steps=\(stepCount) noTopK=\(noTopK) noCand=\(noCandidates) plainOutside=\(plainOutside) K=\(lastK) cands=\(lastCandidates) flips=\(flips) bias_ms=\(String(format: "%.2f", pickSeconds * 1000))" }

    init?(words: [String], pieces: [Int: String]) {
        guard !pieces.isEmpty,
            let bias = NemotronVocabularyBias(
                terms: words.map { CustomVocabularyTerm(text: $0) }, pieces: Self.sentencePieceForm(pieces))
        else { return nil }
        self.bias = bias
        self.words = words
    }

    /// parakeet_vocab.json writes a word start as a leading space (" the"). The biaser expects the SentencePiece
    /// marker U+2581 ("\u{2581}the"). Without this, no piece matched a word start: 0 candidates, and the first
    /// proof run changed nothing.
    static func sentencePieceForm(_ pieces: [Int: String]) -> [Int: String] {
        pieces.mapValues { $0.hasPrefix(" ") ? "\u{2581}" + $0.dropFirst() : $0 }
    }

    /// A token the decoder emitted (fed back to its predictor).
    func observe(_ tokenId: Int) {
        bias.observe(tokenId)
        boosts = nil
    }

    /// Start of a new utterance.
    func reset() {
        bias.resetMatchState()
        boosts = nil
        flips = 0
        pickSeconds = 0
        stepCount = 0; noTopK = 0; noCandidates = 0; plainOutside = 0
    }

    private func currentBoosts() -> [Int: Float] {
        if let boosts { return boosts }
        let map = Dictionary(bias.candidates().map { ($0.tokenId, $0.boost) }, uniquingKeysWith: { max($0, $1) })
        boosts = map
        return map
    }

    /// The biased pick among the top-K, or nil when the plain pick stands.
    /// Returns the picked id and its probability within the top-K (softmax over the K logits).
    func pick(plain: Int, topKIds: [Int], topKLogits: [Float]) -> (id: Int, probability: Float)? {
        stepCount += 1
        guard topKIds.count == topKLogits.count, !topKIds.isEmpty else { noTopK += 1; return nil }
        lastK = topKIds.count
        let map = currentBoosts()
        lastCandidates = map.count
        guard !map.isEmpty else { noCandidates += 1; return nil }
        var plainLogit: Float?
        var bestId = -1
        var bestScore = -Float.infinity
        var bestLogit: Float = 0
        var maxLogit = -Float.infinity
        for (i, id) in topKIds.enumerated() {
            let logit = topKLogits[i]
            maxLogit = max(maxLogit, logit)
            if id == plain { plainLogit = logit }
            if let boost = map[id], logit + boost > bestScore {
                bestScore = logit + boost
                bestId = id
                bestLogit = logit
            }
        }
        if plainLogit == nil { plainOutside += 1 }
        guard let plainLogit, bestId >= 0, bestId != plain, bestScore > plainLogit else { return nil }
        var sum: Float = 0
        for logit in topKLogits { sum += expf(logit - maxLogit) }
        flips += 1
        return (bestId, expf(bestLogit - maxLogit) / max(sum, .leastNormalMagnitude))
    }
}

extension TdtDecoderV3 {
    static func applyVocabularyBias(
        label: inout Int, score: inout Float, topKIds: [Int]?, topKLogits: [Float]?, bias: TdtVocabularyBias?
    ) {
        guard let bias else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { bias.pickSeconds += CFAbsoluteTimeGetCurrent() - t0 }
        guard let ids = topKIds, let logits = topKLogits else { bias.stepCount += 1; bias.noTopK += 1; return }
        guard let picked = bias.pick(plain: label, topKIds: ids, topKLogits: logits)
        else { return }
        label = picked.id
        score = TdtDurationMapping.clampProbability(picked.probability)
    }
}

extension AsrManager {
    /// Free Flow change: the words the TDT v3 decoder leans toward for the next transcription (empty = none).
    /// Rebuilds only when the words change; always starts a fresh match state. Returns the number of words in use
    /// (0 when the loaded model has no top-K joint or no usable word).
    @discardableResult
    public func prepareCustomVocabulary(_ words: [String]) -> Int {
        if words.isEmpty {
            tdtVocabularyBias = nil
            return 0
        }
        if tdtVocabularyBias?.words != words {
            tdtVocabularyBias = TdtVocabularyBias(words: words, pieces: vocabulary)
        }
        tdtVocabularyBias?.reset()
        return tdtVocabularyBias == nil ? 0 : words.count
    }

    /// Free Flow change: how many decode steps the vocabulary changed in the last transcription.
    public var customVocabularyFlips: Int { tdtVocabularyBias?.flips ?? 0 }
    public var customVocabularyDebug: String { tdtVocabularyBias?.debugLine ?? "no-bias" }
}
