import CryptoKit
import FluidAudio
import FreeFlowKit
import Foundation
import UIKit

struct ManifestModel: Decodable {
    struct File: Decodable { let sha256: String; let size: Int64 }
    let repo: String
    let subfolder: String
    let revision: String
    let bytes: Int64
    let files: [String: File]
}

/// Downloads, verifies (sha256 per file, pinned commit), loads and measures the speech models.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Status: Equatable {
        case notDownloaded, downloading(Double), verifying, ready, failed(String)
    }

    @Published private(set) var status: [String: Status] = [:]
    @Published var activeID: String {
        didSet {
            UserDefaults.standard.set(activeID, forKey: "activeModel"); crashNotice = nil
            // Build 22: a pick takes effect at once. Its load starts now (the model in use is let go
            // first), so the next dictation does not wait for it, and a load of an older pick never holds it up.
            if oldValue != activeID {
                NSLog("FFMODEL pick %@ (was %@)", activeID, oldValue)
                if status[activeID] == .ready { Task { try? await self.ensureLoaded() } }
            }
        }
    }
    /// Loads in flight: model id -> when it began. Dictate and Models show them ("Loading on the Neural Engine…", then
    /// the one-time build with its time).
    @Published private(set) var building: [String: Date] = [:] {
        didSet { for id in building.keys where oldValue[id] != building[id] { spans[id] = ActiveSpan(began: building[id]!) } }
    }
    /// Build 24: each load's clock in active time (ActiveClock: time in the background is left out).
    private var spans: [String: ActiveSpan] = [:]
    /// Build 24 (seen on an iPad): a load that did not finish within its limit, per model: what to say on its card,
    /// with Try again. A prepare never waits forever.
    @Published private(set) var stuck: [String: String] = [:]
    /// Build 24 (the full prepare screen only on first launch): true once any model got ready on this
    /// device, or on an update from a build that had models. Later prepares show on the model's card, not full screen.
    @Published private(set) var firstPrepareDone: Bool
    /// Active seconds a load may run before it counts as stuck (ActiveLimit). The slowest first prepare we know of on an
    /// iPhone or iPad is about 2 min (Parakeet Ultra, FluidAudio #1022, 105 to 109 s); Bark 3.0 Pro also compiles its
    /// packages first.
    static let prepareLimit: TimeInterval = 600
    /// Back in front after iOS suspended a load in the background: seconds it gets to finish before it starts again.
    static let resumeGrace: TimeInterval = 20
    private var resumedOnce: Set<String> = []
    /// Build 23: the pick that left the catalog this launch (for the one line on Dictate), until dismissed.
    @Published var movedFrom: String?

    /// Deletes the files of models this build no longer offers (ModelCatalog.removed). Returns the ids it removed.
    static func removeDroppedModels() -> [String] {
        var gone: [String] = []
        for id in ModelCatalog.removed.keys.sorted() {
            // Parakeet v3 Core ML ("medium") sat in FluidAudio's cache: "parakeet-tdt-0.6b-v3" before FluidAudio v0.18.0,
            // "parakeet-tdt-0.6b-v3-coreml" from it. Both names, explicitly.
            let cache = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
            let dirs = id == "medium"
                ? [cache.appendingPathComponent("parakeet-tdt-0.6b-v3"), cache.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")]
                : [Transcriber.root.appendingPathComponent(id)]
            for dir in dirs where FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.removeItem(at: dir)
                if !gone.contains(id) { gone.append(id) }
            }
            UserDefaults.standard.removeObject(forKey: "verified.\(id)")
        }
        return gone
    }
    /// This process's memory peak during the last load (MB), for the switch log.
    private(set) var lastLoadPeakMB: UInt64 = 0
    /// One line after the last launch died inside a C++ load or run (CppCrashGuard); cleared when a model is picked.
    @Published private(set) var crashNotice: String?
    @Published private(set) var loadedID: String?
    /// True while a speech model is being loaded or prepared (build 18: the first load after an install or an iOS
    /// update can take a while, and the app says so instead of a silent wait).
    @Published private(set) var preparing = false
    private var preparingCount = 0
    @Published private(set) var loadSeconds: Double?
    @Published private(set) var plan: [String: Int] = [:]
    /// The memory peak shown in Models. Measured as often as notePeak() is called; published to SwiftUI at most once a
    /// second, only on a rise of 1 MB or more, and only while Free Flow is active (Apple, "Preparing your UI to run in
    /// the background": a background app should not update its views). Build 8 published it every second while
    /// recording and 20 times a second during a model load, and each publish re-rendered every view (iOS killed the
    /// app on an iPad for main-thread CPU in SwiftUI updates, cpu_resource_fatal twice on 10-29).
    @Published private(set) var peakFootprint: UInt64 = 0
    private var peakSeen: UInt64 = 0
    private var lastPeakPublish = Date.distantPast
    /// C++ models: the backend the last dictation ran on ("metal" or "cpu") and any reload it needed for that backend.
    @Published private(set) var lastBackend: String?
    @Published private(set) var lastReloadSeconds: Double = 0
    /// Memory the loaded model added to the app (Transcriber.loadedBytes); 0 when none is loaded.
    @Published private(set) var loadedModelBytes: UInt64 = 0
    /// Speeds this device measured, per model (only real dictations; see MeasuredSpeed).
    @Published private(set) var measuredSpeeds: [String: MeasuredSpeed] = [:]
    /// Free space, memory iOS still gives the app, and the app's footprint, as the Models page shows them. Stored, never
    /// read from a view body: build 8 queried free space inside ModelsView's body, which re-rendered dozens of times a
    /// second in the background on an iPad (cpu_resource_fatal, symbolicated 10-29). refreshDevice()
    /// reads them on appear, after each download or delete, and every 5 s while Models is on screen and the app is active,
    /// and publishes only a real change.
    @Published private(set) var disk = DiskSpace(freeBytes: 0, totalBytes: 0)
    @Published private(set) var availableMemory: UInt64?
    @Published private(set) var footprintNow: UInt64 = 0
    let device = DeviceProfile.current
    let manifest: [String: ManifestModel]
    let availableDevices = Transcriber.availableDevices

    var recommended: SpeechModel { ModelCatalog.recommended(memoryBytes: device.memoryBytes) }
    var active: SpeechModel { ModelCatalog.model(activeID) ?? recommended }
    var activeReady: Bool { status[activeID] == .ready }

    init() {
        // Build 24: an update from a build that had a model is not a first launch (read before any cleanup below).
        let defaults = UserDefaults.standard
        let hadModel = defaults.string(forKey: "activeModel") != nil
            || defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("verified.") }
        let done = defaults.bool(forKey: "firstPrepareDone") || hadModel
        firstPrepareDone = done
        if done { defaults.set(true, forKey: "firstPrepareDone") }
        let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json")
        manifest = url.flatMap { try? JSONDecoder().decode([String: ManifestModel].self, from: Data(contentsOf: $0)) } ?? [:]
        // A saved pick that is no longer in the catalog, or too big for this device, falls back to the recommendation.
        let memory = DeviceProfile.current.memoryBytes
        let savedID = UserDefaults.standard.string(forKey: "activeModel")
        let saved = savedID.flatMap(ModelCatalog.model)
        activeID = (saved?.fits(memoryBytes: memory) == true ? saved : nil)?.id ?? ModelCatalog.recommended(memoryBytes: memory).id
        // Build 23: models this build no longer offers. Their files go from this device (once), and a pick of one moves
        // to the default with one line on Dictate.
        let removedHere = Self.removeDroppedModels()
        if let savedID, saved == nil, ModelCatalog.removed[savedID] != nil {
            UserDefaults.standard.set(activeID, forKey: "activeModel")
            movedFrom = savedID
            NSLog("FFMODEL catalog: %@ is no longer offered, pick moved to %@ (removed files: %@)", savedID, activeID, removedHere.joined(separator: ","))
        }
        for model in ModelCatalog.all {
            if let data = UserDefaults.standard.data(forKey: "measuredSpeed.\(model.id)"),
               let speed = try? JSONDecoder().decode(MeasuredSpeed.self, from: data) {
                measuredSpeeds[model.id] = speed
            }
        }
        refresh()
        // The last process died inside a GGUF load or run: dictation goes back to Core ML, once, and says so.
        // Saved here by hand: didSet does not run inside init, and the next launch must not load the C++ pick again.
        if let crash = Transcriber.crashGuard.takeCrash() {
            let ready = Set(status.filter { $0.value == .ready }.map(\.key))
            activeID = CppCrashGuard.fallback(activeID: activeID, readyIDs: ready, memoryBytes: memory)
            UserDefaults.standard.set(activeID, forKey: "activeModel")
            crashNotice = CppCrashGuard.notice(for: crash, fallbackName: ModelCatalog.model(activeID)?.name ?? activeID)
        }
        Self.cleanStaleCaches()
        #if !targetEnvironment(macCatalyst)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            ActiveClock.shared.enteredBackground()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            ActiveClock.shared.enteredForeground()
            MainActor.assumeIsolated { self?.backInFront() }
        }
        #endif
    }

    /// Build 24: back in front after a stay in the background long enough for iOS to suspend the app (its background
    /// time is about 30 s). A Neural Engine prepare that was running then gets resumeGrace seconds to finish; one that
    /// does not is started again, once (seen on an iPad: a prepare left in the background never came back).
    private func backInFront() {
        guard ActiveClock.shared.lastBackground > 25 else { return }
        for (id, began) in building {
            guard let model = ModelCatalog.model(id), !model.engine.isCpp else { continue }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.resumeGrace * 1_000_000_000))
                guard self.building[id] == began else { return }
                NSLog("FFMODEL %@ did not finish %.0f s after Free Flow came back from %.0f s in the background: starting it again",
                      id, Self.resumeGrace, ActiveClock.shared.lastBackground)
                await Transcriber.shared.abandon(id)
            }
        }
    }

    /// Build 24 (Bark stuck after an update, fine after a reinstall): what an earlier build left that this
    /// build cannot use goes, once per app build, before any model loads: Core ML's compiled-model caches (rebuilt on
    /// the next load), compiled Bark 3.0 Pro packages from an interrupted compile ("*.mlmodelc.part"), and partial
    /// downloads of models this build no longer offers.
    static func cleanStaleCaches() {
        let defaults = UserDefaults.standard
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        guard defaults.string(forKey: "cachesCleanedForBuild") != build else { return }
        let fm = FileManager.default
        var gone: [String] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            for name in ["com.apple.e5rt.e5bundlecache", "com.apple.coreml"] {
                for dir in [caches.appendingPathComponent(name),
                            caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "").appendingPathComponent(name)]
                where fm.fileExists(atPath: dir.path) {
                    if (try? fm.removeItem(at: dir)) != nil { gone.append(dir.lastPathComponent) }
                }
            }
        }
        for model in ModelCatalog.all {
            let dir = Transcriber.directory(for: model.id)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".mlmodelc.part") {
                if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { gone.append(model.id + "/" + name) }
            }
        }
        defaults.set(build, forKey: "cachesCleanedForBuild")
        NSLog("FFMODEL caches cleaned for build %@: %@", build, gone.isEmpty ? "nothing to clean" : gone.joined(separator: ", "))
    }

    func measured(_ id: String) -> MeasuredSpeed? { measuredSpeeds[id] }

    /// Records one finished dictation's speed for the model that ran it.
    func noteRun(audioSeconds: Double, processSeconds: Double) {
        let id = loadedID ?? activeID
        var speed = measuredSpeeds[id] ?? MeasuredSpeed()
        guard speed.add(audioSeconds: audioSeconds, processSeconds: processSeconds) else { return }
        measuredSpeeds[id] = speed
        if let data = try? JSONEncoder().encode(speed) { UserDefaults.standard.set(data, forKey: "measuredSpeed.\(id)") }
    }

    /// Every pinned part of a model: its files and, for Whisper, its tokenizer.
    func parts(_ id: String) -> [(ManifestModel, URL)] {
        var out: [(ManifestModel, URL)] = []
        if let m = manifest[id] { out.append((m, Transcriber.directory(for: id))) }
        if let t = manifest[id + ".tokenizer"] { out.append((t, Transcriber.tokenizerDirectory(for: id))) }
        return out
    }

    func downloadBytes(_ id: String) -> Int64 { parts(id).reduce(0) { $0 + $1.0.bytes } }
    func revision(_ id: String) -> String { String(manifest[id]?.revision.prefix(7) ?? "") }

    /// Re-reads free space and memory (system queries: call from a task or an action, never from a view body).
    func refreshDevice() {
        let now = DiskSpace.current()
        if abs(now.freeBytes - disk.freeBytes) >= 10_000_000 || now.totalBytes != disk.totalBytes || now.fromTest != disk.fromTest {
            disk = now
        }
        let memory = DeviceProfile.availableMemoryBytes()
        if let m = memory, let old = availableMemory {
            if abs(Int64(m) - Int64(old)) >= 16 << 20 { availableMemory = m }
        } else if memory != availableMemory {
            availableMemory = memory
        }
        let footprint = DeviceProfile.footprintBytes()
        if abs(Int64(footprint) - Int64(footprintNow)) >= 1 << 20 { footprintNow = footprint }
    }

    /// Whether this model's download fits the free space last read (refreshDevice), and what it would leave.
    /// Before the first read (the page reads on appear) nothing is known, so nothing is flagged; download() reads again.
    func diskCheck(_ model: SpeechModel) -> DiskBudget.Check {
        if disk.freeBytes == 0 && disk.totalBytes == 0 && !disk.fromTest { return .fine(leftBytes: 0) }
        return DiskBudget.check(downloadBytes: downloadBytes(model.id), freeBytes: disk.freeBytes)
    }

    /// Bytes the downloaded models take on this device (their manifest sizes).
    var installedBytes: Int64 {
        ModelCatalog.all.map(\.id).filter { status[$0] == .ready }.reduce(0) { $0 + downloadBytes($1) }
    }

    /// The files of a model as ModelInstaller parts, each pinned to its Hugging Face commit.
    func installerParts(_ id: String) -> [ModelInstaller.Part] {
        parts(id).map { entry, directory in
            let repo = entry.repo, revision = entry.revision
            let prefix = entry.subfolder.isEmpty ? "" : entry.subfolder + "/"
            return ModelInstaller.Part(
                directory: directory,
                files: entry.files.map { ModelInstaller.FileEntry(path: $0.key, sha256: $0.value.sha256, size: $0.value.size) },
                source: { path in
                    let encoded = (prefix + path).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                    return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(encoded)")
                })
        }
    }

    /// The model in use downloaded and checked out once, and its files are not all there now.
    var activeMissing: Bool { !activeReady && UserDefaults.standard.string(forKey: "verified.\(activeID)") != nil }

    func refresh() {
        for id in ModelCatalog.all.map(\.id) {
            if case .downloading = status[id] { continue }
            let verified = UserDefaults.standard.string(forKey: "verified.\(id)")
            let present = !parts(id).isEmpty && parts(id).allSatisfy { FileManager.default.fileExists(atPath: $0.1.path) }
            status[id] = (present && verified == manifest[id]?.revision) ? .ready : .notDownloaded
            if present, verified != manifest[id]?.revision { recheck(id) }
        }
    }

    /// Models whose files were hashed this run (recheck), so each folder is read at most once per launch.
    private var rechecked: Set<String> = []

    /// A model folder already on this device without this build's checked mark (an upgrade from an earlier Mac build,
    /// or a stop between install and the mark): every file is hashed once, off the main thread, and the model counts as
    /// downloaded only if every file matches its pinned sha256. Anything else stays "not downloaded".
    private func recheck(_ id: String) {
        guard !rechecked.contains(id), let revision = manifest[id]?.revision else { return }
        rechecked.insert(id)
        let parts = installerParts(id)
        Task {
            let counts = await Task.detached(priority: .utility) { () -> (ok: Int, total: Int) in
                var ok = 0, total = 0
                for part in parts {
                    for f in part.files {
                        total += 1
                        if (try? ModelManager.sha256(of: part.directory.appendingPathComponent(f.path))) == f.sha256 { ok += 1 }
                    }
                }
                return (ok, total)
            }.value
            NSLog("FFMODEL recheck \(id) files=\(counts.total) match=\(counts.ok)")
            guard counts.total > 0, counts.ok == counts.total else { return }
            if case .downloading = status[id] { return }
            UserDefaults.standard.set(revision, forKey: "verified.\(id)")
            status[id] = .ready
        }
    }

    /// Downloads a model, checks every file against its pinned sha256 and only then puts it in place (ModelInstaller).
    /// A failed or partial download never touches the model in use or an older copy of this one.
    func download(_ model: SpeechModel) async {
        guard await fetch(model.id) else { if pickWhenReady == model.id { pickWhenReady = nil }; return }
        if pickWhenReady == model.id { pickWhenReady = nil; activeID = model.id; return }    // picked: loads now
        // Nothing usable yet (first run, or the pick is still a download away): the model just verified is used.
        // A C++ model is used only when picked (Use); Core ML stays the automatic choice.
        if !activeReady, !model.engine.isCpp, model.fits(memoryBytes: device.memoryBytes) { activeID = model.id }   // loads now
        // Build 22: the one-time Neural Engine build starts right after the download, not at a dictation.
        else if activeID == model.id { Task { try? await self.ensureLoaded() } }
        else { Task { await self.prepareBuild(model.id) } }
    }

    /// The first Neural Engine load of each Core ML model, measured once on a Mac (Apple M5, 2026-10-31, one cold load
    /// of our pinned files each): Core ML builds the model for the device on that load and keeps the result, and later
    /// loads took 0.05 to 0.2 s (Whisper large-v3-turbo 0.83 s). iPhones and iPads build their own; this is an estimate.
    static let firstLoadOnMac: [String: Double] = [
        "medium": 11.1, "large": 114.0, "small": 14.1, "whisper-small-f16": 14.7, "whisper-base": 5.3, "whisper-tiny": 2.9,
        // Build 23, measured 10-31 on the M5 Mac with the app's own calls (command line): the first Neural Engine load.
        "parakeet-ultra": 7.1, "phonon-2": 52.4, "parakeet-redux": 3.8,
        // Bark 3.0 Pro: compiling Conway's packages for the device plus the first load.
        "bark-3-pro": 9.9,
    ]

    /// "about 2 min" or "about 11 s": the measured first load on a Mac, for the one-time build line.
    static func setupEstimate(_ id: String) -> String? {
        guard let s = firstLoadOnMac[id] else { return nil }
        return s >= 60 ? "about \(Int((s / 60).rounded())) min" : "about \(Int(s.rounded())) s"
    }

    /// The line for a load in flight. A model already built for this device loads in about a second, so for the first
    /// 3 s it is "Loading on the Neural Engine…"; past that it is the one-time build (or a build again, after the system
    /// let the old one go), with its time so far and what it took on a Mac.
    func loadLabel(_ id: String, now: Date = Date()) -> String? {
        guard building[id] != nil, let model = ModelCatalog.model(id) else { return nil }
        let s = activeSeconds(id, now: now)
        if model.engine.isCpp { return "Loading \(model.name) · \(s) s" }
        if s < 3 { return "Loading on the Neural Engine…" }
        // Build 24: the clock counts time in front only; iOS pauses a prepare while Free Flow is in the background.
        let paused = spans[id]?.wasPaused(now) == true ? " (paused while Free Flow was in the background)" : ""
        return "Preparing for this \(DeviceWord.current)'s Neural Engine (one time only) · \(s) s\(paused)"
    }

    /// Build 24: seconds a load has run with Free Flow in front.
    func activeSeconds(_ id: String, now: Date = Date()) -> Int {
        Int((spans[id] ?? building[id].map { ActiveSpan(began: $0) })?.seconds(now) ?? 0)
    }

    /// Build 24: Try again after a load passed its limit (the card's button).
    func retryPrepare(_ id: String) {
        stuck[id] = nil
        resumedOnce.remove(id)
        if id == activeID { Task { try? await self.ensureLoaded() } } else { Task { await self.prepareBuild(id) } }
    }

    private func stuckLine(_ id: String) -> String {
        let name = ModelCatalog.model(id)?.name ?? id
        return "\(name) did not get ready on this \(DeviceWord.current) in \(Int(Self.prepareLimit / 60)) minutes. Try again, or use another model."
    }

    /// Build 24: a load that passed its limit or was given up on. A load given up on after iOS suspended it starts
    /// again once; otherwise the model is marked on its card with Try again. True when it should be started again.
    private func noteStopped(_ id: String, _ error: Error) -> Bool {
        if error is LoadGate.Abandoned, !resumedOnce.contains(id) {
            resumedOnce.insert(id)
            NSLog("FFMODEL %@ given up on after the background: starting again", id)
            return true
        }
        stuck[id] = stuckLine(id)
        if !firstPrepareDone { firstPrepareDone = true; UserDefaults.standard.set(true, forKey: "firstPrepareDone") }
        NSLog("FFMODEL %@ stuck: %@ after %d s in front", id, String(describing: error), activeSeconds(id))
        return false
    }

    // MARK: Build 23: the first-prepare screen (PrepareLoader)

    /// Seconds a load of the pick runs before the full-screen loader shows: a model already built for this device loads
    /// in about a second (Whisper large-v3-turbo 0.83 s on a Mac), so a warm load never shows it. A model this device has
    /// built before waits longer (the system can let a build go; then it is built again and the loader shows).
    static let loaderAfter = 2.0
    static let loaderAfterIfPrepared = 10.0
    private static let preparedKey = "neuralEnginePrepared"
    /// Core ML keeps a build per OS build, so an OS update builds again.
    private static var osBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }
    /// Build 23: an app update builds again too (FluidAudio #1022: Ultra 105-109 s on an iPhone 18 Pro Max after each
    /// update), so the full-screen loader shows again after one.
    private static var preparedPrefix: String {
        osBuild + " app " + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?") + "|"
    }
    private lazy var prepared = Set(UserDefaults.standard.stringArray(forKey: Self.preparedKey) ?? [])

    func wasPrepared(_ id: String) -> Bool { prepared.contains(Self.preparedPrefix + id) }

    /// A Core ML model finished a load or a build on this device (OS and app build): later loads are warm.
    func notePrepared(_ id: String) {
        stuck[id] = nil
        resumedOnce.remove(id)
        if !firstPrepareDone { firstPrepareDone = true; UserDefaults.standard.set(true, forKey: "firstPrepareDone") }
        if failedHereIDs.contains(id) { noteFailedHere(id, false) }
        guard let model = ModelCatalog.model(id), !model.engine.isCpp, !wasPrepared(id) else { return }
        prepared = Set(prepared.filter { $0.hasPrefix(Self.preparedPrefix) }).union([Self.preparedPrefix + id])
        UserDefaults.standard.set(Array(prepared).sorted(), forKey: Self.preparedKey)
    }

    // MARK: Build 23: Core ML models that could not load on this device (per OS build: an OS update may load them)

    private static let failedHereKey = "coreMLLoadFailedHere"
    @Published private(set) var failedHereIDs: Set<String> = Set((UserDefaults.standard.stringArray(forKey: ModelManager.failedHereKey) ?? [])
        .filter { $0.hasPrefix(ModelManager.osBuild + "|") }.map { String($0.dropFirst(ModelManager.osBuild.count + 1)) })

    func failedHere(_ id: String) -> Bool { failedHereIDs.contains(id) }

    private func noteFailedHere(_ id: String, _ failed: Bool = true) {
        if failed { failedHereIDs.insert(id) } else { failedHereIDs.remove(id) }
        UserDefaults.standard.set(failedHereIDs.sorted().map { Self.osBuild + "|" + $0 }, forKey: Self.failedHereKey)
    }

    /// The pick whose Neural Engine build the full-screen loader shows now, or nil.
    func loaderID(now: Date = Date()) -> String? {
        // Build 24: full screen only for the first model a new install gets ready.
        guard !firstPrepareDone, building[activeID] != nil, let model = ModelCatalog.model(activeID), !model.engine.isCpp else { return nil }
        let wait = wasPrepared(activeID) ? Self.loaderAfterIfPrepared : Self.loaderAfter
        return Double(activeSeconds(activeID, now: now)) >= wait ? activeID : nil
    }

    // MARK: Build 23: the slow-model suggestion (SlowRule)

    /// The next smaller Neural Engine model that fits this device: the slow hint's suggestion.
    func smallerNeuralEngineModel(than id: String) -> SpeechModel? {
        guard let current = ModelCatalog.model(id) else { return nil }
        return ModelCatalog.all.filter { !$0.engine.isCpp && $0.downloadBytes < current.downloadBytes && $0.fits(memoryBytes: device.memoryBytes) }
            .max { $0.downloadBytes < $1.downloadBytes }
    }

    /// Pick a model; one not on the device yet is downloaded first and picked when it is ready (the slow hint's Switch).
    private var pickWhenReady: String?
    func use(_ id: String) {
        if status[id] == .ready { activeID = id; return }
        guard let model = ModelCatalog.model(id) else { return }
        pickWhenReady = id
        Task { await self.download(model) }
    }

    /// The short form for a model's row in Models.
    func loadShort(_ id: String, now: Date = Date()) -> String {
        guard building[id] != nil else { return "" }
        let s = activeSeconds(id, now: now)
        return s < 3 ? "Loading…" : "Preparing · \(s) s"
    }

    /// A Core ML model just downloaded and not picked gets its one-time Neural Engine build now, while
    /// nothing else loads and nothing is being dictated. The model in use is let go for it (one resident model) and
    /// loads again right after (about a second once built). Picking the model meanwhile turns the build into its load.
    func prepareBuild(_ id: String) async {
        guard let model = ModelCatalog.model(id), !model.engine.isCpp, status[id] == .ready, building.isEmpty,
              loadedID != id else { return }
        let engine = DictationEngine.shared
        guard engine.phase != .listening, engine.phase != .transcribing else {
            NSLog("FFMODEL build %@ not started: a dictation is running", id); return
        }
        stuck[id] = nil
        building[id] = Date()
        let background = BackgroundTime("Prepare speech model")
        defer { background.end() }
        let before = DeviceProfile.footprintBytes()
        NSLog("FFMODEL build-start %@ footprintMB=%llu", id, before >> 20)
        loadedID = nil
        do {
            let seconds = try await Transcriber.shared.prepare(id, limit: ActiveLimit(seconds: Self.prepareLimit))
            NSLog("FFMODEL build-done %@ load=%.2fs footprintMB before=%llu after=%llu", id, seconds, before >> 20,
                  DeviceProfile.footprintBytes() >> 20)
            notePrepared(id)
        } catch let stop where stop is LoadGate.TimedOut || stop is LoadGate.Abandoned {
            building[id] = nil
            loadedID = await Transcriber.shared.currentID
            if noteStopped(id, stop) { await prepareBuild(id) }
            return
        } catch {
            NSLog("FFMODEL build %@ ended: %@", id, error.localizedDescription)
        }
        building[id] = nil
        loadedID = await Transcriber.shared.currentID
        if activeReady, loadedID != activeID { Task { try? await self.ensureLoaded() } }
    }

    /// The download, check and install of one pinned manifest entry (a speech model or the writing model). True when it
    /// ended verified and in place.
    @discardableResult
    func fetch(_ id: String) async -> Bool {
        guard let revision = manifest[id]?.revision, !parts(id).isEmpty else {
            status[id] = .failed("Not available in this build yet.")
            return false
        }
        let total = downloadBytes(id)
        let installParts = installerParts(id)
        refreshDevice()
        let staged = ModelInstaller.stagedBytes(installParts, hash: nil)
        let room = DiskBudget.check(downloadBytes: total, freeBytes: disk.freeBytes, stagedBytes: staged)
        if case .noRoom = room {
            status[id] = .failed(DiskBudget.warning(room, device: DeviceWord.current) ?? "Not enough free space.")
            return false
        }
        status[id] = .downloading(0)
        defer { refreshDevice() }
        do {
            try await ModelInstaller.install(installParts, fetch: { url, destination, written in
                try await FileDownloader().download(url, to: destination, progress: written)
            }, hash: { try ModelManager.sha256(of: $0) }, progress: { done in
                Task { @MainActor in
                    // A late progress report never turns a finished or failed download back into "downloading".
                    if case .downloading = self.status[id] { self.status[id] = .downloading(min(1, Double(done) / Double(max(total, 1)))) }
                }
            })
            UserDefaults.standard.set(revision, forKey: "verified.\(id)")
            status[id] = .ready
            return true
        } catch {
            status[id] = .failed(error.localizedDescription)
            return false
        }
    }

    /// Deletes a model's files (and any partial download of it). Deleting the model in use moves dictation to another
    /// downloaded model: the recommended one if it is here, else the smallest Core ML model here, else any.
    func delete(_ model: SpeechModel) async {
        if loadedID == model.id { await Transcriber.shared.unload(); loadedID = nil; plan = [:]; loadedModelBytes = 0; lastBackend = nil }
        for (_, dir) in parts(model.id) { try? FileManager.default.removeItem(at: dir) }
        for part in installerParts(model.id) { try? FileManager.default.removeItem(at: part.staging) }
        UserDefaults.standard.removeObject(forKey: "verified.\(model.id)")
        refresh()
        if activeID == model.id, let next = Self.nextActive(after: model.id, ready: Set(status.filter { $0.value == .ready }.map(\.key)),
                                                         recommended: recommended.id, memoryBytes: device.memoryBytes) {
            activeID = next
        }
        refreshDevice()
    }

    /// Where dictation goes after its model is deleted; nil when no other model is downloaded.
    static func nextActive(after deleted: String, ready: Set<String>, recommended: String, memoryBytes: UInt64) -> String? {
        let left = ModelCatalog.all.filter { $0.id != deleted && ready.contains($0.id) && $0.fits(memoryBytes: memoryBytes) }
        if left.contains(where: { $0.id == recommended }) { return recommended }
        return (left.filter { !$0.engine.isCpp }.min { $0.downloadBytes < $1.downloadBytes } ?? left.first)?.id
    }

    /// Loads the active model (or, for Retry, the one picked) if needed; records load time and the Core ML compute plan.
    /// Build 22: the model in use is let go before this one loads (one resident model), memory is logged before, after
    /// and at its peak, and a load that a newer pick overtook ends with Transcriber.Superseded.
    @discardableResult
    func ensureLoaded(_ requested: String? = nil) async throws -> Double {
        let id = requested ?? activeID
        guard status[id] == .ready else { throw FFError("Download a speech model first: open Free Flow, then Models.") }
        if loadedID == id { return try await Transcriber.shared.load(id) }    // in use: 0 s, and it is the pick again
        let peak = PeakBox(DeviceProfile.footprintBytes())
        let sampler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                peak.note(DeviceProfile.footprintBytes())
                self?.notePeak()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        preparingCount += 1; preparing = true
        stuck[id] = nil
        if building[id] == nil { building[id] = Date() }
        loadedID = nil
        let background = BackgroundTime("Load speech model")
        defer {
            sampler.cancel()
            preparingCount -= 1; preparing = preparingCount > 0
            background.end()
        }
        let before = DeviceProfile.footprintBytes()
        NSLog("FFMODEL load-start %@ footprintMB=%llu", id, before >> 20)
        let seconds: Double
        do {
            seconds = try await Transcriber.shared.load(id, limit: ActiveLimit(seconds: Self.prepareLimit))
        } catch let stop where stop is LoadGate.TimedOut || stop is LoadGate.Abandoned {
            building[id] = nil
            loadedID = await Transcriber.shared.currentID
            if noteStopped(id, stop) { return try await ensureLoaded(requested) }
            throw FFError(stuckLine(id))
        } catch let superseded as Transcriber.Superseded {
            building[id] = nil
            loadedID = await Transcriber.shared.currentID
            throw superseded
        } catch {
            building[id] = nil
            loadedID = await Transcriber.shared.currentID
            NSLog("FFMODEL load-failed %@: %@", id, error.localizedDescription)
            // Missing files are not the device's fault: that error says to download again.
            guard requested == nil, !(error is DownloadError), let model = ModelCatalog.model(id), !model.engine.isCpp else {
                throw Self.plainLoadError(error, id: id)
            }
            // Core ML could not load this model on this device (build 23: FluidAudio #828, an int8 encoder that builds no
            // execution plan on an A16 iPhone). It is marked on its card; dictation moves to a Core ML model already on
            // the device, else the C++ fallback when its file is here, else the Core ML model to
            // download. Never a crash: the error is caught here.
            noteFailedHere(id)
            let ready = Set(status.filter { $0.value == .ready }.map(\.key))
            let next = EngineDefault.coreMLFallback(after: id, failedIDs: failedHereIDs, readyIDs: ready, memoryBytes: device.memoryBytes)
            if let next, ready.contains(next.id) {
                activeID = next.id
                crashNotice = EngineDefault.coreMLFallbackNotice(failed: model.name, to: next, downloaded: true, device: DeviceWord.current)
                return try await ensureLoaded()
            }
            if let cpp = EngineDefault.fallback(after: id, readyIDs: ready, memoryBytes: device.memoryBytes) {
                activeID = cpp.id
                crashNotice = EngineDefault.fallbackNotice(failed: model.name, to: cpp)
                return try await ensureLoaded()
            }
            guard let next else { throw Self.plainLoadError(error, id: id) }
            activeID = next.id
            let line = EngineDefault.coreMLFallbackNotice(failed: model.name, to: next, downloaded: false, device: DeviceWord.current)
            crashNotice = line
            throw FFError(line)
        }
        building[id] = nil
        let inUse = await Transcriber.shared.currentID
        loadedID = inUse
        if inUse == id {
            notePrepared(id)
            loadSeconds = seconds
            plan = [:]
            loadedModelBytes = await Transcriber.shared.loadedBytes
            lastBackend = nil
            lastReloadSeconds = 0
        }
        peak.note(DeviceProfile.footprintBytes())
        lastLoadPeakMB = peak.value >> 20
        NSLog("FFMODEL loaded %@ load=%.2fs footprintMB before=%llu after=%llu peak=%llu in-use=%@", id, seconds, before >> 20,
              DeviceProfile.footprintBytes() >> 20, peak.value >> 20, inUse ?? "none")
        notePeak()
        return seconds
    }

    /// FluidAudio runs offline (FreeFlowApp.init): a Parakeet file missing from this device throws instead of being
    /// fetched. Its error lists FluidAudio's file names; say what happened and what to do.
    static func plainLoadError(_ error: Error, id: String) -> Error {
        guard let download = error as? DownloadError else { return error }
        switch download {
        case .modelMissing, .networkDisabled:
            let name = ModelCatalog.model(id)?.name ?? id
            return FFError("Some files of \(name) are missing on this device. Delete it in Models, then download it again.")
        default:
            return error
        }
    }

    /// Reads Core ML's compute plan for the loaded model, once, when the stats screen is shown.
    func loadPlanIfNeeded() async {
        guard plan.isEmpty, let id = loadedID else { return }
        plan = await Transcriber.computePlan(directory: Transcriber.directory(for: id))
        notePeak()
    }

    func notePeak() {
        peakSeen = max(peakSeen, DeviceProfile.footprintBytes())
        guard peakSeen >= peakFootprint &+ (1 << 20), UIApplication.shared.applicationState == .active,
              Date().timeIntervalSince(lastPeakPublish) >= 1 else { return }
        peakFootprint = peakSeen
        lastPeakPublish = Date()
    }

    /// Back in front: show the peak measured while in the background, once.
    func publishPeak() {
        if peakSeen > peakFootprint { peakFootprint = peakSeen; lastPeakPublish = Date() }
    }

    func noteEngine(backend: String, reloadSeconds: Double) {
        lastBackend = backend
        lastReloadSeconds = reloadSeconds
        notePeak()
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file download with byte progress. Moves the file into place before returning.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: ((Int64) -> Void)?
    private var destination: URL!
    private var session: URLSession?

    func download(_ url: URL, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        self.destination = destination
        self.progress = progress
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(FFError("Download failed (HTTP \(http.statusCode))."))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

/// The highest memory footprint seen while a model loads (sampled every 50 ms on the main actor).
@MainActor
final class PeakBox {
    private(set) var value: UInt64
    init(_ start: UInt64) { value = start }
    func note(_ bytes: UInt64) { value = max(value, bytes) }
}

/// Extra time iOS gives a model load or a one-time Neural Engine build when Free Flow leaves the screen (Apple:
/// beginBackgroundTask, typically about 30 s; the app keeps running while a session holds the mic). When that time
/// runs out the app is suspended and the load goes on the next time Free Flow is in front. The Mac has no such limit.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            NSLog("FFMODEL background time ran out: %@", name)
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
