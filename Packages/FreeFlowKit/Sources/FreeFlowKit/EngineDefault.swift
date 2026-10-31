import Foundation

/// Which speech engine Free Flow uses. 2026-10-29: the default went back to Core ML for CPU efficiency, with the C++
/// engine as the fallback.
/// Core ML (Neural Engine) is the default for every device it works on. The C++ (ggml) engine is the fallback when
/// Core ML can't load a model on a device, and a manual pick in Settings > Models. Nobody is moved between engines.
public enum EngineDefault {
    /// Parakeet TDT 0.6B v3 Q4_0 on the C++ engine: the fallback when Core ML fails.
    public static let cppFallbackID = "parakeet-gguf-q4_0"

    /// The model a fresh install uses: the Core ML recommendation for this memory and language.
    public static func model(memoryBytes: UInt64, language: String = ModelCatalog.currentLanguage,
                             in models: [SpeechModel] = ModelCatalog.all) -> SpeechModel {
        ModelCatalog.recommended(memoryBytes: memoryBytes, language: language, in: models)
    }

    /// After a Core ML model failed to load on this device: the C++ fallback when its file is already on the device,
    /// fits this memory and covers the language; nil otherwise (the error stands). A failed C++ model never falls back
    /// here (CppCrashGuard handles C++ crashes).
    public static func fallback(after failedID: String, readyIDs: Set<String>, memoryBytes: UInt64,
                                language: String = ModelCatalog.currentLanguage,
                                in models: [SpeechModel] = ModelCatalog.all) -> SpeechModel? {
        guard let failed = models.first(where: { $0.id == failedID }), !failed.engine.isCpp,
              let cpp = models.first(where: { $0.id == cppFallbackID }), readyIDs.contains(cpp.id),
              cpp.fits(memoryBytes: memoryBytes), cpp.covers(language: language) else { return nil }
        return cpp
    }

    /// Build 23: after a Core ML model failed to load on this device (FluidAudio #828: an int8 encoder, like Parakeet
    /// Ultra's, did not load on an A16 iPhone on any compute unit), the Core ML model to move to: one already on the
    /// device that covers the language first (dictation works at once), else the recommendation without the models that
    /// failed here (it asks for its download). Nil when nothing else fits.
    public static func coreMLFallback(after failedID: String, failedIDs: Set<String>, readyIDs: Set<String>, memoryBytes: UInt64,
                                      language: String = ModelCatalog.currentLanguage,
                                      in models: [SpeechModel] = ModelCatalog.all) -> SpeechModel? {
        let failed = failedIDs.union([failedID])
        let usable = models.filter { !$0.engine.isCpp && !failed.contains($0.id) && $0.fits(memoryBytes: memoryBytes) }
        guard !usable.isEmpty else { return nil }
        if let ready = usable.filter({ readyIDs.contains($0.id) && $0.covers(language: language) })
            .max(by: { ($0.preference, $1.downloadBytes) < ($1.preference, $0.downloadBytes) }) {
            return ready
        }
        let pick = ModelCatalog.recommended(memoryBytes: memoryBytes, language: language, in: usable)
        return failed.contains(pick.id) ? nil : pick
    }

    /// The one line Home shows after a Core ML model moved to another.
    public static func coreMLFallbackNotice(failed: String, to next: SpeechModel, downloaded: Bool, device: String) -> String {
        "Core ML could not load \(failed) on this \(device), so Free Flow now uses \(next.name)."
            + (downloaded ? "" : " Download it in Models (\(Int((Double(next.downloadBytes) / 1_000_000).rounded())) MB).")
    }

    /// The one line Home shows after a fallback.
    public static func fallbackNotice(failed: String, to cpp: SpeechModel) -> String {
        "Core ML could not load \(failed) on this device, so dictation uses \(cpp.name) on the C++ engine."
    }
}
