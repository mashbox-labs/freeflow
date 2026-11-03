import Foundation
#if os(iOS)
import os
#endif

/// One speech model Free Flow offers. The list is data (Resources/speech-models.json), so a new model slots in
/// with no picker code. Each model is pinned to one Hugging Face commit; every downloaded file is checked
/// against its sha256 (App/Resources/model-manifest.json).
public struct SpeechModel: Identifiable, Hashable, Sendable, Decodable {
    public enum Tier: String, Sendable, CaseIterable, Decodable {
        case extraSmall = "xsmall", small, medium, large
        public var title: String {
            switch self {
            case .extraSmall: "Extra small"
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
    }

    /// The runtime that runs the files.
    public enum Engine: String, Sendable, Decodable {
        case whisperKit = "whisperkit"
        /// Our own Whisper large-v3-turbo Core ML build on the Neural Engine (WHISPER-ANE, 2026-11-02): length-bucket
        /// encoder, stateful decoder, greedy with Whisper's suppress lists and the compression-ratio fallback.
        case whisperANE = "whisper-ane"
        case parakeetV3 = "parakeet-v3"
        /// whisper.cpp Parakeet code on our one ggml (FreeFlowEngine, C++): Metal in the foreground, CPU in the background.
        case ggmlParakeet = "ggml-parakeet"
        /// llama.cpp mtmd audio LLM (Liquid LFM audio + its audio projector) on the same ggml.
        case ggmlAudioLLM = "ggml-audio-llm"

        /// Runs on the C++ engine (any iPhone the app supports; no Neural Engine needed).
        public var isCpp: Bool { self == .ggmlParakeet || self == .ggmlAudioLLM }
        /// A Whisper engine (either runtime): the one the language routing sends non-Parakeet languages to.
        public var isWhisper: Bool { self == .whisperKit || self == .whisperANE }

        /// Build 23: the dictionary is used while decoding (Parakeet on Core ML: decode-time boost on its top-K; Whisper:
        /// the words as its prompt). The C++ engine has no decode-time hook, so it gets no words. Transcriber.transcribe
        /// passes the words only when this is true and the Models cards show "Dictionary" from it: they cannot disagree.
        public var usesDictionary: Bool { self == .parakeetV3 || self == .whisperKit }
    }

    /// A quality number measured on this exact file, with who measured it and when.
    public struct Quality: Hashable, Sendable, Decodable {
        public let werPercent: Double
        public let testSet: String
        public let measuredBy: String
        public let date: String
        /// "measured" = we ran this exact file; "vendor" = the maker's published number. Missing = measured.
        public let source: String?
        public var isVendor: Bool { source == "vendor" }
        /// MEASURED or VENDOR, shown next to the number.
        public var label: String { isVendor ? "VENDOR" : "MEASURED" }
        public var line: String {
            isVendor
                ? String(format: "%.1f%% word errors on %@ (published by %@, %@)", werPercent, testSet, measuredBy, date)
                : String(format: "%.1f%% word errors on %@ (measured by %@, %@)", werPercent, testSet, measuredBy, date)
        }
    }

    public let id: String
    public let tier: Tier
    public let name: String
    public let maker: String
    /// Asset name of the maker's logo in the app's catalog, if it has one.
    public let makerLogo: String?
    public let parameters: String
    public let languages: String
    /// ISO 639-1 codes the model covers; nil = Whisper's full set.
    public let languageCodes: [String]?
    public let licence: String
    public let runtime: String
    public let engine: Engine
    /// Model files plus tokenizer, as listed in the manifest.
    public let downloadBytes: Int64
    /// Below this much memory (GiB, as iOS reports it) the model is too big for the device and cannot be picked.
    public let minMemoryGiB: Double
    /// The automatic pick considers the model from this much memory (GiB); nil = never picked automatically.
    public let recommendFromGiB: Double?
    /// Among the models the automatic pick considers, the highest wins.
    public let preference: Int
    public let blurb: String
    public let quality: Quality?
    /// Groups the quantizations of one model in the picker (nil = a model on its own).
    public let family: String?
    /// Quantization of this file, e.g. "Q4_0" (C++ models).
    public let quant: String?
    /// Peak memory while transcribing, measured on the Mac CPU run of this file (MB). Drives "won't run well".
    public let peakMemoryMB: Int?

    /// The measured peak memory as one line for the Models screen; nil when it was not measured.
    public var peakMemoryLine: String? {
        peakMemoryMB.map { "Peak memory \($0) MB while transcribing (measured on a Mac CPU with the app's engine)" }
    }
    /// The section of the Models page this model sits in (a ModelGroup id); nil = a section of its own.
    public let group: String?
    /// Speed of this exact file on the iOS simulator in our UI test walk (FreeFlowUITests.test2, the JFK clip);
    /// nil = not measured. Always shown as a simulator number, never as a phone's.
    public let simSpeed: SimSpeed?
    /// Audio LLMs only: the instruction that makes them transcribe, e.g. "Perform ASR in English."
    public let systemPrompt: String?
    /// C++ models: the model file's name inside the model's folder (its manifest entry).
    public let modelFile: String?
    /// Build 23: false where the dictionary's decode-time boost was measured and fixed no word on this model (a Dictionary
    /// label only where the vocabulary boost is verified on that model). Nil: the engine decides.
    public let dictionary: Bool?
    /// Build 23: the card's one line on what the model is for ("Fastest · English"), when the catalog gives one.
    public let purpose: String?

    /// The dictionary goes to this model while decoding, and its card says "Dictionary": one flag, so they cannot disagree.
    public var usesDictionary: Bool { engine.usesDictionary && (dictionary ?? true) }
    /// Audio LLMs only: the audio projector (mmproj) file's name inside the same folder.
    public let projectorFile: String?

    /// The quantization as shown on the Models page: the GGUF type, or how the Core ML weights are stored.
    public var quantLabel: String { quant ?? "As published" }
    /// "Core ML" or "C++ (ggml)".
    public var engineLabel: String { engine.isCpp ? "C++ (ggml)" : "Core ML" }

    public func covers(language: String) -> Bool { languageCodes.map { $0.contains(language) } ?? true }
    public func fits(memoryBytes: UInt64) -> Bool { Double(memoryBytes) / ModelCatalog.gib >= minMemoryGiB }
}

/// How fast a model ran on the iOS simulator in our test walk: the JFK clip (about 11 s of speech, fed for 12-15 s)
/// through the app's own capture and engine, timed by the app (audio seconds / processing seconds).
public struct SimSpeed: Hashable, Sendable, Decodable {
    public let audioSeconds: Double
    public let processSeconds: Double
    /// The simulated device, e.g. "iPhone Air".
    public let simulator: String
    public let date: String
    public init(audioSeconds: Double, processSeconds: Double, simulator: String, date: String) {
        self.audioSeconds = audioSeconds; self.processSeconds = processSeconds; self.simulator = simulator; self.date = date
    }
    public var speed: Double { processSeconds > 0 ? audioSeconds / processSeconds : 0 }
    /// "6.1x real time", one decimal under 10x, none from 10x.
    public var short: String {
        let x = speed
        return (x >= 10 ? String(format: "%.0f", x) : String(format: "%.1f", x)) + "x real time"
    }
    public var line: String {
        String(format: "%@ on the %@ simulator (%.1f s of audio in %.2f s, %@)", short, simulator, audioSeconds, processSeconds, date)
    }
}

/// One section of the Models page: a model and every way Free Flow can run it (sizes, quantizations, engines).
public struct ModelGroup: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let maker: String
    public let makerLogo: String?
    public let blurb: String
}

public enum ModelCatalog {
    static let gib = 1_073_741_824.0

