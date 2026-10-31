#if canImport(FoundationModels)
import FoundationModels
#endif
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import AVFAudio
import FreeFlowKit
import SwiftUI
import UIKit
import os

private let latencyLog = Logger(subsystem: "freeflow", category: "latency")
/// Why a recording started, stopped or ended, one line each, so a stop on a phone or iPad can be read from its unified
/// log (Console, log collect). Never the words: only phases, reasons, routes, seconds and memory.
private let recLog = Logger(subsystem: FF.subsystem, category: "recording")

struct RunStats: Equatable {
    let audioSeconds: Double
    let processSeconds: Double
    let loadSeconds: Double
    let modelName: String
    let footprintMB: Double
    let source: String
    var speed: Double { audioSeconds / max(processSeconds, 0.001) }
    var rtf: Double { processSeconds / max(audioSeconds, 0.001) }
    var line: String {
        String(format: "%.1f s of audio in %.2f s · %.0fx real time (RTF %.3f) · %@", audioSeconds, processSeconds, speed, rtf, modelName)
    }
}

/// Owns the microphone session and the dictation lifecycle. The session (mic open, audio mixed with
/// other apps) stays warm for the time chosen in Settings, so the keyboard can dictate without
/// opening the app. Audio is kept only while you dictate: in memory for the model, and as a clip in the app's own
/// folder so a call, an X or a crash can't lose it. A finished dictation deletes its clip at once; one that didn't
/// finish waits in History > Recent recordings (Retry, Delete) until it is deleted or reaches its age limit.
@MainActor
final class DictationEngine: ObservableObject {
    static let shared = DictationEngine()
    /// Who started the dictation: the app's own mic, the keyboard, or Start/Stop Free Flow (Action Button, controls, Siri, Back Tap).
    /// "iOS" or "macOS", and "Tap" or "Click", for messages that name the system or the gesture (build 21: the Mac
    /// app says what a Mac does).
    enum SystemWords {
        #if targetEnvironment(macCatalyst)
        static let os = "macOS", tap = "Click"
        #else
        static let os = "iOS", tap = "Tap"
        #endif
    }

    /// fn: the Mac's hold-fn dictation (Catalyst/MacHost.swift); the text comes back to it and goes in at the cursor.
    enum Target { case app, keyboard, trigger, fn }

    @Published private(set) var phase: SessionPhase = .off
    @Published private(set) var sessionLive = false
    @Published private(set) var sessionEndsAt: Date?
    /// Mic levels go into a ring here and reach SwiftUI only through LevelMeter (see LevelFeed): at most 10 a second,
    /// only while the app is active, and the keyboard's App Group copy only while the keyboard is on screen.
    private var feed = LevelFeed(count: 40)
    @Published var transcript = ""
    /// What happens after Finish, shown instead of a silent "Writing" (build 18): "Preparing speech model",
    /// "Transcribing", "Writing · Apple Intelligence". Empty when idle.
    @Published private(set) var stage = ""
    /// Shown when the chosen speech model is not the one recommended for this device and runs long (build 18, an
    /// iPad on Whisper large): which model is slow, which is recommended, and a one-tap switch when it is downloaded.
    /// Build 23: "A smaller model may feel faster on this device" (SlowRule decides when; never during the loader).
    struct SlowHint: Equatable { let model: String; let smaller: String; let smallerID: String }
    @Published private(set) var slowHint: SlowHint?
    /// The slow-model rule's memory on this device (waits per model, when it last asked, each "Not now").
    private var slowRule: SlowRule = (UserDefaults.standard.data(forKey: "slowRule")).flatMap { try? JSONDecoder().decode(SlowRule.self, from: $0) } ?? SlowRule() {
        didSet { if let data = try? JSONEncoder().encode(slowRule) { UserDefaults.standard.set(data, forKey: "slowRule") } }
    }
    private var stageTicker: Task<Void, Never>?
    private var prepareBegan: Date?
    private var busyBegan: Date?
    /// Build 22: the model being waited for at Finish, when the transcription itself began, and the recording's length
    /// (the honest "slow" rule compares the two).
    private var preparingID: String?
    private var transcribeBegan: Date?
    private var transcribeAudio: Double = 0
    /// The model that transcribed the last dictation (the switch test and the log check it against the pick).
    @Published private(set) var lastRanID: String?
    /// Kept recordings waiting for the picked model to be ready (park), and whether the waiter runs.
    private var waiting: [UUID] = []
    private var waitingRuns = false
    private var switchTestStarted = false
    /// Build 23 (security): the nonce of the last keyboard command acted on, and the session of the dictation
    /// running for a keyboard (nil when anything else started it).
    private var lastCommandNonce: String?
    private var keyboardSession: String?
    /// How long Finish waits for the picked model to load before keeping the recording for later (a first Neural Engine
    /// build can take minutes: 114 s for Whisper large-v3-turbo on a Mac).
    static let prepareLimit: Double = 30
    @Published private(set) var stats: RunStats? {
        // Each finished dictation's speed feeds the measured line in the model picker.
        didSet { if let stats { ModelManager.shared.noteRun(audioSeconds: stats.audioSeconds, processSeconds: stats.processSeconds) } }
    }
    @Published var errorText: String?
    /// The "Recording. Go back to your app" card for a keyboard that opened Free Flow (FreeFlowKit ReturnCard).
    @Published private(set) var returnCard = ReturnCard()

    let capture: AudioCapture
    /// The dictation in progress also goes to disk, chunk by chunk, and is closed cleanly when a call takes the mic.
    let recorder = ClipRecorder()
    /// "Recording stopped by a call or another app. Transcribe it?": a clip cut off by something other than you.
    @Published var recoveryPrompt: Clip?
    /// The saved recording being transcribed now (Retry or Transcribe).
    @Published private(set) var retryingID: UUID?
    private var heartbeat: Timer?
    private var target: Target = .app
    /// Times the capture restarted after a mic change (the Mac mic test reads it).
    private(set) var micRestarts = 0
    private let activity = LiveActivityController()
    /// True from a start request until it is listening or has failed. One keyboard press can reach the app
    /// twice on a cold launch (the freeflow://dictate link and the pending start read on becoming active), and
    /// the phase check alone lets both through while the first is still waiting on the session.
    private var starting = false
    /// Where the last Start/Stop Free Flow text went (typed by the keyboard or copied).
    private var delivery: Task<TriggerDelivery, Never>?

