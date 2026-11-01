import AVFAudio
import FreeFlowKit
import SwiftUI
import UIKit

/// The ways to start dictation. The user picks; setup then covers only those.
enum DictationMethod: String, CaseIterable, Identifiable {
    case keyboard, actionButton, controlCenter   // build 32: no Back Tap (it needs a Shortcuts-app action)
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: "The Free Flow keyboard"
        case .actionButton: "Action Button"
        case .controlCenter: "Control Center"
        }
    }

    var detail: String {
        switch self {
        case .keyboard: "A mic key in every app, and a two-finger swipe: up starts, down finishes. The text goes straight into the box you're typing in."
        case .actionButton: "Press the Action Button to start and again to stop. With the Free Flow keyboard up, the text goes in at your cursor; otherwise it's copied, ready to paste."
        case .controlCenter: "A Free Flow button in Control Center or on the Lock Screen. Tap to start and again to stop. With the Free Flow keyboard up, the text goes in at your cursor; otherwise it's copied, ready to paste."
        }
    }

    var icon: String {
        switch self {
        case .keyboard: "keyboard"
        case .actionButton: "button.vertical.right.press"
        case .controlCenter: "switch.2"
        }
    }

    /// iPad has no Action Button.
    static var available: [DictationMethod] {
        UIDevice.current.userInterfaceIdiom == .phone ? allCases : [.keyboard, .controlCenter]
    }
}

/// The real state of every setup step, read from iOS and from what the keyboard and shortcuts wrote.
@MainActor
final class SetupState: ObservableObject {
    @Published var mic: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    /// What setup knows about a keyboard switch. iOS gives an app no way to read whether its keyboard is added or has
    /// Full Access, and reading the system's keyboard list is not allowed (B10, App Store privacy), so the keyboard
    /// itself reports each time it opens. `check` = it reported before Free Flow last started: iOS restarts Free Flow
    /// whenever Full Access changes, so that answer may be old, and setup asks for one opening instead of guessing.
    enum Check: String { case done, notYet = "not yet", check }
    @Published var keyboardAdded = Check.notYet
    @Published var fullAccess = Check.notYet
    @Published var lastTrigger: Date?
    /// When this run of Free Flow started (set from FreeFlowApp.init).
    static var launched = Date()
    /// When a keyboard without Full Access opened during this run.
    private var noAccessAt: Date?

    init() {
        #if DEBUG
        // UI tests only (compiled out of TestFlight builds): start as a device where the keyboard has never opened,
        // so the Full Access check is really exercised.
        if ProcessInfo.processInfo.arguments.contains("-ffFreshKeyboard") {
            SharedSession.keyboardSeen = nil
            SharedSession.keyboardFullAccess = false
            KeyboardProof.clear()
        }
        #endif
        DarwinBus.shared.observe(.keyboardSeen) { [weak self] in Task { @MainActor in self?.refresh() } }
        DarwinBus.shared.observe(.keyboardNoAccess) { [weak self] in
            Task { @MainActor in
                // The keyboard is added and has no Full Access now: an older proof is wrong.
                self?.noAccessAt = Date()
                KeyboardProof.clear()
                SharedSession.keyboardFullAccess = false
                self?.refresh()
            }
        }
    }

    static var keyboardID: String { (Bundle.main.bundleIdentifier ?? FF.subsystem) + ".keyboard" }

    func refresh() {
        mic = AVAudioApplication.shared.recordPermission
        // The keyboard writes a proof each time it appears, with what iOS told it about Full Access (the flag). A
        // keyboard opened at all proves "added"; only flag true proves Full Access. Without Full Access a device keyboard
        // cannot write here at all and tells the app with a Darwin notice instead (keyboardNoAccess).
        // Only the keyboard's own reports count: no system preference is read (App Store privacy, B10). The proof file
        // is read fresh each time; a report from before this run started may be old (see Check).
        let proof = KeyboardProof.read()
        let fresh = proof.map { $0.seen >= Self.launched } ?? false
        if let none = noAccessAt, proof.map({ !$0.flag || $0.seen < none }) ?? true {
            keyboardAdded = .done
            fullAccess = .notYet
        } else if let proof, fresh, proof.flag {
            keyboardAdded = .done
            fullAccess = .done
        } else if fresh {
            // The keyboard opened in this run and iOS said Full Access was off at that moment; it says so again within
            // 2 s, or the next check finds it on.
            keyboardAdded = .done
            fullAccess = .check
        } else if proof != nil || SharedSession.keyboardSeen != nil {
            keyboardAdded = .check
            fullAccess = .check
        } else {
            keyboardAdded = .notYet
            fullAccess = .notYet
        }
        lastTrigger = SharedSession.lastTrigger
    }
}

