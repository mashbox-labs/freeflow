import SwiftUI
import FreeFlowKit

/// Settings › Writing › Where it runs (build 18: show where the model runs and how much memory it uses). Only what
/// this device reports: the speech model, where it runs (Core ML's
/// own plan for a Core ML model, the backend of the last run for the C++ engine), Free Flow's memory footprint as iOS
/// counts it (phys_footprint), and whether Apple Intelligence writes, with the reason when it can't.
struct WhereItRunsPage: View {
    @EnvironmentObject private var models: ModelManager
    @ObservedObject private var apple = AppleStatus.shared
    @ObservedObject private var readout = WritingReadoutStore.shared
    @AppStorage(WriterChoice.key) private var writerChoice = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Page {
            speechCard
            writerCard
        }
        .accessibilityIdentifier("whereItRuns")
        .navigationTitle("Where it runs")
        .task { WritingModel.refreshApple() }
        .task(id: models.loadedID) { await models.loadPlanIfNeeded() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                models.refreshDevice()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var speechCard: some View {
        let loaded = models.loadedID.flatMap(ModelCatalog.model)
        let model = loaded ?? models.active
        return VStack(alignment: .leading, spacing: 8) {
            Text("Speech").ffEyebrow()
            Text(model.name).font(FFFont.text(19, .bold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("where.speechModel")
            row("Engine", ModelCatalog.backendLabel(for: model))
            row("Runs on", runsOn(model, loaded: loaded != nil)).accessibilityIdentifier("where.speechCompute")
            if loaded != nil, !model.engine.isCpp, !models.plan.isEmpty {
                row("Core ML plan", models.plan.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
            }
            row("Free Flow's memory now", mb(models.footprintNow)).accessibilityIdentifier("where.memory")
            row("Peak this session", mb(models.peakFootprint))
            Text("Memory is Free Flow's footprint as \(DictationEngine.SystemWords.os) counts it, speech model included.")
                .font(FFFont.text(13)).foregroundStyle(Palette.faint).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private var writerCard: some View {
        let on = WriterChoice.resolved(raw: writerChoice) == .apple
        let title: String, detail: String
        if !on {
            title = "Off"
            detail = "Your words go in as the speech model heard them, with your dictionary words."
        } else if apple.available {
            title = "Apple Intelligence, on this device"
            detail = "It runs in Apple's own system process, so its memory is not part of Free Flow's numbers above. Nothing leaves this device."
        } else {
            title = "Not available: " + (apple.reason ?? "Apple Intelligence can't run here")
            detail = "Your words go in as the speech model heard them, with your dictionary words."
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Writer").ffEyebrow()
            Text(title).font(FFFont.text(19, .bold)).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(on && !apple.available ? Palette.warn : Palette.fg)
                .accessibilityIdentifier("where.writer")
            Text(detail).font(FFFont.text(15)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let last = readout.last {
                row("Last dictation", last.short)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    /// Core ML: the units Free Flow allows (Neural Engine and CPU); the plan row shows how Core ML split the model.
    /// C++: the backend the last run used (GPU only while the app is open, CPU in the background).
    private func runsOn(_ model: SpeechModel, loaded: Bool) -> String {
        if model.engine.isCpp {
            switch models.lastBackend {
            case "metal": return "GPU (Metal), last run"
            case .some: return "CPU, last run"
            case nil: return "CPU or GPU, not run yet"
            }
        }
        return loaded ? "Neural Engine and CPU" : "Neural Engine and CPU, once loaded"
    }

    private func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_000_000) }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(FFFont.text(14, .semibold)).foregroundStyle(Palette.muted)
            Spacer(minLength: 12)
            Text(v).font(FFFont.mono(12.5)).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