    init() {
        let file = ProcessInfo.processInfo.environment["FF_AUDIO_FILE"]
        capture = AudioCapture(testFile: file.map { URL(fileURLWithPath: $0) })
        capture.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.push(level) }
        }
        capture.onChunk = { [recorder] chunk in recorder.append(chunk) }
        recorder.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.clipEvent(event) } }
        // Build 23: the last run ended with the mic on (no end of ours was recorded after its last beat).
        if SharedSession.phase != .off, let last = SharedSession.heartbeat {
            SharedSession.noteEnd("Free Flow was closed with the mic on (by the system for memory, a crash, or swiped away)", at: last)
        }
        SharedSession.phase = .off
        SharedSession.heartbeat = nil
        #if !targetEnvironment(macCatalyst)
        // Build 23 (security): a keyboard command counts only with the keyboard's fresh, unused nonce
        // (KeyboardCommand). The Mac has no keyboard extension, so no Darwin observers there.
        DarwinBus.shared.observe(.start) { [weak self] in Task { @MainActor in await self?.keyboardCommand(.start) } }
        DarwinBus.shared.observe(.finish) { [weak self] in Task { @MainActor in await self?.keyboardCommand(.finish) } }
        DarwinBus.shared.observe(.cancel) { [weak self] in Task { @MainActor in await self?.keyboardCommand(.cancel) } }
        #endif
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let simulated = note.userInfo?[DictationEngine.simulatedKey] != nil
            Task { @MainActor in self?.interrupted(began: type == .began, shouldResume: options.contains(.shouldResume), simulated: simulated) }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesReset() }
        }
        // Apple, AVAudioEngineConfigurationChange: when the hardware's channel count or sample rate changes "the engine
        // stops itself"; the app must reinstall its taps and start it again. Only our own engine's notifications count.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, self.capture.owns(note.object) else { return }
                self.routeChanged()
            }
        }
        // Apple, "Responding to audio route changes" (AVAudioSession.routeChangeNotification): logged with its reason, so a
        // stop on a device shows which change came before it.
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let before = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?.inputs.map(\.portType.rawValue) ?? []
            let now = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue)
            recLog.log("route change reason=\(reason, privacy: .public) inputs \(before.joined(separator: ","), privacy: .public) -> \(now.joined(separator: ","), privacy: .public)")
        }
        // Older builds could keep the mic ready for 8 hours or "until I end it"; it must always disarm by itself.
        UserDefaults.standard.set(ArmWindow.minutes(stored: UserDefaults.standard.object(forKey: "sessionMinutes") as? Int), forKey: "sessionMinutes")
        // A recording the last run never finished (killed, crashed, out of memory): fix its file, offer it once.
        let clips = ClipStore.shared
        clips.recover()
        clips.purge(ClipRetention.current)
        recoveryPrompt = clips.recent().first { $0.needsPrompt }
        waiting = clips.all().filter { $0.status == .waiting }.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        if !waiting.isEmpty { Task { await self.runWaiting() } }
    }

    static func installIntentHooks() {
        FFActions.toggleDictation = { inForeground in
            let e = DictationEngine.shared
            let active = inForeground || UIApplication.shared.applicationState == .active
            if active { NoticePoster.requestPermission() }
            let outcome: TriggerOutcome
            switch TriggerPlanner.step(phase: e.phase, sessionLive: e.sessionLive, appActive: active) {
            case .busy: outcome = .busy
            case .openApp: outcome = .needsApp
            case .start:
                await e.startDictation(target: .trigger)
                outcome = e.phase == .listening ? .listening : .failed(e.errorText ?? "Could not start.")
            case .stop:
                outcome = await e.finishForTrigger()
            }
            if case .failed = outcome { NoticePoster.post(outcome) }
            return outcome
        }
        FFActions.finishDictation = {
            let e = DictationEngine.shared
            if e.phase == .listening { return (await e.finishForTrigger()).value }
            e.endSession("Turned off from a shortcut or control")
            return ""
        }
        FFActions.startSession = {
            let e = DictationEngine.shared
            do { try await e.startSession() } catch { return error.localizedDescription }
            #if targetEnvironment(macCatalyst)
            return "Free Flow is ready. Hold fn in any app to dictate."
            #else
            return "Free Flow is ready. The keyboard will dictate without switching apps."
            #endif
        }
    }

    var settings: AppSettings { AppSettings() }

    // MARK: Session

    func startSession() async throws {
        if !sessionLive {
            SharedSession.offReason = ""
            activity.start(model: ModelManager.shared.active.name)
            if !capture.usesTestFile {
                guard await Self.micPermission() else {
                    throw FFError("Free Flow needs the microphone. Turn it on in Settings > Free Flow.")
                }
                try configureAudioSession()
            }
            try capture.start()
            sessionLive = true
            SharedSession.inputName = capture.usesTestFile ? "Test recording" : Self.inputName()
            heartbeat?.invalidate()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
            // Lets iOS fire it together with other wakeups (Energy Efficiency Guide: timer tolerance, at least 10%).
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
            setPhase(.ready)
        }
        extendSession()
        beat()
    }

    func endSession(_ why: String = "You turned it off") {
        recLog.log("session end phase=\(self.phase.rawValue, privacy: .public) why=\(why, privacy: .public)")
        if sessionLive { SharedSession.noteEnd(why) }
        lastBeat = nil
        if phase == .listening {
            _ = capture.end()
            recorder.stop(.interrupted, reason: ClipReason.sessionEnded)
        }
        capture.stop()
        heartbeat?.invalidate()
        heartbeat = nil
        sessionLive = false
        sessionEndsAt = nil
        SharedSession.heartbeat = nil
        SharedSession.endsAt = nil
        setPhase(.off)
        activity.end()
        if !capture.usesTestFile {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func extendSession() {
        sessionEndsAt = Date().addingTimeInterval(Double(settings.sessionMinutes) * 60)
        SharedSession.endsAt = sessionEndsAt
        activity.endsAt = sessionEndsAt
    }

    /// Build 23: the last heartbeat. A gap over SessionTruth.staleAfter with the mic on is when every keyboard saw the
    /// mic off (and reopened the app to turn it on): the app was suspended or its main thread was blocked.
    private var lastBeat: Date?

    private func beat() {
        let now = Date()
        if let last = lastBeat, sessionLive, now.timeIntervalSince(last) > SessionTruth.staleAfter {
            let gap = now.timeIntervalSince(last)
            let loading = ModelManager.shared.building.keys.sorted().compactMap { ModelCatalog.model($0)?.name }.joined(separator: " and ")
            SharedSession.noteEnd("Free Flow was paused for \(Int(gap.rounded())) s with the mic on, so the keyboard saw it off"
                                  + (loading.isEmpty ? "" : " (\(loading) was loading)"), at: last)
            recLog.log("heartbeat gap \(gap, format: .fixed(precision: 1), privacy: .public)s phase=\(self.phase.rawValue, privacy: .public) loading=\(loading, privacy: .public)")
        }
        lastBeat = now
        SharedSession.heartbeat = Date()
        // The keyboard clears the words from the App Group when it types them. Text no keyboard typed leaves when
        // KeyboardAwait stops waiting for it (10 minutes after it was ready); History keeps its own copy if it is on.
        if let at = SharedSession.resultAt, Date().timeIntervalSince(at) > KeyboardAwait.window, !SharedSession.resultText.isEmpty {
            SharedSession.resultText = ""
        }
        if ArmWindow.shouldDisarm(endsAt: sessionEndsAt, phase: phase, resultAt: SharedSession.resultAt) {
            endSession("The mic's \(settings.sessionMinutes)-minute window ended")
        }
        ModelManager.shared.notePeak()
        CpuMeter.shared.sample()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try AudioSessionSetup.configure(session, mixWithOthers: settings.mixWithOthers, duckOthers: settings.duckOthers)
        KeyClickCounts.hapticsAllowedWhileMic = session.allowHapticsAndSystemSoundsDuringRecording
    }

    private var armedBeforeInterruption = false

    /// A call, Siri or another app took the audio. The mic is off from that moment, and every surface says so.
    /// When it ends, come back only if iOS says to resume and the session really restarts; otherwise stay Off.
    private func interrupted(began: Bool, shouldResume: Bool, simulated: Bool = false) {
        recLog.log("interruption \(began ? "began" : "ended", privacy: .public) phase=\(self.phase.rawValue, privacy: .public) shouldResume=\(shouldResume, privacy: .public) simulated=\(simulated, privacy: .public)")
        guard !capture.usesTestFile || simulated else { return }
        if began {
            armedBeforeInterruption = sessionLive
            apply(InterruptionRule.began(phase: sessionLive ? phase : .off))
        } else {
            apply(InterruptionRule.ended(shouldResume: shouldResume, wasArmed: armedBeforeInterruption))
            armedBeforeInterruption = false
        }
    }

    /// AirPods connected or disconnected, a different mic: restart on the new route, or go Off and say why.
    /// The engine stopped itself for a hardware change. Right after the change the input can read 0 Hz for a moment,
    /// so the restart is tried for about a second before the mic is called lost; samples taken so far stay.
    private func routeChanged() {
        recLog.log("engine configuration change phase=\(self.phase.rawValue, privacy: .public) live=\(self.sessionLive, privacy: .public) input=\(Self.inputName(), privacy: .public)")
        guard sessionLive, !capture.usesTestFile else { return }
        Task { @MainActor in
            for attempt in 1...10 {
                do {
                    #if targetEnvironment(macCatalyst)
                    // macOS: the engine that saw the change stays on the old device; record on a new one (build 19, the
                    // Mac app measured the same engine silent for 7 of 11 half-seconds after a switch).
                    capture.stop()
                    capture.rebuild()
                    try capture.start()
                    #else
                    try capture.restart()
                    #endif
                    micRestarts += 1
                    recLog.log("mic restarted after the change, attempt \(attempt, privacy: .public)")
                    return
                } catch {
                    recLog.log("mic restart attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard sessionLive else { return }
            }
            apply(InterruptionRule.routeLost)
        }
    }

    private func apply(_ step: InterruptionStep) {
        switch step {
        case .nothing: break
        case .tryResume:
            Task {
                do { try await startSession() } catch { apply(InterruptionRule.resumeFailed) }
            }
        case .turnOff(let reason): turnOff(reason, clip: step == InterruptionRule.routeLost ? ClipReason.routeLost : ClipReason.interruption)
        }
    }

    /// iOS reset its audio (a media-server crash; rare). ClipRecorder has already closed the clip. Every audio
    /// object is dead now, so start from a new engine and go Off.
    private func mediaServicesReset() {
        guard !capture.usesTestFile else { return }
        capture.rebuild()
        if sessionLive || phase == .listening { turnOff("\(SystemWords.os) restarted its audio. \(SystemWords.tap) to turn on.", clip: ClipReason.audioReset) }
    }

    /// The mic is really off now: end the session, keep any half dictation as a clip, and publish why at once.
    func turnOff(_ reason: String, clip clipReason: String = ClipReason.interruption) {
        recLog.log("turn off phase=\(self.phase.rawValue, privacy: .public) clip=\(clipReason, privacy: .public)")
        if phase == .listening {
            _ = capture.end()
            // What was said up to here stays (nil when ClipRecorder already closed it on the notification).
            recorder.stop(.interrupted, reason: clipReason)
        }
        endSession(reason)
        SharedSession.offReason = reason
        errorText = reason
        DarwinBus.shared.post(.state)
        NoticePoster.post(.failed(reason))
    }

    static func micPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    static func inputName() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Microphone"
    }

    // MARK: Dictation

    /// Build 23 (security): acts on a keyboard command only when the App Group holds the keyboard's fresh, unused
    /// nonce for it, and a finish or cancel only for the dictation that keyboard started. Read a few times: the
    /// keyboard's App Group write can reach this process just after its notification.
    func keyboardCommand(_ name: DarwinName) async {
        var accepted: KeyboardCommand?
        for attempt in 0..<5 {
            let command = SharedSession.keyboardCommand
            if KeyboardCommand.accepts(command, name: name, lastNonce: lastCommandNonce, currentSession: keyboardSession) {
                accepted = command
                break
            }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 60_000_000) }
        }
        guard let command = accepted else {
            recLog.log("keyboard \(name.rawValue, privacy: .public) ignored: no fresh, unused request from the keyboard")
            return
        }
        lastCommandNonce = command.nonce
        SharedSession.keyboardCommand = nil
        switch name {
        case .start: await startDictation(target: .keyboard, session: command.session)
        case .finish: _ = await finishDictation()
        case .cancel: cancelDictation()
        default: break
        }
    }

    /// Build 23 (security): the keyboard's open-and-start (its link, or the start read on becoming active). Starts only
    /// when the keyboard wrote its start (with a nonce) and pendingStart in the last seconds; both are used up then.
    /// Anything else, or a link from anywhere else, just opens Free Flow. From the link it reads again for up to 1.5 s:
    /// on a cold launch the keyboard's App Group write can reach this process after the link does.
    /// Both callers may run at once: the check and the use of the nonce happen together on the main actor, so one starts.
    private func startFromKeyboardOpen(fromLink: Bool = false) {
        Task { @MainActor in
            let tries = fromLink ? 15 : 1
            for attempt in 0..<tries {
                let pending = SharedSession.pendingStart, command = SharedSession.keyboardCommand
                if let pending, Date().timeIntervalSince(pending) < KeyboardCommand.openFreshFor, let command,
                   KeyboardCommand.accepts(command, name: .start, lastNonce: lastCommandNonce, currentSession: nil,
                                           fresh: KeyboardCommand.openFreshFor) {
                    SharedSession.pendingStart = nil
                    SharedSession.keyboardCommand = nil
                    lastCommandNonce = command.nonce
                    updateReturnCard { $0.openedByKeyboard() }
                    await startDictation(target: .keyboard, session: command.session)
                    return
                }
                if fromLink, attempt == tries - 1 {
                    let p = pending.map { String(format: "%.1f s", Date().timeIntervalSince($0)) } ?? "none"
                    let c = command.map { "\($0.name) \(String(format: "%.1f s", Date().timeIntervalSince($0.at)))" } ?? "none"
                    recLog.log("keyboard link: no fresh start from the keyboard (pending \(p, privacy: .public), request \(c, privacy: .public))")
                }
                if attempt < tries - 1 { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        }
    }

    func startDictation(target: Target, session: String? = nil) async {
        guard !starting, phase != .listening, phase != .transcribing else { return }
        guard retryingID == nil else { fail("Free Flow is transcribing a saved recording. Try again in a moment."); return }
        starting = true
        defer { starting = false }
        errorText = nil
        SharedSession.error = ""
        let wasArmed = sessionLive
        guard ModelManager.shared.activeReady else {
            fail(ModelManager.shared.activeMissing
                 ? "Your speech model is missing. Open Free Flow, then Models, to download it again."
                 : "Download a speech model first: open Free Flow, then Models.")
            return
        }
        do { try await startSession() } catch { fail(error.localizedDescription); return }
        self.target = target
        // Build 23 (security): the keyboard that asked owns this dictation's text; any other start owns none.
        keyboardSession = target == .keyboard ? session : nil
        SharedSession.dictationSession = keyboardSession ?? (target == .trigger ? KeyboardCommand.triggerSession : "")
        feed.reset()
        LevelMeter.shared.show(feed.snapshot)
        dropLastKept()          // build 23: the last dictation's audio goes when the next dictation starts
        recorder.start()
        capture.begin()
        setPhase(.listening)
        recLog.log("listening target=\(String(describing: target), privacy: .public) footprintMB=\(DeviceProfile.footprintBytes() >> 20, privacy: .public)")
        simulateInterruptionIfAsked()
        noteLatency(target: target, warm: wasArmed)
        // Load the model while you talk.
        Task { try? await ModelManager.shared.ensureLoaded() }
    }

    @discardableResult
    func finishDictation() async -> String {
        guard phase == .listening else { return "" }
        let audio = capture.end()
        // The clip stays on disk until the text is out: if Free Flow ends now, it is offered at the next launch.
        let clip = recorder.stop(.transcribing)
        setPhase(.transcribing)
        let seconds = Double(audio.count) / AudioCapture.rate
        recLog.log("finish audio=\(Int(seconds), privacy: .public)s footprintMB=\(DeviceProfile.footprintBytes() >> 20, privacy: .public) model=\(ModelManager.shared.activeID, privacy: .public)")
        guard seconds >= 0.3 else {
            if let clip { ClipStore.shared.delete(clip.id) }
            fail("Didn't catch that. Try again."); return ""
        }
        do {
            let models = ModelManager.shared
            // Build 22: the model picked when you finish transcribes, and only that one. Its load (started on Use) gets
            // at most prepareLimit; past that the recording is kept and transcribed once the model is ready (park).
            // Build 18 waited with no limit, and build 19 could run whichever model happened to be loaded.
            var load = 0.0, raw = "", ran = models.activeID, start = Date(), tries = 0, againAfterError = false
            while true {
                let pick = models.activeID
                if models.loadedID != pick {
                    prepareBegan = Date(); preparingID = pick
                    setStage(models.loadLabel(pick) ?? "Preparing speech model")
                } else {
                    setStage("Transcribing")
                }
                // Build 23: the pick is in its first Neural Engine prepare (the full-screen loader's case, e.g. after
                // "Dictate now"): kept for it at once, not after prepareLimit.
                if models.loaderID() == pick { park(clip?.id, pick: pick); return "" }
                let loaded = await Deadline.run(Self.prepareLimit) { () -> Result<Double, Error> in
                    do { return .success(try await ModelManager.shared.ensureLoaded()) } catch { return .failure(error) }
                }
                prepareBegan = nil; preparingID = nil
                guard let loaded else { park(clip?.id, pick: models.activeID); return "" }
                switch loaded {
                case .failure(let error):
                    if error is Transcriber.Superseded, tries < 3 { tries += 1; continue }
                    throw error
                case .success(let seconds):
                    load = seconds
                }
                ran = models.loadedID ?? models.activeID      // the C++ fallback may have replaced the pick
                setStage("Transcribing")
                transcribeBegan = Date(); transcribeAudio = seconds
                start = Date()
                do {
                    raw = try await transcribeLimited(audio, model: ran)
                    transcribeBegan = nil
                    break
                } catch let changed as Transcriber.ModelChanged where tries < 3 {
                    transcribeBegan = nil
                    tries += 1
                    NSLog("FFMODEL pick changed before transcription (expected %@, in use %@): again with the pick",
                          changed.expected, changed.loaded ?? "none")
                } catch {
                    transcribeBegan = nil
                    // Build 23 (on an iPad on build 22: one 28 s Whisper large dictation failed and a retry of the same
                    // recording worked): an error from the model itself is tried once more, with the pick checked and
                    // loaded again first. Not the time limit (it already waited), and only once. The error is logged.
                    if !againAfterError, !lastTranscribeTimedOut {
                        againAfterError = true
                        recLog.log("transcription error, once more: \(String(describing: error), privacy: .public)")
                        NSLog("FFMODEL transcription error by=%@ audio=%.1fs (%@): once more", ran, seconds, String(describing: error))
                        continue
                    }
                    throw error
                }
            }
            lastRanID = ran
            let ranName = ModelCatalog.model(ran)?.name ?? ran
            NSLog("FFMODEL transcribed by=%@ pick=%@ audio=%.1fs", ran, models.activeID, seconds)
            // C++ models: a backend switch reloads the model inside the call; that is load time, not speed.
            let elapsed = max(0.001, Date().timeIntervalSince(start) - models.lastReloadSeconds)
            models.notePeak()
            noteWait(model: ran, seconds: elapsed, audio: seconds)
            let style = SharedSession.style
            // Build 12: the recognizer's words (dictionary applied in decoding), never rewritten by a rule; the on-device
            // writing model (WritingModel) writes them in the chosen style, or they go in as heard.
            if let writer = WritingModel.stageName() { setStage("Writing · " + writer) }
            let (text, readout) = await WritingModel.written(DictationText.finish(raw), style: style)
            let notUsed = WritingReadoutStore.shared.notUsed
            stats = RunStats(audioSeconds: seconds, processSeconds: elapsed, loadSeconds: load > 0 ? load : (models.loadSeconds ?? 0), modelName: ranName,
                             footprintMB: Double(DeviceProfile.footprintBytes()) / 1_000_000,
                             source: capture.usesTestFile ? "Test recording (simulator)" : SharedSession.inputName)
            transcript = text
            // Before history: on first use the stats store counts older history once, so this one must not be in it yet.
            StatsStore.shared.record(.live(text: text, raw: raw, samples: audio, rate: AudioCapture.rate, processSeconds: elapsed, model: ranName))
            if settings.keepHistory, !text.isEmpty {
                HistoryStore.shared.add(HistoryItem(text: text, raw: raw, style: style, model: ranName,
                                                    audioSeconds: seconds, processSeconds: elapsed, writer: readout?.short))
            }
            // Finished: the text is out. Build 23: Apple Intelligence's version left out words -> the recording stays in
            // Recent recordings with both texts. Otherwise, with LastDictation.keepAudio, the last dictation's audio stays
            // 10 minutes (or until the next dictation) for Retry; without it, it is deleted now.
            if let clip {
                let store = ClipStore.shared
                if let notUsed {
                    store.update(clip.id) { $0.status = .transcribed; $0.reason = ClipReason.writerLeftOut; $0.text = text
                        $0.written = notUsed; $0.model = ranName; $0.acknowledged = true }
                } else if LastDictation.keepAudio, ClipRetention.current != .never {
                    store.update(clip.id) { $0.status = .transcribed; $0.reason = LastDictation.reason; $0.text = text
                        $0.model = ranName; $0.acknowledged = true }
                    lastKeptClip = clip.id
                    Task { [id = clip.id] in
                        try? await Task.sleep(nanoseconds: UInt64(LastDictation.keepFor * 1_000_000_000) + 1_000_000_000)
                        if let c = ClipStore.shared.clip(id), LastDictation.isExpired(c, now: Date()) { ClipStore.shared.delete(id) }
                    }
                } else {
                    store.delete(clip.id)
                }
            }
            SharedSession.resultText = text
            SharedSession.resultAt = Date()
            let id = UUID().uuidString
            SharedSession.resultID = id
            setPhase(.done)
            delivery = target == .trigger ? Task { await self.deliverTrigger(text, id: id) } : nil
            return text
        } catch {
            recLog.log("transcription failed: \(error.localizedDescription, privacy: .public)")
            if let clip { ClipStore.shared.update(clip.id) { $0.status = .failed; $0.reason = error.localizedDescription } }
            fail(error.localizedDescription)
            return ""
        }
    }

    /// Stop for Start/Stop Free Flow. A dictation started in the app itself is copied, so a press can finish it too;
    /// one the keyboard started stays the keyboard's, and it types the text.
    func finishForTrigger() async -> TriggerOutcome {
        if target == .app { target = .trigger }
        let started = target
        let text = await finishDictation()
        if text.isEmpty { return phase == .error ? .failed(errorText ?? "Something went wrong.") : .finished(.nothing, text: "") }
        if started == .keyboard { return .finished(.typed, text: text) }
        return .finished(await delivery?.value ?? .copied, text: text)
    }

    /// The keyboard, when it is on screen, types every new result and writes back its id; otherwise copy it.
    private func deliverTrigger(_ text: String, id: String) async -> TriggerDelivery {
        let result = await TriggerRouting.deliver(text: text, id: id, keyboardSeenAt: { SharedSession.keyboardUpAt },
                                                  insertedID: { SharedSession.insertedID },
                                                  copy: { UIPasteboard.general.string = $0 })
        activity.update(phase: .done, detail: text, label: result == .typed ? "Typed" : "Copied")
        NoticePoster.post(.finished(result, text: text))
        return result
    }

    /// Tap (keyboard) or press (Action Button, control, Siri, Back Tap) to capture starting, in milliseconds.
    private func noteLatency(target: Target, warm: Bool) {
        let pressed = target == .keyboard ? SharedSession.tapAt : SharedSession.lastTrigger
        guard let pressed, Date().timeIntervalSince(pressed) < 60 else { return }
        let ms = Date().timeIntervalSince(pressed) * 1000
        SharedSession.lastLatencyMs = ms
        latencyLog.notice("FFLATENCY target=\(String(describing: target), privacy: .public) warm=\(warm, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
    }

    func cancelDictation() {
        guard phase == .listening else { return }
        _ = capture.end()
        // X cancels the paste, never the audio: the clip waits in History > Recent recordings with Retry.
        recorder.stop(.cancelled, reason: ClipReason.cancelled)
        setPhase(sessionLive ? .ready : .off)
    }

    // MARK: Saved recordings

    private func clipEvent(_ event: ClipRecorder.Event) {
        switch event {
        case .saved(let id, .interrupted):
            guard let clip = ClipStore.shared.clip(id) else { return }
            NoticePoster.postClipSaved(clip)
            // A call: ask when it ends (or when Free Flow is next in front). A lost mic or an ended session: ask now.
            if clip.reason != ClipReason.interruption { recoveryPrompt = clip }
        case .interruptionEnded(let id?, _):
            if let clip = ClipStore.shared.clip(id), clip.needsPrompt { recoveryPrompt = clip }
        default:
            break
        }
    }

    /// The answer to "Transcribe it?". Later leaves the clip in History > Recent recordings.
    func answerPrompt(transcribe: Bool) async {
        guard let clip = recoveryPrompt else { return }
        recoveryPrompt = nil
        ClipStore.shared.update(clip.id) { $0.acknowledged = true }
        if transcribe { await retry(clip.id) }
    }

    /// Retry: the saved audio through the model picked (or the active one). The text goes to History and stays
    /// with the clip; nothing is typed or pasted. The clip stays until it is deleted or reaches its age limit.
    /// Build 23: Retry has no model choice. It uses the pick: the model in use, or the one loading or being
    /// prepared now, and waits for it with the recording kept. It never loads, prepares or switches to another model
    /// (build 22's choice let a retry load Whisper large while Whisper small was being prepared: two at once).
    func retry(_ id: UUID) async {
        let store = ClipStore.shared
        guard retryingID == nil, !starting, phase != .listening, phase != .transcribing,
              let clip = store.clip(id), clip.canRetry else { return }
        retryingID = id
        defer { retryingID = nil }
        if recoveryPrompt?.id == id { recoveryPrompt = nil }
        store.update(id) { $0.status = .transcribing; $0.acknowledged = true }
        let models = ModelManager.shared
        let chosen = models.activeID
        // The pick still loading or being prepared: kept for it, and transcribed the moment it is ready.
        if models.loadedID != chosen, models.building[chosen] != nil {
            retryingID = nil
            wait(for: id, name: ModelCatalog.model(chosen)?.name ?? chosen)
            NSLog("FFMODEL retry kept for %@ (still preparing)", chosen)
            return
        }
        do {
            let audio = try store.samples(id)
            let load = try await models.ensureLoaded()
            let start = Date()
            let raw = try await transcribeLimited(audio, model: chosen)
            // C++ models: a backend switch reloads the model inside the call; that is load time, not speed.
            let elapsed = max(0.001, Date().timeIntervalSince(start) - models.lastReloadSeconds)
            let style = SharedSession.style
            // Build 12: the recognizer's words (dictionary applied in decoding), never rewritten by a rule; the on-device
            // writing model (WritingModel) writes them in the chosen style, or they go in as heard.
            let (text, readout) = await WritingModel.written(DictationText.finish(raw), style: style)
            let name = ModelCatalog.model(chosen)?.name ?? chosen
            let seconds = Double(audio.count) / AudioCapture.rate
            store.update(id) { $0.status = .transcribed; $0.reason = ""; $0.text = text; $0.model = name }
            transcript = text
            lastRanID = chosen
            NSLog("FFMODEL transcribed by=%@ pick=%@ audio=%.1fs (saved recording)", chosen, models.activeID, seconds)
            stats = RunStats(audioSeconds: seconds, processSeconds: elapsed, loadSeconds: load, modelName: name,
                             footprintMB: Double(DeviceProfile.footprintBytes()) / 1_000_000, source: "Saved recording")
            if settings.keepHistory, !text.isEmpty {
                HistoryStore.shared.add(HistoryItem(text: text, raw: raw, style: style, model: name,
                                                    audioSeconds: seconds, processSeconds: elapsed, writer: readout?.short))
            }
        } catch {
            store.update(id) { $0.status = .failed; $0.reason = error.localizedDescription }
        }
    }

    nonisolated static let simulatedKey = "FFSimulated"

    /// UI tests only (launch argument -ffSimulateInterruption <seconds>): posts the interruption notifications iOS
    /// posts when a call comes in, that many seconds after listening starts, and the end 2 s later. It proves the
    /// app's handling in the simulator; a real phone, FaceTime or WhatsApp call needs a device.
    private func simulateInterruptionIfAsked() {
        let after = UserDefaults.standard.double(forKey: "ffSimulateInterruption")
        guard after > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            guard self.phase == .listening else { return }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue, Self.simulatedKey: true])
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: UInt(0), Self.simulatedKey: true])
        }
    }

    // MARK: Entry points

    func handle(_ url: URL) {
        guard FF.isOurs(url) else { return }
        // Build 23 (security): "dictate" starts only for the keyboard that asked; "session" no longer arms the mic
        // (that takes a tap in Free Flow). Either way the link just opens Free Flow.
        if url.host == "dictate" { startFromKeyboardOpen(fromLink: true) }
    }

    func becameActive() {
        ModelManager.shared.refresh()
        #if DEBUG || FF_TESTS
        // Test builds only (security): the model-switching test from a launch argument.
        if !switchTestStarted, let spec = UserDefaults.standard.string(forKey: "ffSwitchTest") {
            switchTestStarted = true
            Task { let rc = await self.runSwitchTest(spec); exit(rc) }
        }
        #endif
        ModelManager.shared.publishPeak()
        if phase == .listening { LevelMeter.shared.show(feed.snapshot) }
        let clips = ClipStore.shared
        clips.purge(ClipRetention.current, active: recorder.activeID)
        if recoveryPrompt.flatMap({ clips.clip($0.id) }) == nil { recoveryPrompt = clips.recent().first { $0.needsPrompt } }
        // Start loading the model now, not on the first press. The first launch after an update Core ML
        // prepares it again, which can take a while; presses that come in meanwhile wait for this same load.
        if ModelManager.shared.activeReady { Task { try? await ModelManager.shared.ensureLoaded() } }
        // Build 18: Apple's model is prewarmed too, never when writing is off.
        WritingModel.warm()
        startFromKeyboardOpen()
    }

    /// Free Flow left the screen: the return card's trip is over (back in the person's app, or anywhere else).
    func leftApp() { updateReturnCard { $0.leftApp() } }

    /// Stay here on the return card: Free Flow itself, with its own Finish and Cancel.
    func stayHere() { updateReturnCard { $0.stay() } }

    /// Publishes only a real change: every @Published assignment redraws what observes the engine.
    private func updateReturnCard(_ change: (inout ReturnCard) -> Void) {
        var card = returnCard
        change(&card)
        if card != returnCard { returnCard = card }
    }

    // MARK: State

    private func setStage(_ s: String) {
        guard stage != s else { return }
        stage = s
        SharedSession.stage = s
        DarwinBus.shared.post(.state)
        activity.update(phase: .transcribing, detail: "", label: s)
    }

    /// Build 18: transcription has a time limit too, so the screen never stays on "Transcribing" for good (seen on an
    /// iPad on iPadOS 27). Past it the recording stays in History › Recent recordings with Retry.
    /// Set when transcribeLimited gave up at its time limit (that error is not tried again).
    private var lastTranscribeTimedOut = false
    private func transcribeLimited(_ audio: [Float], model: String) async throws -> String {
        lastTranscribeTimedOut = false
        let seconds = Double(audio.count) / AudioCapture.rate
        let limit = max(90, 4 * seconds)
        let words = DictionaryStore.shared.words
        let result = await Deadline.run(limit) { () -> Result<String, Error> in
            do { return .success(try await Transcriber.shared.transcribe(audio, words: words, expect: model).text) } catch { return .failure(error) }
        }
        guard let result else {
            lastTranscribeTimedOut = true
            recLog.log("transcription time limit \(Int(limit), privacy: .public)s")
            throw FFError("Transcribing took over \(Int(limit)) s, so Free Flow stopped waiting. Your recording is saved in History › Recent recordings: try it again there, or pick the recommended speech model in Models.")
        }
        return try result.get()
    }

    /// The slow hint's Switch: the smaller model from now on (downloaded first if it is not on the device).
    func switchToSmaller() {
        guard let hint = slowHint else { return }
        slowRule.switched(from: hint.model)
        slowHint = nil
        NSLog("FFMODEL slow hint: switch %@ -> %@", hint.model, hint.smallerID)
        ModelManager.shared.use(hint.smallerID)
    }
    /// The slow hint's Not now (twice for one model: never asked again for it).
    func notNowSlowHint() {
        if let hint = slowHint { slowRule.notNow(hint.model) }
        slowHint = nil
    }

    /// Build 23: after each dictation, its wait after speech (the transcription itself, without the model's load)
    /// goes into SlowRule; when the rule says so and a smaller Neural Engine model exists, the hint shows once.
    private func noteWait(model: String, seconds: Double, audio: Double) {
        slowRule.record(model: model, wait: seconds, audio: audio)
        let models = ModelManager.shared
        let now = Date()
        guard slowHint == nil, models.loaderID(now: now) == nil, slowRule.mayAsk(model, now: now),
              let smaller = models.smallerNeuralEngineModel(than: model) else { return }
        slowRule.asked(now: now)
        NSLog("FFMODEL slow hint: %@ waits %@ (wait/recording s); suggesting %@", model,
              (slowRule.recent[model] ?? []).map { String(format: "%.2f/%.0f", $0.wait, $0.audio) }.joined(separator: ","), smaller.id)
        slowHint = SlowHint(model: model, smaller: smaller.name, smallerID: smaller.id)
    }

    /// While Finish is being processed: count the prepare seconds on screen, and name a slow, non-recommended speech
    /// model after 20 s (build 18).
    private func tick() {
        let now = Date()
        let models = ModelManager.shared
        if let began = prepareBegan {
            setStage(preparingID.flatMap { models.loadLabel($0, now: now) } ?? "Preparing speech model · \(Int(now.timeIntervalSince(began))) s")
        }
        // Build 23: the slow-model hint comes from SlowRule after each dictation (noteWait), not from this ticker.
    }

    private func setPhase(_ p: SessionPhase) {
        if p != .transcribing, !stage.isEmpty { stage = ""; SharedSession.stage = "" }
        if p == .transcribing {
            busyBegan = Date()
            stageTicker?.cancel()
            stageTicker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.tick()
                }
            }
        } else {
            stageTicker?.cancel(); stageTicker = nil; busyBegan = nil; prepareBegan = nil
        }
        phase = p
        updateReturnCard { $0.phaseChanged(p) }
        SharedSession.phase = p
        DarwinBus.shared.post(.state)
        activity.update(phase: p, detail: p == .done ? transcript : (errorText ?? ""))
    }

    /// Build 22: the picked model is still loading after prepareLimit (a first Neural Engine build can take
    /// minutes). The recording is kept as a saved clip and transcribed the moment the pick is in use; the text shows on
    /// Dictate and in History. Nothing is typed later into an app you may have left.
    private func park(_ clipID: UUID?, pick: String) {
        let name = ModelCatalog.model(pick)?.name ?? pick
        recLog.log("kept for later: model \(pick, privacy: .public) still loading")
        NSLog("FFMODEL kept recording: %@ still loading after %.0fs", pick, Self.prepareLimit)
        guard let clipID else { fail("\(name) is still loading. Try again in a moment."); return }
        wait(for: clipID, name: name)
        saved("Saved. Free Flow writes this when \(name) is ready (it is being prepared for this \(DeviceWord.current)'s Neural Engine). The text shows here and in History.")
    }

    /// Build 23: the last finished dictation's recording, kept for Retry until the next dictation or 10 minutes.
    private var lastKeptClip: UUID?
    private func dropLastKept() {
        guard let id = lastKeptClip else { return }
        lastKeptClip = nil
        if let c = ClipStore.shared.clip(id), c.reason == LastDictation.reason, c.status == .transcribed { ClipStore.shared.delete(id) }
    }

    /// Build 23: a recording kept for the pick: "Saved. Free Flow writes this when <model> is ready." in Recent
    /// recordings, and transcribed automatically once the pick is in use (runWaiting).
    private func wait(for clipID: UUID, name: String) {
        ClipStore.shared.update(clipID) { $0.status = .waiting; $0.reason = name; $0.acknowledged = true }
        if !waiting.contains(clipID) { waiting.append(clipID) }
        Task { await self.runWaiting() }
    }

    /// Transcribes the kept recordings once the picked model is in use and no dictation is running.
    private func runWaiting() async {
        guard !waitingRuns else { return }
        waitingRuns = true
        defer { waitingRuns = false }
        let models = ModelManager.shared
        while let id = waiting.first {
            guard ClipStore.shared.clip(id) != nil else { waiting.removeFirst(); continue }
            if models.activeReady, models.loadedID == models.activeID, phase != .listening, phase != .transcribing,
               retryingID == nil, !starting {
                waiting.removeFirst()
                await retry(id)
                let done = ClipStore.shared.clip(id)?.status == .transcribed
                NSLog("FFMODEL kept recording transcribed=%d by=%@", done ? 1 : 0, lastRanID ?? "none")
                if done, phase == .error { errorText = nil; SharedSession.error = ""; setPhase(.done) }
            } else {
                if models.activeReady, models.building[models.activeID] == nil, models.loadedID != models.activeID {
                    Task { try? await models.ensureLoaded() }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func fail(_ message: String) {
        errorIsSaved = false
        errorText = message
        SharedSession.error = message
        setPhase(.error)
    }

    /// Build 23: the end of a dictation that is kept, not lost (shown in the normal text color, not as an error).
    @Published private(set) var errorIsSaved = false
    private func saved(_ message: String) {
        errorIsSaved = true
        errorText = message
        SharedSession.error = message
        setPhase(.error)
    }

    private func push(_ level: Float) {
        guard phase == .listening else { return }
        let now = Date()
        let out = feed.push(level, now: now.timeIntervalSinceReferenceDate,
                            appActive: UIApplication.shared.applicationState == .active,
                            keyboardShowing: { KeyboardPresence.isShowing(upAt: SharedSession.keyboardUpAt, now: now) })
        if let ui = out.ui { LevelMeter.shared.show(ui) }
        if let shared = out.shared { SharedSession.levels = Array(shared.suffix(32)) }
    }
}

/// The only SwiftUI object that changes with the mic level. Only the listening panel observes it, so a level redraws
/// the meter and nothing else (build 8 kept the levels on DictationEngine, which the App and every screen observe).
@MainActor
final class LevelMeter: ObservableObject {
    static let shared = LevelMeter()
    @Published private(set) var levels = [Float](repeating: 0, count: 40)
    func show(_ snapshot: [Float]) { if snapshot != levels { levels = snapshot } }
}

/// This process's CPU time (getrusage: user + system of every thread) against wall time, sampled every second while
/// the mic session is live and before each piece of C++ work in the background (CpuBudget).
final class CpuMeter: @unchecked Sendable {
    static let shared = CpuMeter()
    private let lock = NSLock()
    private var budget = CpuBudget(limit: 0.5)

    static func processCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func sample() {
        let t = Self.now(), c = Self.processCPU()
        lock.withLock { budget.record(t: t, cpu: c) }
    }

    /// Seconds to wait before work costing `cost` CPU seconds (0 = go).
    func wait(cost: Double) -> Double {
        let t = Self.now(), c = Self.processCPU()
        return lock.withLock { budget.record(t: t, cpu: c); return budget.wait(t: t, cpu: c, cost: cost) }
    }

    var allowed: Double { lock.withLock { budget.allowed } }
}

struct AppSettings {
    private let d = UserDefaults.standard
    var sessionMinutes: Int {
        #if targetEnvironment(macCatalyst)
        // Build 23 (F2): the Mac's own choice; 0 (off right after a dictation) leaves the usual window for other starts.
        let mac = MacMic.minutes(stored: d.object(forKey: MacMic.key) as? Int)
        if mac > 0 { return mac }
        #endif
        return ArmWindow.minutes(stored: d.object(forKey: "sessionMinutes") as? Int)
    }
    var mixWithOthers: Bool { d.object(forKey: "mixWithOthers") as? Bool ?? true }
    var duckOthers: Bool { d.object(forKey: "duckOthers") as? Bool ?? false }
    var keepHistory: Bool { d.object(forKey: "keepHistory") as? Bool ?? true }
}

#if targetEnvironment(macCatalyst)
/// The Mac has no Live Activities: the pill and the menu-bar item show the state (Catalyst/MacHost.swift).
@MainActor
final class LiveActivityController {
    var endsAt: Date?
    func start(model: String) {}
    func update(phase: SessionPhase, detail: String, label override: String? = nil) {}
    func end() {}
}
#else
/// The Live Activity that iOS requires while an AudioRecordingIntent records, also shown for keyboard sessions.
@MainActor
final class LiveActivityController {
    private var activity: Activity<DictationActivityAttributes>?
    private var startedAt = Date()
    private var lastLabel = "Ready", lastDetail = ""
    /// When the armed window ends; the Live Activity counts down to it.
    var endsAt: Date? {
        didSet { if oldValue != endsAt { push() } }
    }

    func start(model: String) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        startedAt = Date()
        lastLabel = "Ready"; lastDetail = ""
        let state = DictationActivityAttributes.ContentState(phase: "Ready", detail: "", startedAt: startedAt, endsAt: endsAt)
        activity = try? Activity.request(attributes: DictationActivityAttributes(modelName: model),
                                         content: ActivityContent(state: state, staleDate: nil))
    }

    func update(phase: SessionPhase, detail: String, label override: String? = nil) {
        guard let activity else { return }
        var label: String
        switch phase {
        case .listening: label = "Listening"
        case .transcribing: label = "Transcribing"
        case .done: label = "Copied"
        case .error: label = "Try again"
        default: label = "Ready"
        }
        if let override { label = override }
        lastLabel = label; lastDetail = String(detail.prefix(120))
        push()
    }

    private func push() {
        guard let activity else { return }
        let state = DictationActivityAttributes.ContentState(phase: lastLabel, detail: lastDetail, startedAt: startedAt, endsAt: endsAt)
        Task { await activity.update(ActivityContent(state: state, staleDate: endsAt)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif

/// Whether Apple's on-device model can run, and why not, as last checked off the main thread (WritingModel.refreshApple).
@MainActor
final class AppleStatus: ObservableObject {
    static let shared = AppleStatus()
    @Published var available = false
    /// Why it cannot run here, in a few words (nil while it can, or before the first check).
    @Published var reason: String?
}

/// The writing layer (build 18: LFM3 is dropped). Apple Foundation Models, the on-device system
/// model, with guardrails .permissiveContentTransformations (made for rewriting the person's own text; the default
/// guardrails refused an ordinary dictated line in the bake-off), when the person has writing on (Settings › Writing) and
/// Apple Intelligence can run here. Otherwise the speech model's text, with the dictionary words, goes in as heard, and
/// the readout says why. The Style pill picks the prompt (WritingPrompt). Nothing leaves the phone and nothing is
/// filtered: any error, refusal or unusable answer (WritingGuard) puts the heard text in for that piece, never edited
/// by a rule. Runs in the app only: the keyboard types the text the app finishes.
enum WritingModel {
    static func write(_ text: String, style: DictationStyle) async -> String { await written(text, style: style).text }

    /// The text and what wrote it (nil readout for empty text). The readout and the heard text are kept in memory for
    /// the last-dictation card (WritingReadoutStore).
    static func written(_ text: String, style: DictationStyle) async -> (text: String, readout: WritingReadout?) {
        guard !text.isEmpty else { return (text, nil) }
        let result: (text: String, readout: WritingReadout)
        if WriterChoice.resolved == .off {
            // Writing off (Settings › Writing): no model is called, nothing is loaded or checked.
            result = raw(text, background: false, note: "Apple Intelligence cleanup is off")
        } else {
            // Build 15: the step has a time limit (WritingBudget); past it the text goes in as heard, never a stall.
            // Build 18: the WHOLE step (availability check and writing) runs under it, on its own task.
            let budget = WritingBudget.seconds(words: WritingReadout.words(text))
            let deadline = Date().addingTimeInterval(budget)
            let routed = await Deadline.run(budget + 0.25) { () -> (text: String, readout: WritingReadout) in
                let foreground = await MainActor.run { inForeground() }
                return await appleOrRaw(text, style: style, background: !foreground, deadline: deadline)
            }
            if let routed { result = routed } else {
                NSLog("FFWRITE used=0 kept-raw=all why=step-time-limit limit-ms=%.0f", budget * 1000)
                result = raw(text, background: false, note: String(format: "time limit %.1f s", budget))
            }
        }
        await MainActor.run {
            WritingReadoutStore.shared.last = result.readout
            WritingReadoutStore.shared.heard = text
            WritingReadoutStore.shared.notUsed = AppleWriterNotUsed.take()
        }
        return (result.text, result.readout)
    }

    @MainActor static func inForeground() -> Bool { UIApplication.shared.applicationState == .active }

    /// Whether Apple's model can run here, and if not, why (SystemLanguageModel.availability, read off the main thread).
    static var appleCheck: (available: Bool, reason: String?) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return AppleWriter.check }
        #endif
        return (false, "needs \(DictationEngine.SystemWords.os) 26 or later")
    }
    static var appleAvailable: Bool { appleCheck.available }

    /// Apple's model availability as last checked OFF the main thread (views never call FoundationModels).
    @MainActor static var appleSeen: Bool { AppleStatus.shared.available }
    static func refreshApple() {
        Task.detached(priority: .utility) {
            let c = appleCheck
            await MainActor.run {
                if AppleStatus.shared.available != c.available { AppleStatus.shared.available = c.available }
                if AppleStatus.shared.reason != c.reason { AppleStatus.shared.reason = c.reason }
            }
        }
    }

    /// At app open: check Apple's model and prewarm it on its own task, so the first dictation does not pay for it.
    /// Nothing when writing is off.
    @MainActor static func warm() {
        guard WriterChoice.resolved != .off else { return }
        refreshApple()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { Task.detached(priority: .utility) { AppleWriter.prewarm() } }
        #endif
    }

    /// The writer named in the "Writing · ..." stage, or nil when no writer will run.
    @MainActor static func stageName() -> String? {
        WriterChoice.resolved == .off ? nil : (appleSeen ? "Apple Intelligence" : nil)
    }

    /// Apple's model where it can run, else the heard text with the reason.
    static func appleOrRaw(_ text: String, style: DictationStyle, background: Bool, deadline: Date) async -> (text: String, readout: WritingReadout) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let c = AppleWriter.check
            if c.available { return await AppleWriter.write(text, style: style, background: background, deadline: deadline) }
            NSLog("FFWRITE used=0 kept-raw=all why=unavailable %@", String(describing: AppleWriter.model.availability))
            return raw(text, background: background, note: c.reason ?? "Apple Intelligence not available")
        }
        #endif
        NSLog("FFWRITE used=0 kept-raw=all why=os-before-26")
        return raw(text, background: background, note: "Apple Intelligence needs \(DictationEngine.SystemWords.os) 26")
    }

    static func raw(_ text: String, background: Bool, note: String) -> (text: String, readout: WritingReadout) {
        let n = WritingReadout.words(text)
        return (text, WritingReadout(model: "None", runtime: "raw text", background: background, wordsIn: n, wordsOut: n,
                                     seconds: 0, note: note))
    }
}

/// Build 23: the writer's version that the safety net did not use, handed from the writer's task to the main actor once.
enum AppleWriterNotUsed {
    nonisolated(unsafe) private static var value: String?
    private static let lock = NSLock()
    static func put(_ s: String?) { lock.withLock { value = s } }
    static func take() -> String? { lock.withLock { defer { value = nil }; return value } }
}

#if canImport(FoundationModels)
/// Apple's model writes into this one field (guided generation).
@available(iOS 26.0, *)
@Generable
struct WrittenText {
    @Guide(description: "The transcript rewritten in the requested style. Only the rewritten text.")
    var text: String
}

@available(iOS 26.0, *)
enum AppleWriter {
    static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    static var available: Bool { check.available }
    /// Available, or why not in a few words (shown in Settings, at setup and in Where it runs).
    static var check: (available: Bool, reason: String?) {
        switch model.availability {
        case .available: return (true, nil)
        case .unavailable(let why):
            switch why {
            case .deviceNotEligible: return (false, "this device can't run Apple Intelligence")
            case .appleIntelligenceNotEnabled: return (false, "Apple Intelligence is off in the Settings app")
            case .modelNotReady: return (false, "Apple's model is still downloading")
            @unknown default: return (false, "Apple's model is not available")
            }
        }
    }
    /// Kept so its prewarmed resources stay loaded; never used to write.
    nonisolated(unsafe) private static var warmSession: LanguageModelSession?
    static func prewarm() {
        guard available else { return }
        let s = LanguageModelSession(model: model, instructions: WritingPrompt.instructions(for: SharedSession.style))
        s.prewarm()
        warmSession = s
    }

    static func write(_ text: String, style: DictationStyle, background: Bool, deadline: Date) async -> (text: String, readout: WritingReadout) {
        let start = Date()
        var out = "", used = 0, kept = 0, timedOut = 0, notUsed = ""
        defer { AppleWriterNotUsed.put(notUsed.isEmpty ? nil : notUsed.trimmingCharacters(in: .whitespaces)) }
        var reasons: [String] = []
        func because(_ r: String) { if !reasons.contains(r) { reasons.append(r) } }
        let instructions = WritingPrompt.instructions(for: style)
        for piece in WritingGuard.pieces(text) {
            guard piece.write else { out += piece.text; continue }
            let budget = deadline.timeIntervalSinceNow
            if budget < 0.05 { out += piece.text; kept += 1; timedOut += 1; continue }
            let message = WritingPrompt.message(piece.text)
            let words = piece.text.split(separator: " ").count
            // Past the limit the request is cancelled and the piece goes in as heard.
            let result = await Deadline.run(budget) { () -> Result<String, Error> in
                do {
                    // Build 16: guided generation. The answer is one text field, so there is no room for "Sure, here is".
                    let session = LanguageModelSession(model: AppleWriter.model, instructions: instructions)
                    let r = try await session.respond(to: message, generating: WrittenText.self, includeSchemaInPrompt: true,
                                                      options: GenerationOptions(sampling: .greedy, maximumResponseTokens: max(300, words * 4)))
                    return .success(r.content.text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch { return .failure(error) }
            }
            switch result {
            case .some(.success(let answer)):
                if WritingGuard.leftOut(raw: piece.text, written: answer) {
                    // Build 23 safety net (a long dictation came back cut in half): the answer lost a large
                    // share of what was said, so this piece goes in as heard; both versions stay in Recent recordings.
                    NSLog("FFWRITE piece kept-raw why=left-out words-in=%d words-out=%d", WritingReadout.words(piece.text), WritingReadout.words(answer))
                    out += piece.text; kept += 1; because("Apple Intelligence left out words, so the text as heard was used")
                    notUsed += answer + " "
                } else if let why = WritingGuard.reject(raw: piece.text, written: answer) {
                    NSLog("FFWRITE piece kept-raw why=%@", why); out += piece.text; kept += 1; because(why == "empty answer" ? "Apple Intelligence gave an empty answer" : "Apple Intelligence: " + why)
                } else { out += answer; used += 1 }
            case .some(.failure(let error)):
                NSLog("FFWRITE piece kept-raw error=%@", String(describing: error)); out += piece.text; kept += 1; because(plain(error))
            case .none:
                NSLog("FFWRITE piece kept-raw why=time-limit"); out += piece.text; kept += 1; timedOut += 1
            }
        }
        let seconds = Date().timeIntervalSince(start)
        NSLog("FFWRITE used=%d kept-raw=%d timed-out=%d ms=%.0f words=%d style=%@ runtime=apple bg=%d", used, kept, timedOut,
              seconds * 1000, text.split(separator: " ").count, style.rawValue, background ? 1 : 0)
        if timedOut > 0 { because(String(format: "time limit %.1f s", deadline.timeIntervalSince(start))) }
        let note = reasons.isEmpty ? nil : reasons.joined(separator: ", ")
        return (out, WritingReadout(model: "Apple on-device model", runtime: "Apple Foundation Models", background: background,
                                    wordsIn: WritingReadout.words(text), wordsOut: WritingReadout.words(out), seconds: seconds,
                                    keptRaw: kept, note: note, used: used))
    }

    /// Why Apple's model gave no text for a piece, in a few plain words (the readout under the dictation).
    static func plain(_ error: Error) -> String {
        #if compiler(>=6.4)
        // iOS 27 reports errors as LanguageModelError, with Apple's own reason (e.g. "May contain unsafe content").
        if #available(iOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .refusal(let r): return "Apple Intelligence refused (" + r.debugDescription + ")"
            case .guardrailViolation(let g): return "Apple Intelligence refused (" + g.debugDescription + ")"
            case .rateLimited: return "Apple Intelligence rate-limited (\(DictationEngine.SystemWords.os) limits it in the background)"
            case .contextSizeExceeded: return "too long for Apple Intelligence"
            case .unsupportedLanguageOrLocale: return "language not supported by Apple Intelligence"
            case .timeout: return "Apple Intelligence timed out"
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                return "Apple Intelligence can't take this request"
            @unknown default: return "Apple Intelligence error (" + chain(error as NSError) + ")"
            }
        }
        #endif
        guard let e = error as? LanguageModelSession.GenerationError else { return "Apple Intelligence error (" + chain(error as NSError) + ")" }
        switch e {
        case .refusal, .guardrailViolation: return "Apple Intelligence refused"
        case .rateLimited: return "Apple Intelligence rate-limited (\(DictationEngine.SystemWords.os) limits it in the background)"
        case .concurrentRequests: return "Apple Intelligence busy"
        case .assetsUnavailable: return "Apple's model not ready"
        case .unsupportedLanguageOrLocale: return "language not supported by Apple Intelligence"
        case .exceededContextWindowSize: return "too long for Apple Intelligence"
        case .decodingFailure, .unsupportedGuide: return "Apple Intelligence answer unreadable"
        @unknown default: return "Apple Intelligence error (" + chain(error as NSError) + ")"
        }
    }

    /// An error Apple gives no case for, as its domains and codes, outermost first: e.g. the iOS 26.5 simulator's
    /// "GenerationError -1, SensitiveContentAnalysisML 15, ModelManagerError 1001" (10-30), so the line says exactly
    /// what failed.
    static func chain(_ error: NSError) -> String {
        var parts: [String] = [], queue = [error]
        while !queue.isEmpty, parts.count < 4 {
            let e = queue.removeFirst()
            let p = (e.domain.split(separator: ".").last.map(String.init) ?? e.domain) + " \(e.code)"
            if !parts.contains(p) { parts.append(p) }
            if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(u) }
            if let us = e.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { queue.append(contentsOf: us) }
        }
        return parts.joined(separator: ", ")
    }
}
#endif

#if DEBUG || FF_TESTS
extension DictationEngine {
    /// Test builds only (security). Test of build 22's model switching: launch argument -ffSwitchTest "<steps>" (iOS) or --switchtest (Mac), fed by
    /// the recorded test file (FF_AUDIO_FILE, FF_TEST_CLIP_SECONDS long). Steps, comma separated:
    /// - "id": pick it (as Use does), wait until it is in use, dictate the recording;
    /// - "a>b": pick a, then b 2 s later (a switch during a load), wait for b, dictate;
    /// - "a~b": dictate with a in use and pick b 3 s into the recording (a switch while recording);
    /// - "!id": pick it and dictate at once, without waiting for its load (a kept recording if it is still loading).
    /// - any step + "@N": that dictation records N seconds instead of FF_TEST_CLIP_SECONDS (build 23).
    /// Each dictation logs the model that transcribed it and whether that is the pick (RC 1 if any is not); each switch
    /// logs memory before, after and at its peak. A model not on the device is downloaded first.
    func runSwitchTest(_ spec: String) async -> Int32 {
        let models = ModelManager.shared
        let defaultClip = Double(ProcessInfo.processInfo.environment["FF_TEST_CLIP_SECONDS"] ?? "") ?? 12
        var rc: Int32 = 0
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        NSLog("FFSWITCH start steps=%@ footprintMB=%llu", spec, DeviceProfile.footprintBytes() >> 20)
        for (n, full) in spec.split(separator: ",").map(String.init).enumerated() {
            let at = full.components(separatedBy: "@")
            let raw = at[0]
            let clipSeconds = at.count == 2 ? (Double(at[1]) ?? defaultClip) : defaultClip
            let now = raw.hasPrefix("!")
            let step = now ? String(raw.dropFirst()) : raw
            let duringLoad = step.components(separatedBy: ">"), duringRec = step.components(separatedBy: "~")
            let first = duringLoad.count == 2 ? duringLoad[0] : (duringRec.count == 2 ? duringRec[0] : step)
            let target = duringLoad.count == 2 ? duringLoad[1] : (duringRec.count == 2 ? duringRec[1] : step)
            for id in [first, target] where models.status[id] != .ready {
                NSLog("FFSWITCH %d download %@", n, id)
                guard await models.fetch(id) else { NSLog("FFSWITCH %d download failed: %@", n, id); return 2 }
            }
            let before = DeviceProfile.footprintBytes() >> 20
            let t0 = Date()
            var t1 = t0
            models.activeID = first
            // The pick unchanged (didSet starts nothing) but not in use, e.g. the first step at launch: load it as Use does.
            if models.loadedID != first, models.building[first] == nil, models.activeReady { Task { try? await models.ensureLoaded() } }
            if duringLoad.count == 2 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                t1 = Date()
                models.activeID = target
            }
            let ready = duringRec.count == 2 ? first : target
            if !now {
                while models.loadedID != ready || models.building[ready] != nil, Date().timeIntervalSince(t0) < 900 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                NSLog("FFSWITCH %d step=%@ in-use=%@ ready-after=%.2fs footprintMB before=%llu after=%llu load-peak=%llu", n, raw,
                      models.loadedID ?? "none", Date().timeIntervalSince(t1), before, DeviceProfile.footprintBytes() >> 20,
                      models.lastLoadPeakMB)
            }
            lastRanID = nil
            await startDictation(target: .app)
            if duringRec.count == 2 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                models.activeID = target
                try? await Task.sleep(nanoseconds: UInt64(max(1, clipSeconds - 3) * 1_000_000_000))
            } else {
                try? await Task.sleep(nanoseconds: UInt64(clipSeconds * 1_000_000_000))
            }
            var text = await finishDictation()
            if now, lastRanID == nil {       // kept for later: wait for it to be transcribed
                let t = Date()
                while lastRanID == nil, Date().timeIntervalSince(t) < 600 { try? await Task.sleep(nanoseconds: 200_000_000) }
                NSLog("FFSWITCH %d kept recording done after %.1fs more", n, Date().timeIntervalSince(t))
                text = transcript
            }
            let by = lastRanID ?? "none"
            let ok = by == target && models.activeID == target
            if !ok { rc = 1 }
            NSLog("FFSWITCH %d dictated pick=%@ by=%@ match=%d clip=%.0fs words=%d footprintMB=%llu error=%@ text=%@", n,
                  models.activeID, by, ok ? 1 : 0, clipSeconds, text.split(separator: " ").count, DeviceProfile.footprintBytes() >> 20,
                  errorText ?? "none", String(text.prefix(90)))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        NSLog("FFSWITCH RC=%d", rc)
        return rc
    }
}
#endif