    struct File: Decodable {
        let groups: [ModelGroup]?
        let models: [SpeechModel]
    }

    static let bundled: File = {
        guard let url = Bundle.module.url(forResource: "speech-models", withExtension: "json") else {
            fatalError("speech-models.json is missing from FreeFlowKit's resources")
        }
        do { return try decodeFile(Data(contentsOf: url)) } catch { fatalError("speech-models.json: \(error)") }
    }()

    /// Models kept in the catalog file but not offered (2026-11-03: the WhisperKit build of Whisper
    /// large-v3-turbo next to our Neural Engine build of the same model). Not on `removed`: files already on a device
    /// stay where they are; the model just is not listed, picked or routed to.
    public static let hidden: Set<String> = ["large"]

    /// Every model offered: the bundled catalog in file order, without the hidden ones.
    public static let all: [SpeechModel] = bundled.models.filter { !hidden.contains($0.id) }

    /// The Models page sections in the bundled catalog, in file order.
    public static let groups: [ModelGroup] = bundled.groups ?? []

    /// Reads a catalog file and checks it: at least one model, unique ids, and one model every device can run
    /// that the automatic pick can fall back to.
    public static func decode(_ data: Data) throws -> [SpeechModel] { try decodeFile(data).models }

    static func decodeFile(_ data: Data) throws -> File {
        let file = try JSONDecoder().decode(File.self, from: data)
        let models = file.models
        if let groups = file.groups {
            let ids = Set(groups.map(\.id))
            guard ids.count == groups.count else { throw CatalogError("duplicate group id") }
            for m in models { if let g = m.group, !ids.contains(g) { throw CatalogError("\(m.id): unknown group \(g)") } }
        }
        _ = try check(models)
        return file
    }

