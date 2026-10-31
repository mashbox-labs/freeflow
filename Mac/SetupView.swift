import AVFoundation
import AppKit
import ApplicationServices
import FreeFlowKit
import SwiftUI

/// What the setup window shows about this machine, read once a second while the window is open.
@MainActor
final class SetupModel: ObservableObject {
    @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var accessibility = AXIsProcessTrusted()
    @Published var fnNote = FnKeySetting.note
    /// Apple's model on this machine, as last checked off the main thread (never from a view body).
    /// The first value is read when the window opens, so it never shows a state the machine isn't in.
    @Published var apple: (available: Bool, reason: String?) = MacWriter.check
    @Published var footprint: UInt64 = DeviceProfile.footprintBytes()
    @Published var peak: UInt64 = DeviceProfile.footprintBytes()
    /// The system's default input, the mic Free Flow records from.
    @Published var micName = AudioDevices.name(AudioDevices.defaultInput())
    private var timer: Timer?

    var ready: Bool { mic == .authorized && accessibility && MacModels.shared.speechReady }

    func watch() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        read()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func read() {
        let m = AVCaptureDevice.authorizationStatus(for: .audio)
        if m != mic { mic = m }
        let a = AXIsProcessTrusted()
        if a != accessibility {
            accessibility = a
            if a { MacDictation.shared.startHotkey() }
        }
        let note = FnKeySetting.note
        if note != fnNote { fnNote = note }
        let input = AudioDevices.name(AudioDevices.defaultInput())
        if input != micName { micName = input }
        let f = DeviceProfile.footprintBytes()
        if abs(Int64(f) - Int64(footprint)) >= 1 << 20 { footprint = f }
        if f > peak { peak = f }
        Task.detached(priority: .utility) {
            let c = MacWriter.check
            await MainActor.run { if self.apple.available != c.available || self.apple.reason != c.reason { self.apple = c } }
        }
    }

