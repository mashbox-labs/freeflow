import AVFoundation
import AppKit
import ApplicationServices
import FreeFlowKit
import os

private let log = Logger(subsystem: FF.subsystem + ".mac", category: "dictation")

/// The Mac dictation: fn (FnGesture through FnKeyMonitor) starts and stops the mic; the words go through the iPhone app's
/// pipeline (Parakeet on Core ML with the user's dictionary, then the writing model in the chosen style) and into the
/// app in front (TextInserter). The mic runs only while you dictate. Logs carry phases and seconds, never words.
@MainActor
final class MacDictation: ObservableObject {
    static let shared = MacDictation()

    enum Phase: Equatable { case idle, listening, handsFree, working }

    @Published private(set) var phase: Phase = .idle
    /// The last finished text (in memory only), for "Paste last dictation" when the paste did not land.
    @Published private(set) var lastText = ""
    @Published private(set) var lastReadout: WritingReadout?
    /// A recording whose transcription failed, kept in memory so "Try the last recording again" can finish it.
    @Published private(set) var failedAudio: [Float]?

    let capture = AudioCapture(testFile: nil)
    let pill = PillController()
    let hotkey = FnKeyMonitor()
    let dictionary = DictionaryStore(url: MacDictation.supportFolder.appendingPathComponent("dictionary.json"))
    private var gesture = FnGesture()
    private var configObserver: NSObjectProtocol?
    /// Times the capture restarted after a mic change (the mic test reads it).
    private(set) var micRestarts = 0
    /// Opens the setup window (set by the app delegate).
    var openSetup: (() -> Void)?