    static func check(_ models: [SpeechModel]) throws -> [SpeechModel] {
        guard !models.isEmpty else { throw CatalogError("no models") }
        guard Set(models.map(\.id)).count == models.count else { throw CatalogError("duplicate model id") }
        // Build 23: no catalog model covers every language now (Parakeet family only); a device whose language isn't
        // covered transcribes in English (SpeechLanguage) and Models says the language is coming.
        guard models.contains(where: { !$0.engine.isCpp && $0.minMemoryGiB == 0 && $0.recommendFromGiB == 0 }) else {
            throw CatalogError("needs one model that fits every device and can be picked from 0 GiB")
        }
        return models
    }

    /// One section of the Models page with its models, smallest download first.
    public struct Section: Identifiable, Sendable {
        public let group: ModelGroup
        public let models: [SpeechModel]
        public var id: String { group.id }
    }

    /// The Models page: each group in catalog order with its models (any engine), Core ML first, then smallest download
    /// first (2026-10-30: Core ML is the default; a C++ twin is the fallback). A model
    /// whose group is missing gets a section of its own, so nothing in the catalog is ever left off the page.
    public static func sections(models: [SpeechModel] = all, groups: [ModelGroup] = groups) -> [Section] {
        var out: [Section] = groups.compactMap { g in
            let ms = models.filter { $0.group == g.id }
            return ms.isEmpty ? nil : Section(group: g, models: ms.sorted { ($0.engine.isCpp ? 1 : 0, $0.downloadBytes) < ($1.engine.isCpp ? 1 : 0, $1.downloadBytes) })
        }
        let known = Set(groups.map(\.id))
        for m in models where m.group.map({ !known.contains($0) }) ?? true {
            out.append(Section(group: ModelGroup(id: m.id, name: m.family ?? m.name, maker: m.maker, makerLogo: m.makerLogo,
                                                 blurb: m.blurb), models: [m]))
        }
        return out
    }

    public struct CatalogError: Error, CustomStringConvertible {
        public let description: String
        init(_ text: String) { description = text }
    }

    public static func model(_ id: String) -> SpeechModel? { all.first { $0.id == id } }