    func askMic() {
        switch mic {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.read() } }
        default:
            Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func askAccessibility() {
        // Adds Free Flow to the list and shows macOS's own prompt; the switch itself is the user's.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openKeyboardSettings() { Self.open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }

    static func open(_ s: String) { if let url = URL(string: s) { NSWorkspace.shared.open(url) } }
}

/// The setup and settings window: permissions, models, the fn key, style, dictionary, a place to try it, credits.
/// MASHBOX visual language v1 through FreeFlowKit's Palette and FFFont: paper page, paper-2 cards with no stroke,
/// filled pills, one primary per card, a full thin stroke only on things you type into.
struct SetupView: View {
    @ObservedObject var setup: SetupModel
    @ObservedObject var models: MacModels
    @ObservedObject var dictation: MacDictation
    @ObservedObject var dictionary: DictionaryStore
    @State private var newWord = ""
    @State private var tryText = ""
    @State private var showCredits = false
    @AppStorage(WriterChoice.key) private var writerChoice = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if setup.ready { readyCard }
                StepCard(title: "Microphone", detail: "Free Flow listens only while you hold fn.", done: setup.mic == .authorized) {
                    Button(setup.mic == .notDetermined ? "Allow" : "Open Settings") { setup.askMic() }
                        .buttonStyle(FFButtonStyle(.primary))
                }
                StepCard(title: "Accessibility", detail: "Lets fn work in every app and puts your words where your cursor is. Turn on Free Flow in the list that opens.",
                         done: setup.accessibility) {
                    Button("Open Settings") { setup.askAccessibility() }.buttonStyle(FFButtonStyle(.primary))
                }
                speechCard
                writerCard
                whereCard
                fnCard
                styleCard
                dictionaryCard
                tryCard
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 22)
        }
        .background(Palette.bg)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandMark(withSound: true, animating: dictation.phase != .idle)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("FREE FLOW")
                    .font(FFFont.display(40))
                    .foregroundStyle(Palette.fg)
                Text("Hold fn and talk. Your words go where your cursor is, and never leave this Mac.")
                    .font(FFFont.text(14.5))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.bottom, 4)
    }

    /// Setup is done: say so first (build 18: after the model download nothing said setup was complete).
    private var readyCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok).font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready. Hold fn in any app and talk, then let go to type it.")
                    .font(FFFont.text(16, .bold)).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                Text("Press fn twice for hands-free. Closing this window keeps Free Flow running; it is in the Dock and the menu bar.")
                    .font(FFFont.text(13.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
        .accessibilityIdentifier("setup.ready")
    }

    private var speechCard: some View {
        let status = models.status[MacModels.speechID] ?? .notDownloaded
        return StepCard(title: "Speech model", detail: "Parakeet v3 · Core ML on the Neural Engine · \(DiskSpace.format(models.bytes(MacModels.speechID)))",
                        done: status == .ready) {
            ModelButton(status: status, label: "Download") { Task { await models.download(MacModels.speechID) } }
        }
    }

    /// Build 18: Apple Intelligence is the writer and it is optional; where it can't run, the reason.
    private var writerCard: some View {
        let on = writerChoice != WriterChoice.off.rawValue
        let state = WriterChoice.status(choice: on ? .apple : .off, appleAvailable: setup.apple.available, reason: setup.apple.reason).state
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { on }, set: { writerChoice = $0 ? WriterChoice.apple.rawValue : WriterChoice.off.rawValue })) {
                Text("Clean up with Apple Intelligence").font(FFFont.text(16.5, .bold)).foregroundStyle(Palette.fg)
            }
            .toggleStyle(.switch).tint(Palette.brand)
            Text(state).font(FFFont.text(14)).foregroundStyle(on && !setup.apple.available ? Palette.warn : Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Apple's on-device model writes each dictation in your style. Off, your words go in as Parakeet heard them, with your dictionary words.")
                .font(FFFont.text(13.5)).foregroundStyle(Palette.faint).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    /// Where it runs (show where the model runs and how much memory it uses): only what the machine reports.
    private var whereCard: some View {
        let on = writerChoice != WriterChoice.off.rawValue
        let writer = !on ? "Off" : setup.apple.available ? "Apple Intelligence, on this Mac" : "Not available: " + (setup.apple.reason ?? "Apple Intelligence can't run here")
        return VStack(alignment: .leading, spacing: 6) {
            Text("Where it runs").font(FFFont.text(16.5, .bold)).foregroundStyle(Palette.fg)
            whereRow("Microphone", setup.micName)
            whereRow("Speech", "Parakeet v3 · Core ML · Neural Engine and CPU")
            whereRow("Free Flow's memory now", String(format: "%.0f MB", Double(setup.footprint) / 1_000_000))
            whereRow("Peak while open", String(format: "%.0f MB", Double(setup.peak) / 1_000_000))
            whereRow("Writer", writer)
            if on && setup.apple.available {
                Text("Apple's model runs in Apple's own system process, so its memory is not part of Free Flow's numbers above.")
                    .font(FFFont.text(12.5)).foregroundStyle(Palette.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private func whereRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.muted)
            Spacer(minLength: 12)
            Text(v).font(FFFont.mono(12)).multilineTextAlignment(.trailing).foregroundStyle(Palette.fg)
        }
    }

    private var fnCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The fn key").font(FFFont.text(16.5, .bold)).foregroundStyle(Palette.fg)
            Text("Hold fn and talk, let go to type it. Press fn twice for hands-free, then fn again to stop. Esc cancels.")
                .font(FFFont.text(14.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let note = setup.fnNote {
                HStack(alignment: .center, spacing: 12) {
                    Text(note)
                        .font(FFFont.text(14, .medium)).foregroundStyle(Palette.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Keyboard Settings") { setup.openKeyboardSettings() }.buttonStyle(SmallPill())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Style").font(FFFont.text(16.5, .bold)).foregroundStyle(Palette.fg)
            HStack(spacing: 8) {
                ForEach(DictationStyle.allCases) { s in
                    Button(s.pill) { dictation.style = s }
                        .buttonStyle(ChoicePill(selected: dictation.style == s))
                }
            }
            Text(dictation.style.example).font(FFFont.text(14)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private var dictionaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dictionary").font(FFFont.text(16.5, .bold)).foregroundStyle(Palette.fg)
            Text("Names and words Free Flow should listen for.").font(FFFont.text(14.5)).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                TextField("Add a word", text: $newWord)
                    .textFieldStyle(.plain)
                    .font(FFFont.text(14.5))
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(Palette.bg, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
                    .ffStroke(Radius.input)
                    .onSubmit(addWord)
                Button("Add", action: addWord).buttonStyle(SmallPill())
            }
            if !dictionary.entries.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(dictionary.entries) { entry in
                        Button { dictionary.remove([entry.id]) } label: {
                            HStack(spacing: 5) {
                                Text(entry.word)
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.faint)
                            }
                        }
                        .buttonStyle(TagStyle())
                        .accessibilityLabel("Remove \(entry.word)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private func addWord() {
        dictionary.add(word: newWord)
        newWord = ""
    }

    private var tryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it").font(FFFont.text(16.5, .bold)).foregroundStyle(Palette.fg)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $tryText)
                    .font(FFFont.text(15))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if tryText.isEmpty {
                    Text("Click here, hold fn and talk.")
                        .font(FFFont.text(15)).foregroundStyle(Palette.faint)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
            .ffStroke(Radius.input)
            if let r = dictation.lastReadout {
                Text(r.short).font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Last cleanup: " + r.line).font(FFFont.text(12.5)).foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(showCredits ? "Hide credits" : "Credits") { withAnimation(.easeOut(duration: 0.2)) { showCredits.toggle() } }
                .buttonStyle(SmallPill())
            if showCredits {
                ForEach(MacCredits.all, id: \.0) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.0).font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.fg)
                        Text(c.1).font(FFFont.text(13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Free Flow by MASHBOX Labs. Free, on your Mac.").font(FFFont.text(12.5)).foregroundStyle(Palette.faint)
        }
        .padding(.top, 4)
    }
}

/// The credits the Mac app owes, worded as the iPhone app's About > Credits words them.
enum MacCredits {
    static let all: [(String, String)] = [
        ("Parakeet TDT 0.6B v3", "NVIDIA. Licensed CC-BY-4.0. Core ML conversion by FluidInference."),
        ("llama.cpp", "The ggml authors (ggml-org). Licensed MIT."),
        ("FluidAudio", "FluidInference. Licensed Apache-2.0."),
        ("Model downloads", "Hugging Face hosts the model files. Each file the Download button fetches is checked against a sha256 pinned in this build."),
        ("Outfit, Geist Mono, Big Shoulders Display, Barlow Semi Condensed", "Fonts licensed under the SIL Open Font License 1.1."),
        ("Free Flow", "MASHBOX Labs. Source available under the PolyForm Noncommercial License 1.0.0: free for personal and noncommercial use, not for sale."),
    ]
}

/// A step: title, one line, then a Done tag or the step's button. `done` nil = optional, no tag.
struct StepCard<Action: View>: View {
    let title: String
    let detail: String
    let done: Bool?
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(FFFont.text(16.5, .bold)).foregroundStyle(Palette.fg)
                Text(detail).font(FFFont.text(14.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if done == true {
                Text("Done")
                    .font(FFFont.text(12.5, .semibold))
                    .foregroundStyle(Palette.ok)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.panel, in: Capsule(style: .continuous))
            } else {
                action()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }
}

/// Download button that turns into progress, a retry, or nothing once the model is in place.
struct ModelButton: View {
    let status: MacModels.Status
    let label: String
    var primary = true
    let action: () -> Void

    var body: some View {
        switch status {
        case .downloading(let p):
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(Int(p * 100))%").font(FFFont.mono(12.5)).foregroundStyle(Palette.muted)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Palette.panel)
                    Capsule(style: .continuous).fill(Palette.brand).frame(width: max(6, 110 * p))
                }
                .frame(width: 110, height: 6)
            }
        case .failed(let why):
            VStack(alignment: .trailing, spacing: 5) {
                Button("Try again", action: action).buttonStyle(FFButtonStyle(.primary))
                Text(why).font(FFFont.text(12)).foregroundStyle(Palette.danger).frame(maxWidth: 200, alignment: .trailing)
            }
        case .ready:
            EmptyView()
        case .notDownloaded:
            Button(label, action: action).buttonStyle(FFButtonStyle(primary ? .primary : .secondary))
        }
    }
}

/// Small pill (nav "Request access"): paper-3 fill, no stroke, 32 tall on this dense screen.
struct SmallPill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FFFont.text(14, .medium))
            .foregroundStyle(Palette.fg)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(configuration.isPressed ? Palette.line : Palette.panel, in: Capsule(style: .continuous))
            .contentShape(Capsule())
    }
}

/// A style choice: the chosen one is the primary pill, the others secondary.
struct ChoicePill: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FFFont.text(14.5, selected ? .semibold : .medium))
            .foregroundStyle(selected ? Palette.priInk : Palette.fg)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(selected ? Palette.pri : (configuration.isPressed ? Palette.pillDown : Palette.pill),
                        in: Capsule(style: .continuous))
            .contentShape(Capsule())
    }
}

/// A word in the dictionary: tag style (paper-3, no stroke).
struct TagStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FFFont.text(13, .medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(configuration.isPressed ? Palette.line : Palette.panel, in: Capsule(style: .continuous))
    }
}

/// Wraps its children onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
