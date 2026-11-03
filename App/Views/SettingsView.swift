import Combine
import FreeFlowKit
import StoreKit
import SwiftUI
#if !targetEnvironment(macCatalyst)
import AVFAudio
#endif

struct SettingsView: View {
    @AppStorage("sessionMinutes") private var sessionMinutes = 15
    @AppStorage(SpeechLanguage.key) private var speechLanguage = SpeechLanguage.automatic   // 2026-11-03: Automatic by default
    @ObservedObject private var models = ModelManager.shared
    /// The device's language as the app's models know it (English when none does).
    static func deviceLanguageName() -> String {
        let code = SpeechLanguage.deviceDefault(preferred: Locale.preferredLanguages, supported: ModelManager.routableLanguages)
        return code.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "English"
    }
    /// Every language a dictation can be pinned to, by name.
    static func languageChoices() -> [(code: String, name: String)] {
        ModelManager.routableLanguages.map { (code: $0, name: Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
            .sorted { $0.name < $1.name }
    }
    @AppStorage("mixWithOthers") private var mixWithOthers = true
    @AppStorage("duckOthers") private var duckOthers = false
    @AppStorage("keepHistory") private var keepHistory = true
    @AppStorage(ClipRetention.key) private var retentionDays = ClipRetention.standard.rawValue
    @AppStorage("onboarded") private var onboarded = true
    @State private var style = SharedSession.style
    @State private var gestures = SharedSession.keyboardGestures
    @AppStorage("appearance") private var appearance = "dark"
    @State private var haptics = SharedSession.keyHaptics
    @State private var clickCheck = SettingsView.clickCheckText()
    @State private var confirmResetStats = false
    @State private var keyLayout = KeyLayoutKind.current
    @State private var layoutOpen: KeyLayoutKind?
    @State private var keyHand = KeyHand.current
    @State private var autocorrect = SharedSession.keyboardAutocorrect
    @AppStorage(WriterChoice.key) private var writerChoice = ""
    @ObservedObject private var apple = AppleStatus.shared

    var body: some View {
        Form {
            // Build 18: Apple Intelligence is the writer and it is optional. One switch, first in
            // Settings, with its state; where it can't run, the reason. "Where it runs" shows what runs where.
            Section("Writing") {
                let on = WriterChoice.resolved(raw: writerChoice) == .apple
                Toggle(isOn: Binding(get: { on }, set: { writerChoice = $0 ? WriterChoice.apple.rawValue : WriterChoice.off.rawValue })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Clean up with Apple Intelligence")
                        Text(WriterChoice.status(choice: on ? .apple : .off, appleAvailable: apple.available, reason: apple.reason).state)
                            .font(FFFont.text(14)).foregroundStyle(on && !apple.available ? Palette.warn : Palette.muted)
                            .accessibilityIdentifier("settings.writerState")
                    }
                }
                .tint(Palette.brand)
                .accessibilityIdentifier("settings.appleWriter")
                NavigationLink("Where it runs") { WhereItRunsPage() }
                    .accessibilityIdentifier("settings.whereItRuns")
                Picker("Default style", selection: $style) {
                    ForEach(DictationStyle.allCases) { Text($0.pill).tag($0) }
                }
                .onChange(of: style) { _, s in SharedSession.style = s }
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            footer("The speech model writes down what it hears, with your dictionary words. With the switch on, Apple Intelligence then writes it in your style. Both run on this device; nothing leaves it.")
            Section("Speech model") {
                NavigationLink("Models") { ModelsView() }
                    .accessibilityIdentifier("settings.models")
                // Build 23: the language is pinned; Automatic is opt-in. Build 26: the list is
                // the model in use's own languages (Whisper's 99 when it is Whisper), Automatic is offered only on a
                // model with more than one language, and an English-only model shows no picker.
                // 2026-11-02: the language picks the engine. The list is Parakeet's 25 plus Whisper's full set
                // when a Whisper model is in the catalog; English and Parakeet's languages dictate on Parakeet, every
                // other language on Whisper, and Automatic (opt-in, guessed once per dictation) is Whisper only.
                let hasWhisper = ModelManager.whisperModel != nil
                let choices = Self.languageChoices()
                Picker("Language", selection: $speechLanguage) {
                    if hasWhisper {
                        Text("Automatic (detects the language you speak)").tag(SpeechLanguage.automatic)
                    }
                    Text("\(Self.deviceLanguageName()) (this \(DeviceWord.current)'s language)").tag("")
                    ForEach(choices, id: \.code) { l in Text(l.name).tag(l.code) }
                }
                .accessibilityIdentifier("settings.language")
                .onChange(of: speechLanguage) { _, _ in models.reroute() }
                let routed = models.routedID()
                if let model = ModelCatalog.model(routed) {
                    let languageName = ModelManager.routedLanguage().flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Automatic"
                    if models.routedMissing == routed {
                        Button("Download \(model.name) (\(model.downloadBytes.megabytes)) to dictate in \(languageName)") { models.use(routed) }
                            .accessibilityIdentifier("settings.routedDownload")
                    } else {
                        Text("\(languageName) runs on \(model.name)")
                            .font(FFFont.text(14)).foregroundStyle(Palette.muted)
                            .accessibilityIdentifier("settings.routedModel")
                    }
                }

            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            #if !targetEnvironment(macCatalyst)   // the Mac has no Free Flow keyboard
            Section("Keyboard") {
                KeyLayoutRow(selected: $keyLayout, open: $layoutOpen)
                NavigationLink("All layouts") { KeyLayoutPage(selected: $keyLayout) }
                    .accessibilityIdentifier("settings.keyLayout")
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            #endif
            Section("Look") {
                Picker("Appearance", selection: $appearance) {
                    Text("Dark").tag("dark"); Text("Light").tag("light"); Text("Match system").tag("system")
                }
                .onChange(of: appearance) { _, v in FF.defaults.set(v, forKey: "appearance") }
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            #if targetEnvironment(macCatalyst)
            MacFnSection()
            #else
            Section("Session") {
                Picker("Keep the mic ready for", selection: $sessionMinutes) {
                    Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("1 hour").tag(60)
                }
                MicPicker()
                Toggle("Keep videos and music playing", isOn: $mixWithOthers)
                Toggle("Lower other audio while I talk", isOn: $duckOthers).disabled(!mixWithOthers)
                if let at = SharedSession.lastEndAt, !SharedSession.lastEnd.isEmpty {
                    Text("Last time the mic turned off: \(SharedSession.lastEnd), \(at.formatted(date: .abbreviated, time: .shortened)).")
                        .font(FFFont.text(13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("session.lastEnd")
                }
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            footer("Applies the next time a session starts. With playback kept on, Free Flow records alongside your video instead of pausing it.")
            Section("Ways to start") {
                Label("Keyboard mic key", systemImage: "keyboard").badge("On")
                Toggle("Two-finger swipe on the keyboard", isOn: $gestures)
                    .onChange(of: gestures) { _, v in SharedSession.keyboardGestures = v }
                NavigationLink("Action Button and Control Center") { TriggersView() }
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            footer("Two-finger swipe up on the Free Flow keyboard starts listening; swipe down finishes and types the text.")
            Section("Keys") {
                LabeledContent("Dictate key") {
                    Picker("Dictate key side", selection: $keyHand) {
                        ForEach(KeyHand.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 170)
                    .accessibilityIdentifier("keyHandPicker")
                    .onChange(of: keyHand) { _, v in KeyHand.current = v }
                }
                Toggle("Autocorrect", isOn: $autocorrect)
                    .onChange(of: autocorrect) { _, v in SharedSession.keyboardAutocorrect = v }
                    .accessibilityIdentifier("set.autocorrect")
                Picker("Key haptics", selection: $haptics) {
                    ForEach(KeyTick.Level.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: haptics) { _, v in SharedSession.keyHaptics = v }
                .accessibilityIdentifier("set.keyHaptics")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key click check").font(FFFont.text(15, .semibold))
                    Text(clickCheck).font(FFFont.text(13)).foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("set.clickCheck")
                Button("Reset the click count") {
                    KeyClickCounts.stored = KeyClickCounts()
                    clickCheck = Self.clickCheckText()
                }
                .font(FFFont.text(14, .semibold))
                .accessibilityIdentifier("set.clickCheckReset")
            }
            .onAppear { clickCheck = Self.clickCheckText() }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            footer(Self.keyboardFooter)
            #endif
            Section("Privacy") {
                Toggle("Keep history on this device", isOn: $keepHistory)
                Picker("Delete unfinished recordings after", selection: $retentionDays) {
                    ForEach(ClipRetention.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("set.clipRetention")
                .onChange(of: retentionDays) { _, _ in
                    ClipStore.shared.purge(ClipRetention.current, active: DictationEngine.shared.recorder.activeID)
                }
                NavigationLink("Your stats") { StatsPage() }
                Button("Reset stats", role: .destructive) { confirmResetStats = true }
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("set.resetStats")
                    .confirmationDialog("Reset your stats to zero?", isPresented: $confirmResetStats, titleVisibility: .visible) {
                        Button("Reset stats", role: .destructive) { StatsStore.shared.reset() }
                            .accessibilityIdentifier("set.resetStats.confirm")
                    } message: {
                        Text("Words, streaks, speed and time saved start again from zero. Your history stays as it is.")
                    }
                NavigationLink("Privacy") { PrivacyView() }
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            footer("Stats keep counts and times only, never your words or audio. They are worked out on this device and never sent. A recording that didn't finish (a call, an X tap, Free Flow closing) stays on this device for Retry until you delete it or it reaches this age; Never keeps it until you delete it. Delete them all in Privacy.")
            TestBuildSection()
            Section("MASHBOX Labs") {
                NavigationLink("About and credits") { AboutView() }
                Button("Show setup again") { onboarded = false }
                // Build 18: TestFlight shows "1.1 (18)"; Settings says "Build 18" so the build is plain.
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
                    .accessibilityIdentifier("settings.build")
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
        }
        .navigationDestination(item: $layoutOpen) { kind in KeyLayoutDetail(kind: kind, selected: $keyLayout) }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .font(FFFont.text(17))
        .navigationTitle("Settings")
        .task { WritingModel.refreshApple() }
    }

    private func footer(_ text: String) -> some View {
        Section { EmptyView() } footer: { Text(text).font(FFFont.text(14)) }.listSectionSeparator(.hidden)
    }

    /// Settings > Keyboard footer.
    static let keyboardFooter = "One click per key, like the system keyboard. Haptics from a keyboard need Allow Full Access."
        + " Autocorrect fixes a misspelled word when you tap space, return or punctuation; tap delete right after to put your word back."
        + " Names in your contacts and your Dictionary words are left alone."

    /// Key click check, counted by the keyboard on this device (counts only).
    static func clickCheckText() -> String {
        var text = KeyClickCounts.stored.summary
        if let ok = KeyClickCounts.hapticsAllowedWhileMic {
            text += ok ? " Clicks are allowed while the mic is ready." : " iOS mutes clicks while the mic is ready."
        }
        return text + " Counted on this phone only."
    }
}

/// Settings > Keyboard > Layout: a visual picker, so people see what each layout looks like before choosing it.
/// Each layout is drawn by the keyboard's own code (FreeFlowKit KeyboardPreview: the same geometry
/// and key faces as the keyboard extension), scaled to the card. Tap to pick; the keyboard switches at once, and the
/// field at the top brings it up to try.
struct KeyLayoutPage: View {
    @Binding var selected: KeyLayoutKind
    @State private var tryText = ""
    @FocusState private var trying: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let screenW = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Tap here to try the Free Flow keyboard", text: $tryText, axis: .vertical)
                        .font(FFFont.text(17)).lineLimit(2...4).padding(12)
                        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.lineStrong, lineWidth: 1))
                        .focused($trying)
                        .accessibilityIdentifier("layoutTryField")
                    Text("Every layout keeps the same letters in the same places. Pick one, then type above to feel it.")
                        .font(FFFont.text(14)).foregroundStyle(Palette.muted)
                    ForEach(KeyLayoutKind.allCases, id: \.self) { kind in
                        card(kind, keyboardWidth: screenW, cardWidth: geo.size.width - 32)
                    }
                }
                .padding(16)
            }
        }
        .background(Palette.bg)
        .navigationTitle("Keyboard layout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card(_ kind: KeyLayoutKind, keyboardWidth: Double, cardWidth: Double) -> some View {
        let on = kind == selected
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let inner = cardWidth - 24
        let s = min(1, inner / max(keyboardWidth, 1))
        let h = KeyboardLayouts.height(width: keyboardWidth, isPad: isPad)
        return Button {
            selected = kind
            KeyLayoutKind.current = kind
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.title).font(FFFont.text(17, .bold)).foregroundStyle(Palette.fg)
                    Spacer()
                    if on {
                        Label("In use", systemImage: "checkmark.circle.fill").font(FFFont.text(14, .semibold))
                            .foregroundStyle(Palette.accentText)
                    }
                }
                Text(kind.detail).font(FFFont.text(14)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                // The keyboard's own state: its style, and its status dot (ready while Free Flow's mic session is on).
                KeyboardPreview(kind: kind, width: keyboardWidth, isPad: isPad, scale: Double(scale), hand: KeyHand.current,
                                globe: Self.keyboardShowsGlobe(isPad: isPad),
                                state: KeyFaceState(sessionLive: SharedSession.micState != .off, stylePill: SharedSession.style.pill))
                    .scaleEffect(s, anchor: .topLeading)
                    .frame(width: keyboardWidth * s, height: h * s, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(12)
            .frame(width: cardWidth, alignment: .leading)
            .background(on ? Palette.panel : Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
        .accessibilityValue(on ? "In use" : "")
        .accessibilityHint(kind.detail)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("layout.\(kind.rawValue)")
    }

    /// Whether the keyboard draws its own globe key on this device: what it last reported (iOS's
    /// needsInputModeSwitchKey, SharedSession.keyboardGlobe), else the device class: iPhones with a Home button have no
    /// globe under the keyboard, so the keyboard draws one; iPhones with Face ID show Apple's under it.
    static func keyboardShowsGlobe(isPad: Bool) -> Bool {
        if let reported = SharedSession.keyboardGlobe { return reported }
        if isPad { return true }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return (window?.safeAreaInsets.bottom ?? 0) == 0
    }
}

struct TriggersView: View {
    var body: some View {
        Page {
            Text("Start and stop without the keyboard").font(FFFont.display(30))
            Text("Press once to start listening and again to stop. With the Free Flow keyboard on screen, the text is typed at your cursor. Otherwise it is copied and a small notice says so; touch and hold where you want it, then tap Paste. A Live Activity shows while Free Flow listens, and your video keeps playing.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            step("Action Button", "iPhone 15 Pro and later: Settings > Action Button, swipe to Controls, tap Choose a Control, search Free Flow, pick Start/Stop Free Flow.")
            step("Control Center", "Swipe down from the top right, tap + (top left), Add a Control, search Free Flow, pick Start/Stop Free Flow.")
            step("Lock Screen", "Touch and hold the Lock Screen, tap Customize, then Lock Screen. Tap the minus on a bottom button, tap the empty spot, search Free Flow, pick Start/Stop Free Flow.")
            step("The first press", "If Free Flow's mic session is off, iOS only lets the microphone turn on in the app, so the first press opens Free Flow and starts listening there. Go back to what you were doing. While the session stays on, presses work without leaving your app.")
            step("Live Activities", "Leave Live Activities on for Free Flow (Settings > Free Flow). iOS lets a press listen only while Free Flow's Live Activity shows; with them off, the press says so and turns the mic off.")
            Button("Turn on the Copied notice") { NoticePoster.requestPermission() }
                .font(FFFont.text(16, .bold)).tint(Palette.accentText)
                .accessibilityIdentifier("noticeButton")
            Text("iPad and Mac have no Action Button; use Control Center or the keyboard.").font(FFFont.text(15)).foregroundStyle(Palette.faint)
        }
        .navigationTitle("Ways to start")
    }

    private func step(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(FFFont.text(19, .bold))
            Text(body).font(FFFont.text(16)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }
}

/// The keyboard layout, easy to spot near the top of Settings: its name, then three small live previews
/// (Classic first, the default; the one in use outlined). Tap a preview for the large view and its Use button.
struct KeyLayoutRow: View {
    @Binding var selected: KeyLayoutKind
    @Binding var open: KeyLayoutKind?
    @Environment(\.displayScale) private var scale

    var body: some View {
        let previews = KeyLayoutKind.rowPreviews(current: selected)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let kbW = Double(UIScreen.main.bounds.width)
        let kbH = KeyboardLayouts.height(width: kbW, isPad: isPad)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Layout").font(FFFont.text(17, .semibold)).foregroundStyle(Palette.fg)
                Spacer()
                Text(selected.title).font(FFFont.text(17)).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("settings.keyLayout.current")
            }
            GeometryReader { geo in
                let gap = 8.0
                let w = max(1, (Double(geo.size.width) - 2 * gap) / 3)
                let s = w / kbW
                HStack(alignment: .top, spacing: gap) {
                    ForEach(previews, id: \.self) { kind in
                        let on = kind == selected
                        Button { open = kind } label: {
                            KeyboardPreview(kind: kind, width: kbW, isPad: isPad, scale: Double(scale), hand: KeyHand.current,
                                            globe: KeyLayoutPage.keyboardShowsGlobe(isPad: isPad),
                                            state: KeyFaceState(sessionLive: false, stylePill: SharedSession.style.pill))
                                .scaleEffect(s, anchor: .topLeading)
                                .frame(width: kbW * s, height: kbH * s, alignment: .topLeading)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(on ? Palette.brand : Palette.lineStrong, lineWidth: on ? 2 : 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(kind.title)
                        .accessibilityValue(on ? "In use" : (kind == KeyLayoutKind.standard ? "Default" : ""))
                        .accessibilityIdentifier("layoutMini.\(kind.rawValue)")
                    }
                }
            }
            .aspectRatio(CGFloat(3 * kbW / kbH), contentMode: .fit)
            HStack(alignment: .top, spacing: 8) {
                ForEach(previews, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(FFFont.text(13, .semibold)).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                        if kind == KeyLayoutKind.standard { Text("Default").font(FFFont.text(12)).foregroundStyle(Palette.muted) }
                        if kind == selected { Text("In use").font(FFFont.text(12, .semibold)).foregroundStyle(Palette.accentText) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One layout, large, with its Use button (from the Keyboard row's previews).
struct KeyLayoutDetail: View {
    let kind: KeyLayoutKind
    @Binding var selected: KeyLayoutKind
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let screenW = Double(geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing)
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let s = min(1, (Double(geo.size.width) - 32) / max(screenW, 1))
            let h = KeyboardLayouts.height(width: screenW, isPad: isPad)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind.title).font(FFFont.text(24, .bold)).foregroundStyle(Palette.fg)
                    if kind == KeyLayoutKind.standard {
                        Text("The default layout.").font(FFFont.text(15, .semibold)).foregroundStyle(Palette.muted)
                    }
                    Text(kind.detail).font(FFFont.text(15)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    KeyboardPreview(kind: kind, width: screenW, isPad: isPad, scale: Double(scale), hand: KeyHand.current,
                                    globe: KeyLayoutPage.keyboardShowsGlobe(isPad: isPad),
                                    state: KeyFaceState(sessionLive: SharedSession.micState != .off, stylePill: SharedSession.style.pill))
                        .scaleEffect(s, anchor: .topLeading)
                        .frame(width: screenW * s, height: h * s, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if kind == selected {
                        Label("In use", systemImage: "checkmark.circle.fill").font(FFFont.text(17, .semibold))
                            .foregroundStyle(Palette.accentText).accessibilityIdentifier("layoutDetail.inUse")
                    } else {
                        Button("Use \(kind.title)") { selected = kind; KeyLayoutKind.current = kind }
                            .buttonStyle(FFButtonStyle(.primary)).accessibilityIdentifier("layoutDetail.use")
                    }
                    NavigationLink("All layouts, and try typing") { KeyLayoutPage(selected: $selected) }
                        .font(FFFont.text(16, .semibold)).accessibilityIdentifier("layoutDetail.all")
                }
                .padding(16)
            }
        }
        .background(Palette.bg)
        .navigationTitle("Keyboard layout")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if !targetEnvironment(macCatalyst)
/// Build 26 (MicChoice): which microphone Free Flow records from. Built-in by default; any input iOS
/// offers can be picked, a Bluetooth headset mic included, and the note under it says what that costs.
struct MicPicker: View {
    @AppStorage(MicChoice.key) private var micInput = ""
    @AppStorage(MicChoice.nameKey) private var micName = ""
    @AppStorage(MicChoice.bluetoothKey) private var micBluetooth = false
    @State private var available: [MicChoice.Input] = []

    var body: some View {
        Picker("Microphone", selection: $micInput) {
            ForEach(MicChoice.rows(available: available, saved: micInput, savedName: micName), id: \.tag) { row in
                Text(row.title).tag(row.tag)
            }
        }
        .accessibilityIdentifier("settings.mic")
        .onChange(of: micInput) { _, uid in
            if uid.isEmpty { micName = ""; micBluetooth = false }
            else if let input = available.first(where: { $0.uid == uid }) { micName = input.name; micBluetooth = input.isBluetooth }
        }
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in refresh() }
        Text(MicChoice.note)
            .font(FFFont.text(13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.micNote")
    }

    /// A Bluetooth headset mic is listed only by a session that allows hands-free. With the mic off, the category is set
    /// that way (not activated: nothing plays or records) just to list it; with the mic on, the live route is never touched.
    private func refresh() {
        let session = AVAudioSession.sharedInstance()
        if !DictationEngine.shared.sessionLive {
            try? session.ffSetPlayAndRecord(mixWithOthers: true, duckOthers: false, bluetoothMic: true)
        }
        let now = (session.availableInputs ?? []).map(DictationEngine.micInput)
        if now != available { available = now }
    }
}
#endif

/// Build 28: Settings > Test build, shown only in TestFlight and Xcode builds (StoreKit's AppTransaction
/// environment), never in the App Store build. Export diagnostics shares WriteDiagnostics (counts and times of the
/// writing step from the app and the keyboard; never words or audio).
struct TestBuildSection: View {
    @State private var shown = false
    @State private var keyboardWrites = KeyboardWriting.enabled
    @AppStorage("bgprobe.armed") private var probeArmed = false

    var body: some View {
        Group {
            if shown {
                Section("Test build") {
                    Toggle("Write keyboard dictations in the keyboard", isOn: $keyboardWrites)
                        .onChange(of: keyboardWrites) { _, on in KeyboardWriting.enabled = on }
                    Toggle("Background Apple test (next time Free Flow is in the background)", isOn: $probeArmed)
                    ShareLink(item: DiagnosticsFile(), preview: SharePreview("Free Flow diagnostics")) {
                        Text("Export diagnostics")
                    }
                    Button("Clear diagnostics", role: .destructive) { WriteDiagnostics.clear() }
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
                Section { EmptyView() } footer: {
                    Text("Test builds only. Diagnostics hold counts and times of the writing step from the app and the keyboard, never your words or audio. The background test calls Apple Intelligence on a fixed sample sentence while Free Flow is in the background; start a session first.")
                        .font(FFFont.text(14))
                }.listSectionSeparator(.hidden)
            }
        }
        .task { shown = await TestBuild.isTestBuild() }
    }
}

/// TestFlight or Xcode, never the App Store build. Build 28 on an iPad (TestFlight) did not show the section with
/// only a verified AppTransaction check, so: the receipt's file name first ("sandboxReceipt" on TestFlight installs, a
/// synchronous check that needs no network), then AppTransaction's environment, verified or not (only the environment
/// is read; any failure there means "not shown" unless the receipt already said test build).
enum TestBuild {
    static var receiptSaysTest: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    static func isTestBuild() async -> Bool {
        #if DEBUG
        return true
        #else
        if receiptSaysTest { return true }
        do {
            let result = try await AppTransaction.shared
            let t: AppTransaction
            switch result {
            case .verified(let v): t = v
            case .unverified(let v, _): t = v
            }
            return t.environment == .sandbox || t.environment == .xcode
        } catch {
            return false
        }
        #endif
    }
}

/// The diagnostics file, written when it is shared.
struct DiagnosticsFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            let info = Bundle.main.infoDictionary ?? [:]
            var sys = utsname(); uname(&sys)
            let machine = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let header = "Free Flow \(info["CFBundleShortVersionString"] ?? "") (\(info["CFBundleVersion"] ?? "")) · \(machine) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) · exported \(ISO8601DateFormatter().string(from: Date()))"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("freeflow-diagnostics.txt")
            try WriteDiagnostics.export(header: header).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