struct OnboardingView: View {
    /// accessibility: the Mac's step (fn in every app and paste at the cursor need it), in place of the keyboard's.
    enum Step: Hashable { case welcome, methods, localAI, writer, mic, keyboard, accessibility, trigger(DictationMethod), tryIt }

    @EnvironmentObject private var models: ModelManager
    @StateObject private var setup = SetupState()
    #if targetEnvironment(macCatalyst)
    @ObservedObject private var mac = MacHost.shared
    #endif
    @AppStorage("setup.methods") private var methodsRaw = DictationMethod.keyboard.rawValue
    /// Saved on every step. iOS restarts the app when Allow Full Access changes, and setup must come back on the
    /// step the person was on, never from the start.
    @State private var index = UserDefaults.standard.integer(forKey: OnboardingView.stepKey)
    @State private var keyboardTry = ""
    @FocusState private var keyboardFocused: Bool
    static let stepKey = "setup.step"
    @State private var stepOpened = Date()
    @State private var tryText = ""
    @State private var swipe = SharedSession.keyboardGestures
    @FocusState private var tryFocused: Bool
    let done: () -> Void

    private var chosen: [DictationMethod] {
        let raw = Set(methodsRaw.split(separator: ",").map(String.init))
        return DictationMethod.available.filter { raw.contains($0.rawValue) }
    }

    private var steps: [Step] {
        #if targetEnvironment(macCatalyst)
        // The Mac has one way to start (fn) and no keyboard to add.
        return [.welcome, .localAI, .writer, .mic, .accessibility, .tryIt]
        #endif
        var list: [Step] = [.welcome, .methods, .localAI, .writer, .mic]
        if chosen.contains(.keyboard) { list.append(.keyboard) }
        for method in chosen where method != .keyboard { list.append(.trigger(method)) }
        list.append(.tryIt)
        return list
    }