    /// The languages a model can be pinned to: its own list, or (nil, Whisper) the full set the caller passes in.
    /// More than one = the model gets a language setting (device language by default, Automatic only by choice).
    public static func languages(of model: SpeechModel?, whisper: Set<String>) -> Set<String> {
        guard let model else { return ["en"] }
        return model.languageCodes.map(Set.init) ?? whisper
    }

    /// Languages Parakeet TDT 0.6B v3 covers (ISO 639-1), from the catalog.
    public static var parakeetLanguages: Set<String> { Set(all.first { $0.engine == .parakeetV3 }?.languageCodes ?? []) }

    public static var currentLanguage: String { Locale.current.language.languageCode?.identifier ?? "en" }

    /// The automatic pick: of the models that fit this memory, can be picked from it and cover your language, the
    /// one with the highest preference. C++ models are never the automatic pick: Core ML stays the default until the
    /// C++ engine is measured to match it on device (their recommendFromGiB picks a quantization within a family). With today's catalog: under 5.0 GiB -> small; 5.0 and up -> Parakeet when
    /// your language is one of its 25 (it is the more accurate one there); 7.0 and up with any other language ->
    /// large. A 6 GB iPhone reports about 5.6 GiB, an 8 GB one about 7.5 GiB.
    /// Build 23: the default for new installs, in one line. It is recommended (and so picked on a
    /// new install) wherever it fits this memory from its recommendFromGiB and covers your language; elsewhere the
    /// preference rule below decides. Existing installs keep their pick.
    public static let defaultPick = "parakeet-ultra"

    /// Build 38: the first-run page shows exactly two cards, the recommendation first and preselected.
    /// Build 39: our Whisper is the recommendation where it runs properly (its recommendFromGiB, 7.0 = 8 GB
    /// devices), with Parakeet Ultra second. Below that: Parakeet first (Ultra from 5 GiB, Redux below), then our Whisper
    /// where it fits (5 GiB and up), else the best other model that fits.
    public static let setupWhisper = "whisper-turbo-ane"
    public static func setupChoices(memoryBytes: UInt64, in models: [SpeechModel] = all) -> [SpeechModel] {
        let fits = models.filter { !$0.engine.isCpp && $0.fits(memoryBytes: memoryBytes) }
        // First card = the recommendation Models shows too (Parakeet Ultra from 5 GiB, the smaller Parakeet Redux below).
        let rec = recommended(memoryBytes: memoryBytes, in: models)
        guard let first = fits.first(where: { $0.id == rec.id }) ?? fits.first else { return [] }
        let second = (first.id == setupWhisper ? fits.first(where: { $0.id == defaultPick }) : nil)
            ?? fits.first(where: { $0.id == setupWhisper && $0.id != first.id })
            ?? fits.filter { $0.id != first.id && !$0.engine.isWhisper }.max { ($0.preference, $1.downloadBytes) < ($1.preference, $0.downloadBytes) }
        return [first] + (second.map { [$0] } ?? [])
    }

    public static func recommended(memoryBytes: UInt64, language: String = currentLanguage,
                                   in models: [SpeechModel] = all) -> SpeechModel {
        let memory = Double(memoryBytes) / gib
        // Build 39: our Whisper wherever it runs properly (from its recommendFromGiB), for every language.
        if let w = models.first(where: { $0.id == setupWhisper }), !w.engine.isCpp, w.fits(memoryBytes: memoryBytes),
           let from = w.recommendFromGiB, memory >= from {
            return w
        }
        // The default for every language: one not covered transcribes in English until its model comes.
        if let pick = models.first(where: { $0.id == defaultPick }), !pick.engine.isCpp, pick.fits(memoryBytes: memoryBytes),
           memory >= (pick.recommendFromGiB ?? 0) {
            return pick
        }
        let candidates = models.filter { m in
            guard !m.engine.isCpp, let from = m.recommendFromGiB else { return false }
            return memory >= from && m.fits(memoryBytes: memoryBytes) && m.covers(language: language)
        }
        if let best = candidates.max(by: { ($0.preference, $1.downloadBytes) < ($1.preference, $0.downloadBytes) }) {
            return best
        }
        return models.filter { !$0.engine.isCpp && $0.fits(memoryBytes: memoryBytes) }.min { $0.downloadBytes < $1.downloadBytes }
            ?? models.first { !$0.engine.isCpp } ?? models[0]
    }

