import FreeFlowKit
import SwiftUI

struct HomeView: View {
    @ObservedObject private var readout = WritingReadoutStore.shared
    @State private var showHeard = false
    @EnvironmentObject private var engine: DictationEngine
    @EnvironmentObject private var models: ModelManager
    @AppStorage("sessionMinutes") private var sessionMinutes = 15
    @State private var style = SharedSession.style
    @State private var tryText = ""
    @ObservedObject private var stats = StatsStore.shared
    @ObservedObject private var clips = ClipStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Page {
            HStack(spacing: 12) {
                // The 30 Hz pulse only while it can be seen: paused the moment Free Flow is not the active app.
                BrandMark(withSound: true, animating: engine.phase == .listening && scenePhase == .active).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 0) {
                    Text("FREE FLOW").font(FFFont.display(34))
                    Text("by MASHBOX Labs").font(FFFont.text(15, .semibold)).foregroundStyle(Palette.muted)
                }
            }
            if let from = models.movedFrom {
                HStack(alignment: .firstTextBaseline) {
                    Text(ModelCatalog.movedLine(from: from, to: models.active, downloaded: models.activeReady))
                        .font(FFFont.text(15)).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("catalogMoved")
                    Spacer(minLength: 8)
                    Button("OK") { models.movedFrom = nil }.buttonStyle(FFButtonStyle(.secondary))
                }
                .ffCard()
            }
            if let notice = models.crashNotice {
                Label(notice, systemImage: "arrow.uturn.backward.circle")
                    .font(FFFont.text(16, .semibold)).foregroundStyle(Palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading).ffCard().accessibilityIdentifier("cppCrashNotice")
            }
            if let clip = engine.recoveryPrompt, engine.phase != .listening, clips.clips.contains(where: { $0.id == clip.id }) {
                recoveryCard(clip)
            }
            if engine.retryingID != nil {
                Label("Transcribing your saved recording on this device", systemImage: "waveform")
                    .font(FFFont.text(16, .semibold)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).ffCard().accessibilityIdentifier("retryingNote")
            }
            dictateCard
            if let error = engine.errorText, engine.phase == .error {
                Text(error).font(FFFont.text(16, .semibold)).foregroundStyle(engine.errorIsSaved ? Palette.fg : Palette.danger)
                    .accessibilityIdentifier(engine.errorIsSaved ? "savedText" : "errorText")
            }
            if !engine.transcript.isEmpty { resultCard }
            StatsCardRow(store: stats) { StatsPage(store: stats) }
            #if targetEnvironment(macCatalyst)
            MacFnCard()   // the Mac starts with fn; no keyboard session
            #else
            sessionCard
            #endif
            styleCard
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.tryTitle).ffEyebrow()
                TextField(Self.tryPrompt, text: $tryText, axis: .vertical)
                    .font(FFFont.text(17)).lineLimit(3...6).padding(12)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("tryField")
            }
            .ffCard()
        }
        .navigationTitle("Dictate")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dictateCard: some View {
        VStack(spacing: 14) {
            if engine.phase == .listening || engine.phase == .transcribing {
                MeterPanel(title: engine.phase == .listening ? "Listening" : (engine.stage.isEmpty ? "Transcribing" : engine.stage),
                               subtitle: SharedSession.inputName, busy: engine.phase == .transcribing,
                               onCancel: { engine.cancelDictation() },
                               onFinish: { Task { await engine.finishDictation() } })
            } else {
                MicButton { Task { await engine.startDictation(target: .app) } }
                Text(models.activeReady ? "\(DictationEngine.SystemWords.tap) to dictate · \(models.active.name)"
                     : (models.activeMissing ? "Your speech model (\(models.active.name)) is missing. Download it again to dictate."
                                             : "Download a speech model to start"))
                    .font(FFFont.text(15, .semibold)).foregroundStyle(models.activeReady ? Palette.muted : Palette.warn)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("modelState")
                if !models.activeReady {
                    NavigationLink { ModelsView() } label: { Text("Open Models") }
                        .buttonStyle(FFButtonStyle(.primary)).accessibilityIdentifier("home.openModels")
                }
            }
            if let hint = engine.slowHint { slowCard(hint) }
            // Build 22: the pick's load as it happens: "Loading on the Neural Engine…", then the one-time build with its
            // time so far and what it took on a Mac (build 18 said "Preparing the speech model" with no end in sight).
            if models.building[models.activeID] != nil && engine.phase != .transcribing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView().tint(Palette.brand)
                        Text(models.loadLabel(models.activeID, now: context.date) ?? "Loading…")
                            .font(FFFont.text(14)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("preparingModel")
            }
        }
        .frame(maxWidth: .infinity)
        .ffCard()
    }

    /// Build 18: the chosen speech model is not the recommended one and runs long on this device. Say so plainly.
    /// Build 22: only after this dictation's transcription ran longer than the recording (a measurement, not a timer).
    private func slowCard(_ hint: DictationEngine.SlowHint) -> some View {
        let device = DeviceWord.current
        return VStack(alignment: .leading, spacing: 10) {
            Text("A smaller model may feel faster on this \(device).")
                .font(FFFont.text(16, .semibold)).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("slowHint")
            Text(hint.smaller).font(FFFont.text(15)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                Button("Switch") { engine.switchToSmaller() }
                    .buttonStyle(FFButtonStyle(.primary)).accessibilityIdentifier("slowHint.use")
                Button("Not now") { engine.notNowSlowHint() }
                    .buttonStyle(FFButtonStyle(.secondary)).accessibilityIdentifier("slowHint.keep")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Recording stopped by a call or another app. Transcribe it?" Later keeps it in History > Recent recordings.
    private func recoveryCard(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clip.promptTitle).font(FFFont.text(18, .bold)).accessibilityIdentifier("prompt.title")
            Text("\(clip.duration) of audio is saved on this device. It never leaves it.")
                .font(FFFont.text(15)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                Button("Transcribe") { Task { await engine.answerPrompt(transcribe: true) } }
                    .buttonStyle(FFButtonStyle(.primary)).accessibilityIdentifier("prompt.transcribe")
                Button("Later") { Task { await engine.answerPrompt(transcribe: false) } }
                    .buttonStyle(FFButtonStyle(.secondary)).accessibilityIdentifier("prompt.later")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recoveryPrompt")
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last dictation").ffEyebrow()
            Text(engine.transcript).font(FFFont.text(19)).textSelection(.enabled).accessibilityIdentifier("transcriptText")
            HStack {
                Button("Copy") { UIPasteboard.general.string = engine.transcript }.buttonStyle(FFButtonStyle(.secondary))
                Spacer()
            }
            if let stats = engine.stats {
                Text(stats.line).font(FFFont.mono(12)).foregroundStyle(Palette.muted).accessibilityIdentifier("statsText")
                Text(String(format: "Model load %.2f s · memory %.0f MB · audio from %@", stats.loadSeconds, stats.footprintMB, stats.source))
                    .font(FFFont.mono(12)).foregroundStyle(Palette.faint)
            }
            // Build 18 (before it, nothing showed whether a language model had run at all): one small line says who
            // wrote this text and how long it took; tap it for what was heard and the details.
            if let r = readout.last {
                Button { showHeard.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(r.short).font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.muted)
                        Image(systemName: showHeard ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.short + (showHeard ? ", hide what was heard" : ", show what was heard"))
                .accessibilityIdentifier("writtenBy")
                if showHeard {
                    if let heard = readout.heard {
                        Text("Heard: " + heard).font(FFFont.text(15)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("heardText")
                    }
                    Text("Cleanup: " + r.line).font(FFFont.mono(12)).foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("writeReadout")
                }
            }
        }
        .ffCard()
    }

    #if targetEnvironment(macCatalyst)
    static let tryTitle = "Try it", tryPrompt = "Click here, hold fn and talk, then let go"
    #else
    static let tryTitle = "Try the keyboard", tryPrompt = "Tap here, then switch to the Free Flow keyboard"
    #endif

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Session").ffEyebrow()
                Spacer()
                Circle().fill(engine.sessionLive ? Palette.ok : Palette.faint).frame(width: 8, height: 8)
                Text(engine.sessionLive ? "On" : "Off").font(FFFont.text(14, .bold)).accessibilityIdentifier("sessionState")
            }
            Text("While a session is on, the keyboard dictates without opening this app, and videos keep playing. iOS shows the orange mic dot; audio is recorded only while you dictate.")
                .font(FFFont.text(15)).foregroundStyle(Palette.muted)
            if let end = engine.sessionEndsAt, engine.sessionLive {
                Text("Ends \(end, style: .relative) from now").font(FFFont.text(14, .semibold)).foregroundStyle(Palette.faint)
            }
            HStack {
                Button(engine.sessionLive ? "End session" : "Start session") {
                    if engine.sessionLive { engine.endSession("You turned it off in Free Flow") } else { Task { try? await engine.startSession() } }
                }
                .buttonStyle(FFButtonStyle(engine.sessionLive ? .secondary : .primary))
                .accessibilityIdentifier("sessionButton")
                Spacer()
                Picker("Length", selection: $sessionMinutes) {
                    Text("5 min").tag(5); Text("15 min").tag(15); Text("1 hour").tag(60)
                }
                .tint(Palette.accentText)
            }
        }
        .ffCard()
    }

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Style").ffEyebrow()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DictationStyle.allCases) { s in
                        Button(s.pill) { style = s; SharedSession.style = s }
                            .font(FFFont.text(16, .bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(style == s ? Palette.brand : Palette.panel))
                            .foregroundStyle(style == s ? Palette.accentInk : Palette.fg)
                    }
                }
            }
            Text(style.example).font(FFFont.text(15)).foregroundStyle(Palette.muted)
        }
        .ffCard()
    }
}

/// ListeningPanel fed by LevelMeter, so a mic level redraws only this panel.
private struct MeterPanel: View {
    @ObservedObject private var meter = LevelMeter.shared
    let title: String
    let subtitle: String
    let busy: Bool
    let onCancel: () -> Void
    let onFinish: () -> Void

    var body: some View {
        ListeningPanel(levels: meter.levels, title: title, subtitle: subtitle, busy: busy, onCancel: onCancel, onFinish: onFinish)
    }
}