    private var deviceWord: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    var body: some View {
        let all = steps
        let step = all[min(index, all.count - 1)]
        let last = index >= all.count - 1
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if index > 0 { Text("Step \(index) of \(all.count - 1)").ffEyebrow() }
                    content(step)
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .id(step)
            HStack(spacing: 12) {
                if index > 0 {
                    Button("Back") { go(-1) }.buttonStyle(FFButtonStyle(.secondary)).accessibilityIdentifier("onboarding.back")
                } else {
                    Button("Skip") { finish() }.buttonStyle(FFButtonStyle(.secondary)).accessibilityIdentifier("onboarding.skip")
                }
                Spacer()
                // Build 19: no going past the model page without a speech model that downloaded and checked out.
                if step == .localAI && !models.activeReady {
                    Text("Download a model to continue").font(FFFont.text(14, .semibold)).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.trailing).accessibilityIdentifier("onboarding.needsModel")
                }
                Button(last ? "Start using Free Flow" : "Next") {
                    if last { finish() } else { go(1) }
                }
                .buttonStyle(FFButtonStyle(.primary))
                .disabled(step == .localAI && !models.activeReady)
                .accessibilityIdentifier(last ? "onboarding.done" : "onboarding.next")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // Scrolled text stops at the status bar instead of sliding under it.
        .overlay(alignment: .top) { Palette.bg.frame(height: 0).ignoresSafeArea(edges: .top) }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.fg)
        .onAppear { setup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in setup.refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            setup.refresh()
            #if targetEnvironment(macCatalyst)
            MacHost.shared.refresh()
            #endif
        }
        .onChange(of: swipe) { _, value in SharedSession.keyboardGestures = value }
    }

    private func go(_ delta: Int) {
        tryFocused = false
        keyboardFocused = false
        withAnimation(.easeOut(duration: 0.16)) {
            index = max(0, min(steps.count - 1, index + delta))
        }
        UserDefaults.standard.set(index, forKey: Self.stepKey)
        stepOpened = Date()
        setup.refresh()
    }

    /// Setup is over: a later "Show setup again" starts from the first page.
    private func finish() {
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        done()
    }

    private func toggle(_ method: DictationMethod) {
        var set = Set(chosen.map(\.rawValue))
        if set.contains(method.rawValue) {
            guard set.count > 1 else { return }  // keep at least one way to dictate
            set.remove(method.rawValue)
        } else {
            set.insert(method.rawValue)
        }
        methodsRaw = DictationMethod.allCases.map(\.rawValue).filter(set.contains).joined(separator: ",")
    }

    private func openSettings() {
        #if targetEnvironment(macCatalyst)
        MacHost.shared.openSettings("microphone")
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    @ViewBuilder
    private func content(_ step: Step) -> some View {
        switch step {
        case .welcome: welcome
        case .methods: methodsPage
        case .localAI: localAIPage
        case .writer: WriterOfferPage(deviceWord: deviceWord) { go(1) }
        case .mic: micPage
        case .keyboard: keyboardPage
        case .accessibility:
            #if targetEnvironment(macCatalyst)
            accessibilityPage
            #else
            EmptyView()
            #endif
        case .trigger(let method): triggerPage(method)
        case .tryIt: tryPage
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            BrandMark(withSound: true, animating: true).frame(width: 120, height: 120).frame(maxWidth: .infinity)
            Text("FREE FLOW").font(FFFont.display(56)).frame(maxWidth: .infinity)
            Text("Talk, and it types. In any app, on your \(deviceWord), for free.")
                .font(FFFont.text(22, .semibold)).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            fact("lock", "Your voice never leaves this \(deviceWord). No account.")
            fact("cpu", "An open speech model runs right here, picked for this \(deviceWord).")
            fact("play.rectangle", "Dictate while a video plays. It keeps playing.")
            Text("Setup takes about two minutes. We'll walk you through each switch and check it worked.")
                .font(FFFont.text(16)).foregroundStyle(Palette.muted)
        }
    }

    private var methodsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HOW DO YOU WANT TO DICTATE?").font(FFFont.display(40))
            Text("Free Flow offers \(DictationMethod.available.count) ways to start. Pick the ones you want and we'll set up only those. You can change this later.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            ForEach(DictationMethod.available) { method in
                let on = chosen.contains(method)
                Button { toggle(method) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: method.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.brand).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(method.title).font(FFFont.text(18, .semibold))
                            Text(method.detail).font(FFFont.text(15)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24)).foregroundStyle(on ? Palette.brand : Palette.faint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ffCard()
                    .ffStroke(Radius.card, on ? Palette.brand : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("method.\(method.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var localAIPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On-device AI").ffEyebrow()
            Text("THE AI RUNS ON YOUR \(deviceWord.uppercased())").font(FFFont.display(40))
            Text("Free Flow turns your voice into text with an open speech model running on this \(deviceWord)'s Neural Engine. You download it once. After that it works with no connection, and your voice never leaves the \(deviceWord).")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                stat(String(format: "%.0f GB", models.device.memoryGB), "memory here")
                stat(models.active.downloadBytes.megabytes, "one download")
                stat("None", "audio sent")
            }
            ModelPicker(context: .setup)
            Text("Who made it").ffEyebrow()
            VStack(alignment: .leading, spacing: 12) {
                creditRow("logo-moondream", "Moondream", "Parakeet Ultra and Parakeet Redux, CC-BY-4.0")
                creditRow("logo-fermion", "Fermion Research", "Phonon-2, CC-BY-4.0")
                creditRow("logo-conway", "Conway Research", "Underdog Bark 3.0 Clean and Bark 3.0 Pro, CC-BY-4.0")
                creditRow("logo-nvidia", "NVIDIA", "Parakeet TDT 0.6B v3, the model they all start from and the C++ backup, CC-BY-4.0")
                creditRow("logo-huggingface", "Hugging Face", "Hosts the model files. Each file you download is checked against a sha256 pinned in this build.")
            }
            .ffCard()
            LogoNotice()
        }
    }

    private var micPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MICROPHONE").font(FFFont.display(40))
            StatusChip(done: setup.mic == .granted, doneText: "Allowed",
                       todoText: setup.mic == .denied ? "Turned off" : "Not asked yet")
                .accessibilityIdentifier("check.mic")
                .accessibilityValue(setup.mic == .granted ? "done" : (setup.mic == .denied ? "turned off" : "not yet"))
            Text(Self.micWhy).font(FFFont.text(17)).foregroundStyle(Palette.muted)
            if setup.mic == .undetermined {
                Button("Allow the microphone") {
                    Task { _ = await AVAudioApplication.requestRecordPermission(); setup.refresh() }
                }
                .buttonStyle(FFButtonStyle(.ember)).accessibilityIdentifier("allowMic")
            } else if setup.mic == .denied {
                Text("It was turned off. Turn it back on here:").font(FFFont.text(17, .semibold))
                #if targetEnvironment(macCatalyst)
                PathPill("System Settings › Privacy & Security › Microphone")
                Button("Open Microphone settings") { openSettings() }.buttonStyle(FFButtonStyle(.ember))
                #else
                PathPill("Settings › Apps › Free Flow › Microphone")
                SettingsPicture(title: "Free Flow", back: "Apps",
                                rows: [.link("Siri", nil), .toggle("Microphone", false), .link("Keyboards", nil)], point: 1)
                Button("Open Free Flow in Settings") { openSettings() }.buttonStyle(FFButtonStyle(.ember))
                #endif
                Text("Come back here when it's on. This page checks again by itself.").font(FFFont.text(15)).foregroundStyle(Palette.faint)
            } else {
                Text(Self.micAllSet).font(FFFont.text(16)).foregroundStyle(Palette.muted)
            }
        }
    }

    private var keyboardPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ADD THE KEYBOARD").font(FFFont.display(40))
            Text("iOS doesn't let keyboards use the microphone, so the keyboard asks the Free Flow app to listen and gets the text back through a folder on this \(deviceWord) that only Free Flow can open. That's what Allow Full Access is for. The keyboard has no network code and keeps no record of what you type.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            checkRow(1, "Add Free Flow as a keyboard", state: setup.keyboardAdded, id: "check.keyboardAdded")
            checkRow(2, "Turn on Allow Full Access", state: setup.fullAccess, id: "check.fullAccess",
                     note: setup.keyboardAdded == .done && setup.fullAccess == .notYet
                        ? "The keyboard is added, and Allow Full Access is off. Turn it on in Settings › Apps › Free Flow › Keyboards." : nil)
            if setup.keyboardAdded != .done || setup.fullAccess != .done {
                Text("Free Flow checks both when its keyboard opens. Open it once in the box below.")
                    .font(FFFont.text(15)).foregroundStyle(Palette.muted)
            }
            Text("Where").ffEyebrow()
            PathPill("Settings › Apps › Free Flow › Keyboards")
            SettingsPicture(title: "Free Flow", back: "Apps",
                            rows: [.link("Siri", nil), .toggle("Microphone", setup.mic == .granted), .link("Keyboards", nil)], point: 2)
            SettingsPicture(title: "Keyboards", back: "Free Flow",
                            rows: [.toggle("Free Flow", true), .toggle("Allow Full Access", true)], point: setup.keyboardAdded == .done ? 1 : 0)
            Text("Turn on both switches, then tap Allow when iOS asks about Full Access.").font(FFFont.text(16)).foregroundStyle(Palette.muted)
            Button("Open Free Flow in Settings") { openSettings() }
                .buttonStyle(FFButtonStyle(.ember)).accessibilityIdentifier("openSettings.keyboard")
            Text("Come back here when you're done. This page checks again by itself.").font(FFFont.text(15)).foregroundStyle(Palette.faint)
            Text("Then open the keyboard once").ffEyebrow()
            Text("iOS restarts Free Flow when Full Access changes, and setup comes back on this step. Tap the box, then tap the globe key until the Free Flow keyboard shows. Full Access shows Done as soon as it opens.")
                .font(FFFont.text(16)).foregroundStyle(Palette.muted)
            TextField("Tap here, then switch to the Free Flow keyboard", text: $keyboardTry, axis: .vertical)
                .focused($keyboardFocused)
                .font(FFFont.text(17))
                .lineLimit(2...4)
                .ffCard()
                .accessibilityIdentifier("setup.keyboardTry")
            Toggle(isOn: $swipe) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Two-finger swipe").font(FFFont.text(17, .semibold))
                    Text("On the Free Flow keyboard: swipe up to start, down to finish.").font(FFFont.text(14)).foregroundStyle(Palette.muted)
                }
            }
            .tint(Palette.brand)
            .ffCard()
        }
    }

    private func triggerPage(_ method: DictationMethod) -> some View {
        let ran = (setup.lastTrigger ?? .distantPast) > stepOpened
        return VStack(alignment: .leading, spacing: 16) {
            Text(method.title.uppercased()).font(FFFont.display(40))
            Text(method.detail).font(FFFont.text(17)).foregroundStyle(Palette.muted)
            Text("Where").ffEyebrow()
            switch method {
            case .actionButton:
                PathPill("Settings › Action Button › Controls › Choose a Control › Free Flow › Start/Stop Free Flow")
                SettingsPicture(title: "Action Button", back: "Settings",
                                rows: [.plain("Controls"), .link("Choose a Control…", "Start/Stop Free Flow")], point: 1)
                Text("Swipe sideways on the Action Button screen until it says Controls.").font(FFFont.text(15)).foregroundStyle(Palette.faint)
            default:
                PathPill("Control Center › + (top left) › Add a Control › search Free Flow › Start/Stop Free Flow")
                SettingsPicture(title: "Add a Control", back: nil,
                                rows: [.plain("Search: Free Flow"), .link("Start/Stop Free Flow", "Free Flow")], point: 1)
                Text("Open Control Center by swiping down from the top-right corner.").font(FFFont.text(15)).foregroundStyle(Palette.faint)
            }
            Text("Test it").ffEyebrow()
            StatusChip(done: ran, doneText: "It worked: Free Flow heard the press", todoText: "Press it now")
            Text("The first press opens Free Flow and starts listening; press again to stop. After that, presses work from any app while the session stays on.")
                .font(FFFont.text(15)).foregroundStyle(Palette.muted)
        }
    }

    private var tryPage: some View {
        let typed = !tryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 16) {
            Text("TRY IT").font(FFFont.display(40))
            #if targetEnvironment(macCatalyst)
            Text("Click the box. Hold fn, say a sentence, then let go. Your words go in where your cursor is.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            #else
            if chosen.contains(.keyboard) {
                Text("Tap the box. Hold the globe key (bottom left) and pick Free Flow. Tap the mic, say a sentence, then tap Done.")
                    .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            } else {
                Text("Start with your \(chosen.first?.title ?? "shortcut"), say a sentence, stop it, then paste here.")
                    .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            }
            #endif
            TextField("Your words appear here", text: $tryText, axis: .vertical)
                .focused($tryFocused)
                .font(FFFont.text(18))
                .lineLimit(3...6)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .ffStroke(Radius.row, tryFocused ? Palette.brand : Palette.lineStrong)
                .accessibilityIdentifier("tryField")
            #if targetEnvironment(macCatalyst)
            StatusChip(done: mac.accessibility, doneText: "fn is on, in every app", todoText: "Accessibility is off, so fn can't work yet")
            #else
            if chosen.contains(.keyboard) {
                StatusChip(done: setup.fullAccess == .done, doneText: "Keyboard connected, Full Access on",
                           todoText: setup.fullAccess == .notYet && setup.keyboardAdded == .done ? "Allow Full Access is off" : "Keyboard not seen yet")
            }
            #endif
            StatusChip(done: typed, doneText: "Text arrived", todoText: "Waiting for your words")
            Text("You can come back to this setup any time from Settings.").font(FFFont.text(15)).foregroundStyle(Palette.faint)
        }
    }

    #if targetEnvironment(macCatalyst)
    static let micWhy = "Free Flow needs the mic to hear you. It listens only while you dictate, and macOS shows the orange dot in the menu bar whenever it does."
    static let micAllSet = "All set. You can turn it off any time in System Settings › Privacy & Security › Microphone."

    /// The Mac's step: Accessibility lets Free Flow see fn in every app and paste at the cursor.
    private var accessibilityPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HOLD FN TO DICTATE").font(FFFont.display(40))
            StatusChip(done: mac.accessibility, doneText: "Accessibility on", todoText: "Accessibility off")
                .accessibilityIdentifier("check.accessibility")
                .accessibilityValue(mac.accessibility ? "done" : "not yet")
            Text("In any app, hold fn and talk, then let go: your words go in where your cursor is. Press fn twice for hands-free, then fn again to stop. Esc cancels.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            Text("macOS lets Free Flow see the fn key and paste for you only with Accessibility on. Free Flow reads no other keys and keeps no record of what you type.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            if !mac.accessibility {
                PathPill("System Settings › Privacy & Security › Accessibility")
                Button("Turn on Accessibility") { MacHost.shared.askAccessibility() }
                    .buttonStyle(FFButtonStyle(.ember)).accessibilityIdentifier("allowAccessibility")
                Button("Open Accessibility settings") { MacHost.shared.openSettings("accessibility") }
                    .buttonStyle(FFButtonStyle(.secondary))
                Text("Turn on Free Flow in the list, then come back. This page checks again by itself.")
                    .font(FFFont.text(15)).foregroundStyle(Palette.faint)
            }
            if let note = FnKeySetting.note {
                Text(note).font(FFFont.text(15, .semibold)).foregroundStyle(Palette.warn)
                Button("Open Keyboard settings") { MacHost.shared.openSettings("keyboard") }.buttonStyle(FFButtonStyle(.secondary))
            }
        }
    }
    #else
    static let micWhy = "Free Flow needs the mic to hear you. It listens only while you dictate or while a session is on, and iOS shows the orange dot whenever it does."
    static let micAllSet = "All set. You can turn it off any time in Settings › Apps › Free Flow."
    #endif

    // MARK: Parts

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.brand).frame(width: 28)
            Text(text).font(FFFont.text(18))
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(FFFont.mono(17, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(FFFont.text(13)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }

    private func creditRow(_ logo: String, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MakerLogo(asset: logo, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(FFFont.text(17, .semibold))
                Text(text).font(FFFont.text(14)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func checkRow(_ n: Int, _ title: String, state: SetupState.Check, id: String, note: String? = nil) -> some View {
        let done = state == .done
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(done ? Palette.ok : Palette.brand)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(FFFont.text(18, .semibold))
                Text(done ? "Done" : (state == .check ? "Open the keyboard below to check" : "Not yet"))
                    .font(FFFont.text(14, .semibold)).foregroundStyle(done ? Palette.ok : Palette.warn)
                if let note { Text(note).font(FFFont.text(14)).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
        .accessibilityValue(state.rawValue)
    }
}

/// Done / not yet, as a filled pill.
struct StatusChip: View {
    let done: Bool
    let doneText: String
    let todoText: String
    var body: some View {
        Label(done ? doneText : todoText, systemImage: done ? "checkmark.circle.fill" : "circle.dashed")
            .font(FFFont.text(14, .semibold))
            .foregroundStyle(done ? Palette.ok : Palette.warn)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.panel, in: Capsule(style: .continuous))
    }
}

/// The exact path, in a mono pill.
struct PathPill: View {
    let path: String
    init(_ path: String) { self.path = path }
    var body: some View {
        Text(path)
            .font(FFFont.mono(14))
            .foregroundStyle(Palette.fg)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .textSelection(.enabled)
    }
}

/// A drawn copy of the Settings screen (Apple's own grouped style and switches), with a pointer at the row to tap.
struct SettingsPicture: View {
    enum Row { case link(String, String?), toggle(String, Bool), plain(String) }
    let title: String
    let back: String?
    let rows: [Row]
    let point: Int
    @State private var nudge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let back {
                Label(back, systemImage: "chevron.left").font(.system(size: 16)).foregroundStyle(Color(uiColor: .systemBlue))
            }
            Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(Color(uiColor: .label))
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { i in
                    ZStack(alignment: .trailing) {
                        rowView(rows[i])
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .ffStroke(14, i == point ? Palette.brand : Color.clear)
                        if i == point {
                            Image(systemName: "hand.point.left.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Palette.brand)
                                .offset(x: nudge ? 10 : 22)
                                .padding(.trailing, -6)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(uiColor: .systemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.frame, style: .continuous))
        .ffStroke(Radius.frame, Palette.line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Picture of the \(title) screen in Settings, pointing at \(label(rows[min(point, rows.count - 1)]))")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { nudge = true }
        }
    }

    private func label(_ row: Row) -> String {
        switch row {
        case .link(let t, _), .toggle(let t, _), .plain(let t): t
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack {
            switch row {
            case .link(let text, let value):
                Text(text).foregroundStyle(Color(uiColor: .label))
                Spacer()
                if let value { Text(value).foregroundStyle(Color(uiColor: .secondaryLabel)).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(uiColor: .tertiaryLabel))
            case .toggle(let text, let on):
                Text(text).foregroundStyle(Color(uiColor: .label))
                Spacer()
                Toggle("", isOn: .constant(on)).labelsHidden().tint(Color(uiColor: .systemGreen)).allowsHitTesting(false)
            case .plain(let text):
                Text(text).foregroundStyle(Color(uiColor: .label))
                Spacer()
            }
        }
        .font(.system(size: 17))
        .padding(.trailing, 26)
    }
}

/// A model maker's logo from the pinned LobeHub Icons set (scripts/fetch-logos.py). In-app only.
struct MakerLogo: View {
    let asset: String
    var size: CGFloat = 28
    var body: some View {
        Image(asset).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
    static func asset(forMaker maker: String) -> String? {
        switch maker {
        case "NVIDIA": "logo-nvidia"
        case "Moondream": "logo-moondream"
        case "Fermion Research": "logo-fermion"
        case "Conway Research": "logo-conway"
        default: nil
        }
    }
}

/// Trademark and source line shown under logos.
struct LogoNotice: View {
    var body: some View {
        Text("NVIDIA, Moondream, Fermion Research, Conway Research, Hugging Face and GitHub names and logos are trademarks of their owners. They appear here only to say who made each model and where it comes from, and do not mean those companies endorse Free Flow. Logo images: LobeHub Icons 1.97.1 (MIT); Moondream, Fermion Research and Conway Research: their Hugging Face profile pictures.")
            .font(FFFont.text(12.5))
            .foregroundStyle(Palette.faint)
    }
}

/// Setup's writer step (build 18: LFM3 is dropped, Apple Intelligence is the writer and it is optional): one
/// switch, off by default since build 33, and where Apple Intelligence can't run here, the reason.
struct WriterOfferPage: View {
    let deviceWord: String
    let next: () -> Void
    @AppStorage(WriterChoice.key) private var writerChoice = ""
    @ObservedObject private var apple = AppleStatus.shared

    var body: some View {
        let on = WriterChoice.resolved(raw: writerChoice) == .apple
        VStack(alignment: .leading, spacing: 16) {
            Text("Writer").ffEyebrow()
            Text("CLEAN UP WITH APPLE INTELLIGENCE").font(FFFont.display(40))
            Text("Free Flow can have Apple Intelligence, Apple's on-device model, write each dictation in the style you pick: punctuation, false starts, lists. It runs on this \(deviceWord); nothing leaves it. Off, your words go in exactly as the speech model heard them, with your dictionary words.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            Toggle(isOn: Binding(get: { on }, set: { writerChoice = $0 ? WriterChoice.apple.rawValue : WriterChoice.off.rawValue })) {
                Text("Clean up with Apple Intelligence").font(FFFont.text(17, .bold)).foregroundStyle(Palette.fg)
            }
            .tint(Palette.brand).accessibilityIdentifier("writerOfferSwitch")
            Text(WriterChoice.status(choice: on ? .apple : .off, appleAvailable: apple.available, reason: apple.reason).state)
                .font(FFFont.text(15)).foregroundStyle(on && !apple.available ? Palette.warn : Palette.muted)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("writerOfferState")
            Text("You can change this any time in Settings › Writing.").font(FFFont.text(15)).foregroundStyle(Palette.muted)
        }
        .task { WritingModel.refreshApple() }
    }
}