    /// One model and its quantizations (C++ engine), as the picker groups them.
    public struct Family: Identifiable, Sendable {
        public let name: String
        /// Quantizations, smallest download first.
        public let models: [SpeechModel]
        public var id: String { name }
    }

    /// The Core ML model in the same group as a C++ model (each Parakeet TDT 0.6B v3 GGUF file -> Parakeet v3 on Core
    /// ML); nil for a Core ML model and for a group with no Core ML form (the Liquid audio models). 2026-10-30: Core ML
    /// is the default and the recommended choice; a C++ form with a Core ML twin is the fallback.
    public static func coreMLTwin(of model: SpeechModel, in models: [SpeechModel] = all) -> SpeechModel? {
        guard model.engine.isCpp, let g = model.group else { return nil }
        return models.first { !$0.engine.isCpp && $0.group == g }
    }

    /// Build 23 (the C++ Parakeet cards read as "the larger Parakeet model, only C++"): a C++ copy of a Core
    /// ML model says on its card that it is the same model, a backup copy. nil for every other card.
    public static func backupLine(for model: SpeechModel, in models: [SpeechModel] = all) -> String? {
        guard let twin = coreMLTwin(of: model, in: models) else { return nil }
        // Build 23: the C++ files are Parakeet v3, the model the Core ML ones were trained from (no Ultra file runs on
        // this engine yet), and the card says exactly that.
        if let family = model.family, family != twin.name {
            return "\(family), the model \(twin.name) was trained from: a backup for when the Neural Engine can't be used"
        }
        return "Same model as \(twin.name): a backup copy for when the Neural Engine can't be used"
    }

    /// Build 23: models earlier builds offered and this one doesn't. A pick of
    /// one moves to the default with one plain line, and its files are deleted from the device.
    /// Whisper large-v3-turbo ("large") is offered again (build 26), so it is not on this list.
    public static let removed: [String: String] = [
        "small": "Whisper small", "medium": "Parakeet TDT 0.6B v3",
        "whisper-tiny": "Whisper tiny", "whisper-base": "Whisper base", "whisper-small-f16": "Whisper small 16-bit",
        "lfm3-audio-q4_0": "LFM3-Audio-2B Q4_0",
    ]
    public static func movedLine(from old: String, to new: SpeechModel, downloaded: Bool) -> String {
        "\(removed[old] ?? old) is no longer offered, so Free Flow now uses \(new.name)"
            + (downloaded ? "." : ". Download it in Models (\(Int((Double(new.downloadBytes) / 1_000_000).rounded())) MB).")
    }

    /// The backend each Models page card states under its name.
    public static func backendLabel(for model: SpeechModel, in models: [SpeechModel] = all) -> String {
        guard model.engine.isCpp else { return "Core ML" }
        return coreMLTwin(of: model, in: models) == nil ? "C++" : "C++, for when Core ML isn't available"
    }

    /// Whether a C++ card shows "Recommended file": only in a C++ family of more than one file with no Core ML form.
    public static func showsRecommendedFile(_ model: SpeechModel, memoryBytes: UInt64) -> Bool {
        guard model.engine.isCpp, coreMLTwin(of: model) == nil,
              let family = families().first(where: { $0.models.contains { $0.id == model.id } }), family.models.count > 1 else { return false }
        return familyPick(family, memoryBytes: memoryBytes)?.id == model.id
    }

