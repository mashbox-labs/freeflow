import FluidAudio
import FreeFlowKit
import Foundation

/// Parakeet TDT 0.6B v3 on Core ML (FluidAudio), the iPhone app's default speech model. 16 kHz mono in, text out. The
/// user's dictionary words go in as Parakeet's decode-time boost, as on iPhone; nothing rewrites the text afterwards.
/// No audio leaves the process.
actor MacTranscriber {
    static let shared = MacTranscriber()
    private var manager: AsrManager?
    private var decoderLayers = 2
    private var loading: Task<Double, Error>?

    /// Loads the model once; returns the seconds the load took (0 when it was already loaded).
    @discardableResult
    func load() async throws -> Double {
        if manager != nil { return 0 }
        if let loading { return try await loading.value }
        let task = Task<Double, Error> {
            let start = Date()
            let models = try await AsrModels.load(from: MacModels.directory(MacModels.speechID), version: .v3)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            self.installed(m, layers: await m.decoderLayerCount)
            return Date().timeIntervalSince(start)
        }
        loading = task
        defer { loading = nil }
        return try await task.value
    }

    private func installed(_ m: AsrManager, layers: Int) {
        manager = m
        decoderLayers = layers
    }

    func transcribe(_ samples: [Float], words: [String]) async throws -> String {
        try await load()
        guard let manager else { throw FFError("The speech model is not loaded.") }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        var audio = samples
        if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }
        _ = await manager.prepareCustomVocabulary(words)
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