    static var supportFolder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Free Flow")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var style: DictationStyle {
        get { DictationStyle(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .formal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "style"); objectWillChange.send() }
    }

    init() {
        capture.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.pill.push(level) }
        }
        pill.model.onStop = { [weak self] in self?.stopFromPill() }
        pill.model.onCancel = { [weak self] in self?.cancel(reason: "pill") }
        hotkey.onFn = { [weak self] down, others in
            guard let self else { return }
            let t = ProcessInfo.processInfo.systemUptime
            self.apply(down ? self.gesture.fnPressed(at: t, otherModifiers: others) : self.gesture.fnReleased(at: t))
        }
        // AirPods and other Bluetooth headsets switch to their call profile the moment an app opens their mic, and macOS
        // then stops the engine ("iounit configuration changed"); a USB mic plugged in or out does the same. Mid-recording
        // the capture starts again on the new format and keeps what it already has (a pair of AirPods, build 18, 10-30).
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.capture.owns(note.object) else { return }
                self.micChanged(attempt: 0)
            }
        }
        hotkey.onKey = { [weak self] key in
            guard let self else { return false }
            let r = self.gesture.keyPressed(key, at: ProcessInfo.processInfo.systemUptime)
            self.apply(r.action)
            return r.swallow
        }
    }

    func startHotkey() { hotkey.start() }

    private func apply(_ action: FnGesture.Action) {
        switch action {
        case .none: break
        case .start: start(handsFree: false)
        case .startHandsFree: start(handsFree: true)
        case .becomeHandsFree:
            if phase == .listening { phase = .handsFree; pill.show(.handsFree) }
        case .stopAndInsert: Task { await finish() }
        case .cancel: cancel(reason: "gesture")
        }
    }

    // MARK: Recording

    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start(handsFree: Bool) {
        guard phase == .idle else { return }
        guard MacModels.shared.speechReady else {
            gesture.reset()
            pill.flash("Set up Free Flow first")
            openSetup?()
            return
        }
        guard Self.micAllowed else {
            gesture.reset()
            pill.flash("Free Flow needs the microphone")
            openSetup?()
            return
        }
        do {
            capture.rebuild()      // a fresh engine each time picks up the current input device
            try capture.start()
        } catch {
            gesture.reset()
            pill.flash("No microphone found")
            log.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        capture.begin()
        phase = handsFree ? .handsFree : .listening
        pill.show(handsFree ? .handsFree : .listening)
        log.log("listening handsFree=\(handsFree, privacy: .public)")
        // Load the speech model and prewarm Apple's model while you talk.
        Task { try? await MacTranscriber.shared.load() }
        MacWriter.prepare()
    }

    /// The mic's device or format changed while the engine ran. While recording: start the capture again (a Bluetooth
    /// headset can take a moment to show its new format, so up to 5 tries 0.2 s apart); if it can't, finish with what was
    /// recorded. Not recording: nothing (the next dictation starts a fresh engine).
    private func micChanged(attempt: Int) {
        guard phase == .listening || phase == .handsFree else { return }
        do {
            // A new engine: the old one stays bound to the device it started on and delivers nothing after the change
            // (measured with --mictest --switch, 10-30). The samples so far stay; collecting goes on.
            capture.stop()
            capture.rebuild()
            try capture.start()
            micRestarts += 1
            log.log("mic changed while recording: capture restarted (try \(attempt + 1, privacy: .public))")
        } catch {
            if attempt < 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    MainActor.assumeIsolated { self?.micChanged(attempt: attempt + 1) }
                }
            } else {
                log.error("mic changed while recording and did not come back: \(error.localizedDescription, privacy: .public)")
                gesture.reset()
                Task { await finish() }
            }
        }
    }

    func cancel(reason: String) {
        guard phase == .listening || phase == .handsFree else { return }
        _ = capture.end()
        capture.stop()
        gesture.reset()
        phase = .idle
        pill.hide()
        log.log("cancelled by \(reason, privacy: .public)")
    }

    private func stopFromPill() {
        gesture.reset()
        Task { await finish() }
    }

    func finish() async {
        guard phase == .listening || phase == .handsFree else { return }
        let audio = capture.end()
        capture.stop()
        await process(audio)
    }

    /// Transcribe, write, insert. A recording that fails is kept in memory for one retry from the menu.
    func process(_ audio: [Float]) async {
        let seconds = Double(audio.count) / AudioCapture.rate
        guard seconds >= 0.3 else {
            phase = .idle
            log.log("too short: audio=\(seconds, format: .fixed(precision: 2), privacy: .public)s")
            pill.flash("Didn't catch that")
            return
        }
        // Digital silence (every sample exactly 0) is a mic that gives no sound at all: AirPods in their case, a muted
        // or disconnected input. Say which one instead of "Didn't catch that".
        if audio.allSatisfy({ $0 == 0 }) {
            phase = .idle
            let mic = AudioDevices.name(AudioDevices.defaultInput())
            log.log("silent input: audio=\(seconds, format: .fixed(precision: 1), privacy: .public)s mic=\(mic, privacy: .public)")
            pill.flash("No sound from \(mic). Pick another mic in System Settings › Sound", seconds: 4.5)
            return
        }
        phase = .working
        pill.show(.working)
        let start = Date()
        do {
            let raw = try await MacTranscriber.shared.transcribe(audio, words: dictionary.words)
            let heard = DictationText.finish(raw)
            let written = await MacWriter.write(heard, style: style)
            phase = .idle
            failedAudio = nil
            lastReadout = written.readout
            log.log("done audio=\(seconds, format: .fixed(precision: 1), privacy: .public)s total=\(Date().timeIntervalSince(start), format: .fixed(precision: 2), privacy: .public)s writer=\(written.readout.runtime, privacy: .public) words=\(written.readout.wordsOut, privacy: .public) line=\(written.readout.short, privacy: .public)")
            guard !written.text.isEmpty else { pill.flash("Didn't catch that"); return }
            lastText = written.text
            let inserted = await TextInserter.insert(written.text)
            log.log("inserted: \(inserted == .pasted ? "pasted" : "copied", privacy: .public)")
            switch inserted {
            case .pasted: pill.hide()
            case .copied: pill.flash("Copied. Press ⌘V to paste", seconds: 3.5)
            }
        } catch {
            phase = .idle
            failedAudio = audio
            log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            pill.flash("Something went wrong. Retry from the menu", seconds: 3.5)
        }
    }

    func retryFailed() {
        guard phase == .idle, let audio = failedAudio else { return }
        Task { await process(audio) }
    }

    func pasteLast() {
        guard !lastText.isEmpty else { return }
        let text = lastText
        // The menu closes first so the paste lands in the app that was in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Task { _ = await TextInserter.insert(text) } }
    }

    func copyLast() {
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }
}

/// System settings that matter to fn.
enum FnKeySetting {
    /// What macOS does on its own when fn (the Globe key) is pressed: System Settings > Keyboard > "Press fn key to".
    /// 0 = Do Nothing. nil = never changed (the macOS default, which is not Do Nothing).
    static var usage: Int? {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
    }

    static var conflicts: Bool { usage != 0 }

    /// One line for the setup window when fn also does something of its own, else nil.
    static var note: String? {
        switch usage {
        case 0: return nil
        case 1: return "fn also changes the input source on this Mac. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        case 2: return "fn also opens Emoji & Symbols on this Mac. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        case 3: return "fn also starts Apple's dictation on this Mac. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        default: return "Pressing fn on its own can also open emoji or change the input source. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        }
    }
}