    /// The C++ models grouped by family, in catalog order.
    public static func families(in models: [SpeechModel] = all) -> [Family] {
        var order: [String] = []
        var groups: [String: [SpeechModel]] = [:]
        for m in models where m.engine.isCpp {
            let key = m.family ?? m.name
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.map { Family(name: $0, models: groups[$0]!.sorted { $0.downloadBytes < $1.downloadBytes }) }
    }

    /// The quantization this device should use within a family: of those that fit this memory and can be picked from
    /// it, the highest preference; nil when none fits.
    public static func familyPick(_ family: Family, memoryBytes: UInt64) -> SpeechModel? {
        let memory = Double(memoryBytes) / gib
        return family.models.filter { m in
            // Never recommended without a measured peak memory.
            guard let from = m.recommendFromGiB, m.peakMemoryMB != nil else { return false }
            return memory >= from && m.fits(memoryBytes: memoryBytes)
        }.max { ($0.preference, $1.downloadBytes) < ($1.preference, $0.downloadBytes) }
    }

    /// The picker: the recommended model first, then every other model, biggest download first. By default the Core ML
    /// models; the picker lists C++ models by family (families()).
    public static func pickerOrder(recommended: SpeechModel, in models: [SpeechModel] = all.filter { !$0.engine.isCpp }) -> [SpeechModel] {
        [recommended] + models.filter { $0.id != recommended.id }
            .sorted { $0.downloadBytes != $1.downloadBytes ? $0.downloadBytes > $1.downloadBytes : $0.id < $1.id }
    }

    /// The extra-small model, when the catalog has one.
    public static func extraSmall(in models: [SpeechModel] = all) -> SpeechModel? {
        models.filter { $0.tier == .extraSmall }.min { $0.downloadBytes < $1.downloadBytes }
    }

    /// One plain line saying why the recommended model was picked.
    public static func reason(for model: SpeechModel, memoryBytes: UInt64, language: String = currentLanguage,
                              device: String) -> String {
        let memory = "\(DeviceProfile.marketingGB(memoryBytes: memoryBytes)) GB of memory"
        // Build 23: the language is the reason only when the model speaks it (Ultra is the pick for every language).
        if model.languageCodes != nil, model.covers(language: language) {
            let name = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
            return "Picked for this \(device)'s \(memory) and your language, \(name)."
        }
        return "Picked for this \(device)'s \(memory)."
    }

    /// Whether a model will run well here right now. `availableBytes` = os_proc_available_memory() (what iOS lets
    /// this process still allocate); `probeSpeed` = audio seconds per processing second from a short on-device run
    /// of this model (nil = not probed yet). Only measured inputs; nothing is estimated.
    public enum RunHealth: Equatable, Sendable {
        case good
        case notProbed
        case wontRunWell(String)
    }

    /// `loadedBytes` = memory the model loaded right now added to the app: using another model (or this one) unloads
    /// or reuses it first, so it counts as free.
    public static func runHealth(_ model: SpeechModel, availableBytes: UInt64?, loadedBytes: UInt64 = 0,
                                 probeSpeed: Double?) -> RunHealth {
        if let peak = model.peakMemoryMB, let free = availableBytes, free > 0 {
            let needMB = Double(peak) * 1.15
            let haveMB = Double(free + loadedBytes) / 1_048_576
            if haveMB < needMB {
                return .wontRunWell(String(format: "Needs about %.0f MB free to run; the app can use %.0f MB right now.", needMB, haveMB))
            }
        }
        guard let speed = probeSpeed else { return .notProbed }
        if speed < 1.0 {
            return .wontRunWell(String(format: "Slower than real time on this device (%.1fx in a short test).", speed))
        }
        return .good
    }

    /// Why a model cannot run here, or nil when it fits.
    public static func tooBigReason(_ model: SpeechModel, memoryBytes: UInt64, device: String) -> String? {
        guard !model.fits(memoryBytes: memoryBytes) else { return nil }
        return "Needs \(DeviceProfile.marketingGB(gib: model.minMemoryGiB)) GB of memory. "
            + "This \(device) has \(DeviceProfile.marketingGB(memoryBytes: memoryBytes)) GB."
    }
}

/// How fast a model ran on this device: the speed of each dictation (audio seconds / processing seconds),
/// the latest 20 kept. Only measured runs go in; nothing is estimated.
public struct MeasuredSpeed: Codable, Equatable, Sendable {
    public static let keep = 20
    /// Clips shorter than this are dominated by fixed costs, so they are not counted.
    public static let minimumAudioSeconds = 1.0

