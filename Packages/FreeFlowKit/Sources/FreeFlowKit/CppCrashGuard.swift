import Foundation

/// Crash-loop guard for the C++ (GGUF) engine. A marker file is written before every GGUF load or run and removed
/// when the call returns, with text or with an error. If Free Flow dies in between (a crash inside ggml or Metal, or
/// iOS ending the app for memory), the marker is still there at the next launch. That launch moves dictation back to
/// Core ML and says so in one line, so a model that kills the app cannot kill it again at every start, and the
/// keyboard keeps working on Core ML.
/// A file and not UserDefaults: the file is on disk before ggml is called, while a defaults write may still be on its
/// way to the preferences daemon when the process dies.
public struct CppCrashGuard: Sendable {
    public enum Phase: String, Codable, Sendable { case load, run }

    public struct Marker: Codable, Equatable, Sendable {
        public let modelID: String?
        public let phase: Phase?
        public init(modelID: String?, phase: Phase?) { self.modelID = modelID; self.phase = phase }
    }

    public let url: URL
    public init(url: URL) { self.url = url }

    /// Called right before ggml touches the model. Synchronous and atomic, so a crash a moment later still finds it.
    public func begin(_ modelID: String, _ phase: Phase) {
        guard let data = try? JSONEncoder().encode(Marker(modelID: modelID, phase: phase)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Called when the load or run returned (with a result or an error): nothing died.
    public func end() { try? FileManager.default.removeItem(at: url) }

    /// At launch: the marker a process left behind when it died inside a GGUF load or run. Removed as it is read, so
    /// the fallback happens once per crash. A marker that cannot be read (cut off mid-write) still counts.
    public func takeCrash() -> Marker? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        defer { end() }
        let data = try? Data(contentsOf: url)
        return data.flatMap { try? JSONDecoder().decode(Marker.self, from: $0) } ?? Marker(modelID: nil, phase: nil)
    }

    /// Where dictation goes after a crash. A Core ML pick stays. A C++ pick moves to the best Core ML model already on
    /// the device (this device's recommendation first, then the picker's order), so the keyboard works at once; with
    /// none on the device, to the recommendation, which then asks for its download as on a first run.
    public static func fallback(activeID: String, readyIDs: Set<String>, memoryBytes: UInt64,
                                in models: [SpeechModel] = ModelCatalog.all) -> String {
        if let active = models.first(where: { $0.id == activeID }), !active.engine.isCpp { return activeID }
        let recommended = ModelCatalog.recommended(memoryBytes: memoryBytes, in: models)
        let coreML = models.filter { !$0.engine.isCpp }
        let onDevice = ModelCatalog.pickerOrder(recommended: recommended, in: coreML)
            .first { readyIDs.contains($0.id) && $0.fits(memoryBytes: memoryBytes) }
        return (onDevice ?? recommended).id
    }

    /// The one line the app shows after a fallback.
    public static func notice(for marker: Marker, fallbackName: String) -> String {
        let what = marker.modelID.flatMap { ModelCatalog.model($0)?.name } ?? "a C++ model"
        let doing = marker.phase == .load ? "loading" : "running"
        return "Free Flow closed while \(doing) \(what), so dictation is back on Core ML (\(fallbackName))."
    }
}