    public private(set) var speeds: [Double] = []
    public init() {}

    @discardableResult
    public mutating func add(audioSeconds: Double, processSeconds: Double) -> Bool {
        guard audioSeconds >= Self.minimumAudioSeconds, processSeconds > 0 else { return false }
        speeds.append(audioSeconds / processSeconds)
        if speeds.count > Self.keep { speeds.removeFirst(speeds.count - Self.keep) }
        return true
    }

    public var count: Int { speeds.count }

    public var median: Double? {
        guard !speeds.isEmpty else { return nil }
        let s = speeds.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public func line(device: String) -> String? {
        guard let m = median else { return nil }
        let x = m >= 10 ? String(format: "%.0f", m) : String(format: "%.1f", m)
        return "Measured on this \(device): \(x)x real time, median of \(count) dictation\(count == 1 ? "" : "s")"
    }
}

/// Facts about this device used for the recommendation and the live stats.
public struct DeviceProfile: Sendable {
    public let memoryBytes: UInt64
    public let machine: String
    public let isSimulator: Bool
    /// True when a UI test set the memory (simulator only, FF_SIM_MEMORY_GIB) to show another device's picker.
    public let memoryFromTest: Bool

    public static var current: DeviceProfile {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        var memory = ProcessInfo.processInfo.physicalMemory
        var fromTest = false
        #if targetEnvironment(simulator)
        let sim = true
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        if let value = ProcessInfo.processInfo.environment["FF_SIM_MEMORY_GIB"].flatMap(Double.init), value > 0 {
            memory = UInt64(value * ModelCatalog.gib)
            fromTest = true
        }
        #else
        let sim = false
        let model = machine
        #endif
        return DeviceProfile(memoryBytes: memory, machine: model, isSimulator: sim, memoryFromTest: fromTest)
    }

    public var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }

    /// The memory size Apple sells the device with. iOS reports a little less (an 8 GB iPhone reports about
    /// 7.5 GiB), so this is the smallest standard size at or above the reading.
    public static func marketingGB(gib: Double) -> Int {
        let sizes = [1, 2, 3, 4, 6, 8, 12, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256]
        return sizes.first { Double($0) >= gib - 0.001 } ?? Int(gib.rounded(.up))
    }

    public static func marketingGB(memoryBytes: UInt64) -> Int { marketingGB(gib: Double(memoryBytes) / ModelCatalog.gib) }

    /// Memory iOS still lets this process allocate (os_proc_available_memory); nil off iOS or in the simulator.
    public static func availableMemoryBytes() -> UInt64? {
        #if os(iOS) && !targetEnvironment(simulator)
        let value = os_proc_available_memory()
        return value > 0 ? UInt64(value) : nil
        #else
        return nil
        #endif
    }
    /// Free space now (DiskSpace.current: FF_SIM_FREE_DISK_GB in a simulator test). A system query: never call it from a
    /// view body (build 8 did, and re-rendered it dozens of times a second in the background on an iPad).
    public static func freeDiskBytes() -> Int64 { DiskSpace.current().freeBytes }

    /// This process's memory footprint (what iOS counts against its limit).
    public static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

public extension Int64 {
    var megabytes: String { String(format: "%.0f MB", Double(self) / 1_000_000) }
}
