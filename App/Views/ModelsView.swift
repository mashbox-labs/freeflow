import FreeFlowKit
import SwiftUI
import UIKit

/// Settings > Models and the Models tab (every size and quantization as an option, on a page with its own look).
/// One section per model (Parakeet, Whisper, Liquid AI's LFM Audio), each way to run it a card with
/// its size, quantization, engine, languages and the speed measured on the simulator. Free space sits on top, and a
/// download that would leave the device nearly full asks first. MASHBOX visual language v1: filled cards, filled
/// pills, no strokes.
///
/// Device numbers (free space, memory, footprint) are stored values on ModelManager, read by refreshDevice() on
/// appear, after downloads and deletes, and every 5 s while this page is on screen and Free Flow is active. Never a
/// system query in a body: build 8 did that here and iOS killed the app on an iPad.
struct ModelsView: View {
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var engine: DictationEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter = "all"
    @State private var askDownload: SpeechModel?
    @State private var askDelete: SpeechModel?

    var body: some View {
        let sections = ModelCatalog.sections()
        let word = DeviceWord.current
        Page {
            storageCard(word: word)
            // Build 23: a device language no model here speaks transcribes in English for now (build 26: with
            // Whisper back, any of its 99 languages counts).
            if SpeechLanguage.deviceDefault(preferred: Locale.preferredLanguages,
                                            supported: Set(ModelCatalog.all.flatMap { Transcriber.languages(of: $0.id) })) == nil {
                Text("Your language is coming soon. Until then Free Flow transcribes in English.")
                    .font(FFFont.text(15)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("languageComingSoon")
            }
            inUseCard
            filterBar()
            ForEach(sections) { section in
                let shown = section.models.filter { filter == "all" || Self.slug($0.maker) == filter }
                if !shown.isEmpty {
                    SectionHeader(group: section.group, count: shown.count)
                    ForEach(shown) { model in
                        ModelCard(model: model, word: word, askDownload: { askDownload = $0 }, askDelete: { askDelete = $0 })
                    }
                }
            }
            LogoNotice().padding(.top, 8)
        }
        .accessibilityIdentifier("modelsPage")
        .navigationTitle("Models")
        .alert("Language", isPresented: Binding(get: { models.languageConflict != nil }, set: { if !$0 { models.languageConflict = nil } })) {
            Button("Use Automatic") { models.setLanguageAutomatic() }.accessibilityIdentifier("conflict.automatic")
            Button("Keep my language", role: .cancel) {}
        } message: { Text(models.languageConflict ?? "") }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                models.refreshDevice()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .alert(askDownload.map { "Download \($0.name)?" } ?? "", isPresented: Binding(get: { askDownload != nil }, set: { if !$0 { askDownload = nil } }),
               presenting: askDownload) { model in
            Button("Download anyway") { Task { await models.download(model) } }.accessibilityIdentifier("confirmDownload")
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(DiskBudget.warning(models.diskCheck(model), device: word) ?? "")
        }
        .alert(askDelete.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(get: { askDelete != nil }, set: { if !$0 { askDelete = nil } }),
               presenting: askDelete) { model in
            Button("Delete", role: .destructive) { Task { await models.delete(model) } }.accessibilityIdentifier("confirmDelete")
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(deleteMessage(model))
        }
    }

    private func deleteMessage(_ model: SpeechModel) -> String {
        let frees = "Frees \(DiskSpace.format(models.downloadBytes(model.id))). You can download it again any time."
        guard models.activeID == model.id else { return frees }
        let ready = Set(models.status.filter { $0.value == .ready }.map(\.key))
        if let next = ModelManager.nextActive(after: model.id, ready: ready, recommended: models.recommended.id,
                                              memoryBytes: models.device.memoryBytes).flatMap(ModelCatalog.model) {
            return "It is the model in use. Dictation moves to \(next.name). " + frees
        }
        return "It is the model in use, and no other model is downloaded: download another one to keep dictating. " + frees
    }

    // MARK: Storage

    private func storageCard(word: String) -> some View {
        let disk = models.disk
        let device = models.device
        let mine = models.installedBytes
        let note = device.isSimulator ? (device.memoryFromTest ? " (simulator, memory set by a test)" : " (simulator)") : ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This \(word)").font(FFFont.text(16.5, .bold))
                Spacer(minLength: 8)
                Text("\(DeviceProfile.marketingGB(memoryBytes: device.memoryBytes)) GB memory")
                    .font(FFFont.text(14, .medium)).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("deviceMemory")
            }
            Text("\(device.machine)\(note)").font(FFFont.text(14)).foregroundStyle(Palette.faint)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(disk.totalBytes == 0 && disk.freeBytes == 0 ? "…" : DiskSpace.format(disk.freeBytes).uppercased())
                    .font(FFFont.display(46))
                Text(disk.totalBytes > 0 ? "free of \(DiskSpace.format(disk.totalBytes))" : "free")
                    .font(FFFont.text(16, .medium)).foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("freeSpace")
            .accessibilityValue(disk.freeLine)
            StorageBar(total: disk.totalBytes, free: disk.freeBytes, models: mine)
            HStack(spacing: 14) {
                legend(Palette.brand, "Free Flow models \(DiskSpace.format(mine))")
                legend(Palette.faint, "Everything else")
            }
            Text("Free Flow asks before a download that would leave less than \(DiskSpace.format(DiskBudget.reserveBytes)) free."
                 + (disk.fromTest ? " Free space set by a test (simulator)." : ""))
                .font(FFFont.text(14)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(FFFont.text(13, .medium)).foregroundStyle(Palette.muted)
        }
    }

    // MARK: In use + live stats

    private var inUseCard: some View {
        let active = models.active
        let ready = models.activeReady
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MakerMark(model: active, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Group {
                        if ready, models.building[active.id] != nil {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(models.loadLabel(active.id, now: context.date) ?? "Loading…")
                            }
                        } else if ready, let line = models.stuck[active.id] {
                            Text(line).accessibilityIdentifier("stuck.\(active.id)")
                        } else {
                            Text(ready ? "In use" : "Picked, not downloaded yet")
                        }
                    }
                    .font(FFFont.text(13, .semibold)).foregroundStyle(ready && models.stuck[active.id] == nil ? Palette.ok : Palette.warn)
                    Text(active.name).font(FFFont.text(19, .bold)).fixedSize(horizontal: false, vertical: true)
                    Text("\(active.engineLabel) · \(active.quantLabel) · \(DiskSpace.format(active.downloadBytes))")
                        .font(FFFont.text(14, .medium)).foregroundStyle(Palette.faint)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inUse")
            VStack(alignment: .leading, spacing: 6) {
                row("Loaded", models.loadedID.flatMap { ModelCatalog.model($0)?.name } ?? "None")
                if let id = models.loadedID, ModelCatalog.model(id)?.engine.isCpp == true {
                    row("Engine", "C++ (ggml) · " + (models.lastBackend.map { $0 == "metal" ? "GPU (Metal)" : "CPU" } ?? "not run yet"))
                }
                if let s = models.loadSeconds { row("Load time", String(format: "%.2f s", s)) }
                if let stats = engine.stats {
                    row("Last run", String(format: "%.1f s audio in %.2f s", stats.audioSeconds, stats.processSeconds))
                    row("Speed", String(format: "%.0fx real time (RTF %.3f)", stats.speed, stats.rtf))
                }
                row("Memory now", String(format: "%.0f MB", Double(models.footprintNow) / 1_000_000))
                row("Memory peak", String(format: "%.0f MB", Double(models.peakFootprint) / 1_000_000))
                if models.loadedID.flatMap(ModelCatalog.model)?.engine.isCpp != true {
                    row("Core ML can use", models.availableDevices.joined(separator: ", "))
                }
                if !models.plan.isEmpty {
                    row("Planned ops", models.plan.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                }
                row("Audio", engine.capture.usesTestFile ? "Test recording (simulator)" : SharedSession.inputName)
            }
            .padding(12)
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liveStats")
            .task(id: models.loadedID) { await models.loadPlanIfNeeded() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(FFFont.text(14, .semibold)).foregroundStyle(Palette.muted)
            Spacer(minLength: 12)
            Text(v).font(FFFont.mono(12.5)).multilineTextAlignment(.trailing)
        }
    }

    // MARK: Filter

    /// Build 23: the filter by company, in catalog order: each maker's small logo and its name exactly as the
    /// catalog states it, with how many of its models are listed.
    static func makers() -> [String] {
        var seen: [String] = []
        for m in ModelCatalog.all where !seen.contains(m.maker) { seen.append(m.maker) }
        return seen
    }

    static func slug(_ maker: String) -> String { maker.lowercased().replacingOccurrences(of: " ", with: "-") }

    /// Segmented filter: the selected item is filled (ink with paper text), the rest bare. No underline.
    private func filterBar() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip("all", "All \(ModelCatalog.all.count)")
                ForEach(Self.makers(), id: \.self) { m in
                    chip(Self.slug(m), "\(m) \(ModelCatalog.all.filter { $0.maker == m }.count)", maker: m)
                }
            }
            .padding(4)
            .background(Palette.surface, in: Capsule(style: .continuous))
        }
        .padding(.top, 4)
    }

    private func chip(_ id: String, _ title: String, maker: String? = nil) -> some View {
        let on = filter == id
        return Button { filter = id } label: {
            HStack(spacing: 7) {
                if let maker { MakerChipLogo(maker: maker) }
                Text(title).font(FFFont.text(14.5, on ? .semibold : .medium))
            }
                .foregroundStyle(on ? Palette.priInk : Palette.muted)
                .padding(.leading, maker == nil ? 14 : 8).padding(.trailing, 14).frame(minHeight: 40)
                .background(on ? Palette.pri : Color.clear, in: Capsule(style: .continuous))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.\(id)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Used against the whole device: Free Flow's models in ember, everything else in ink-3, free space as the track.
/// Filled capsules only.
struct StorageBar: View {
    let total: Int64
    let free: Int64
    let models: Int64
    var body: some View {
        GeometryReader { geo in
            let t = Double(max(total, 1))
            let used = total > 0 ? Double(max(0, total - free)) / t : 0
            let mine = total > 0 ? min(Double(models) / t, used) : 0
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Palette.panel)
                Capsule(style: .continuous).fill(Palette.faint.opacity(0.55)).frame(width: max(0, geo.size.width * used))
                Capsule(style: .continuous).fill(Palette.brand).frame(width: models > 0 ? max(8, geo.size.width * mine) : 0)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

/// One model's section head: maker logo, name, maker and how many ways to run it.
struct SectionHeader: View {
    let group: ModelGroup
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let logo = group.makerLogo {
                    MakerLogo(asset: logo, size: 36)
                } else {
                    Image(systemName: "waveform").font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Palette.faint).frame(width: 36, height: 36).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name.uppercased()).font(FFFont.display(30))
                    Text("\(group.maker) · \(count) \(count == 1 ? "option" : "options")")
                        .font(FFFont.text(14, .medium)).foregroundStyle(Palette.faint)
                }
            }
            Text(group.blurb).font(FFFont.text(15)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("section.\(group.id)")
    }
}

/// One way to run a model, as one compact row (2026-10-30: the cards were slimmed so more models fit on screen at
/// once, with the details one tap away): name, runtime tag, real size, one plain line on what it is for, and its
/// state (Download, progress, Use, In use, Delete). The chevron opens the details. No test numbers on the card.
struct ModelCard: View {
    @EnvironmentObject private var models: ModelManager
    let model: SpeechModel
    let word: String
    let askDownload: (SpeechModel) -> Void
    let askDelete: (SpeechModel) -> Void
    @State private var open = false

    var body: some View {
        let status = models.status[model.id] ?? .notDownloaded
        let tooBig = ModelCatalog.tooBigReason(model, memoryBytes: models.device.memoryBytes, device: word)
        let active = tooBig == nil && models.activeID == model.id
        let inUse = active && status == .ready
        let recommended = models.recommended.id == model.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(model.name).font(FFFont.text(16.5, .bold))
                    .foregroundStyle(tooBig != nil ? Palette.faint : Palette.fg)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if tooBig == nil { state(status, active: active, inUse: inUse) }
                if status == .ready {
                    Button { askDelete(model) } label: {
                        Image(systemName: "trash").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.muted)
                            .frame(width: 32, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Delete").accessibilityIdentifier("delete.\(model.id)")
                }
                Button { withAnimation(.easeOut(duration: 0.16)) { open.toggle() } } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .frame(width: 32, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide details" : "Show details")
                .accessibilityIdentifier("expand.\(model.id)")
            }
            HStack(spacing: 6) {
                if recommended { tag("Recommended", fill: Palette.brand, ink: Palette.accentInk).accessibilityIdentifier("recommended.\(model.id)") }
                else if familyRecommended { tag("Recommended file", fill: Palette.accentSoft, ink: Palette.accentText).accessibilityIdentifier("recommended.\(model.id)") }
                tag(model.engine.isCpp ? "C++ fallback" : "Neural Engine", fill: Palette.bg, ink: model.engine.isCpp ? Palette.muted : Palette.fg)
                    .accessibilityIdentifier("runtime.\(model.id)")
                if model.usesDictionary {
                    tag("Dictionary", fill: Palette.bg, ink: Palette.muted).accessibilityIdentifier("dictionary.\(model.id)")
                }
                Text(DiskSpace.format(model.downloadBytes)).font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.muted)
                    .lineLimit(1).fixedSize().accessibilityIdentifier("size.\(model.id)")
            }
            HStack(spacing: 6) {
                Text(purpose).font(FFFont.text(13.5)).foregroundStyle(Palette.muted)
                    .lineLimit(ModelCatalog.backupLine(for: model) == nil && model.purpose == nil ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("purpose.\(model.id)")
                if status == .ready {
                    Text("· Downloaded").font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.ok).lineLimit(1).fixedSize()
                        .accessibilityIdentifier("verified.\(model.id)")
                }
            }
            if case .downloading(let p) = status { ProgressView(value: p).tint(Palette.brand) }
            warnings(status: status, tooBig: tooBig)
            if models.failedHere(model.id) {
                Label("Core ML could not load this on this \(word)", systemImage: "exclamationmark.triangle")
                    .font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.warn)
                    .accessibilityIdentifier("failedHere.\(model.id)")
            }
            if open { details(status: status, recommended: recommended, tooBig: tooBig) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(inUse ? Palette.panel : Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.\(model.id)")
        .accessibilityValue(tooBig != nil ? "too big" : (inUse ? "in use" : (status == .ready ? "downloaded" : "not downloaded")))
    }

    /// The C++ quantization this device should use within its family: never for a C++ form with a Core ML twin.
    private var familyRecommended: Bool { ModelCatalog.showsRecommendedFile(model, memoryBytes: models.device.memoryBytes) }

    /// One plain line on what the model is for: "Smallest" for the smallest Core ML file in its family, else its languages.
    private var purpose: String {
        if let backup = ModelCatalog.backupLine(for: model) { return backup }
        if let purpose = model.purpose { return purpose }
        let family = ModelCatalog.all.filter { $0.group == model.group && !$0.engine.isCpp }
        if !model.engine.isCpp, family.count > 1, family.min(by: { $0.downloadBytes < $1.downloadBytes })?.id == model.id {
            return "Smallest · \(model.languages)"
        }
        return model.languages
    }

    /// The control on the row: Download, progress, Use or In use.
    @ViewBuilder private func state(_ status: ModelManager.Status, active: Bool, inUse: Bool) -> some View {
        switch status {
        case .notDownloaded:
            downloadButton(primary: active)
        case .downloading(let p):
            Text(String(format: "%.0f%%", p * 100)).font(FFFont.mono(13)).foregroundStyle(Palette.fg)
                .accessibilityLabel(String(format: "Downloading %.0f%% of %@", p * 100, DiskSpace.format(model.downloadBytes)))
                .accessibilityIdentifier("progress.\(model.id)")
        case .verifying:
            Text("Checking…").font(FFFont.mono(12)).foregroundStyle(Palette.muted)
        case .ready:
            // Build 24: a load that passed its limit says so here, with Try again.
            if models.stuck[model.id] != nil, models.building[model.id] == nil {
                Button("Try again") { models.retryPrepare(model.id) }.buttonStyle(CompactPill(primary: true))
                    .accessibilityIdentifier("retry.\(model.id)")
            // Build 23: only the pick shows "Preparing" while it is being prepared or waits for its turn.
            } else if models.building[model.id] != nil, model.id == models.activeID || models.building[models.activeID] == nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(models.loadShort(model.id, now: context.date)).font(FFFont.mono(12)).foregroundStyle(Palette.muted)
                }
                .accessibilityIdentifier("loading.\(model.id)")
            } else if inUse {
                tag("In use", fill: Palette.bg, ink: Palette.ok)
            } else if models.activeID != model.id {
                Button("Use") { models.choose(model.id) }.buttonStyle(CompactPill(primary: false))
                    .accessibilityIdentifier("use.\(model.id)")
            }
        case .failed:
            downloadButton(primary: false, title: "Try again")
        }
    }

    /// Anything that stops or warns before a download stays on the row; the reasons are in the details.
    @ViewBuilder private func warnings(status: ModelManager.Status, tooBig: String?) -> some View {
        if tooBig != nil {
            Label("Too big for this \(word)", systemImage: "memorychip")
                .font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.warn)
                .accessibilityIdentifier("tooBig.\(model.id)")
        } else {
            if model.engine.isCpp,
               case .wontRunWell = ModelCatalog.runHealth(model, availableBytes: models.availableMemory,
                                                          loadedBytes: models.loadedModelBytes,
                                                          probeSpeed: models.measured(model.id)?.median) {
                Label("Won't run well on this \(word)", systemImage: "exclamationmark.triangle")
                    .font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.warn)
                    .accessibilityIdentifier("wontRunWell.\(model.id)")
            }
            if status == .notDownloaded || isFailed(status), let warn = DiskBudget.warning(models.diskCheck(model), device: word) {
                Label(warn, systemImage: "internaldrive")
                    .font(FFFont.text(13.5, .semibold)).foregroundStyle(noRoom ? Palette.danger : Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(warn)
                    .accessibilityIdentifier("diskWarning.\(model.id)")
            }
            if case .failed(let message) = status {
                Text(message).font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("failed.\(model.id)")
            }
        }
    }

    /// What the chevron opens: what it is, how it runs, who made it and its licence, and the reasons behind any warning.
    @ViewBuilder private func details(status: ModelManager.Status, recommended: Bool, tooBig: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if recommended {
                Text(ModelCatalog.reason(for: model, memoryBytes: models.device.memoryBytes, device: word))
                    .font(FFFont.text(14, .semibold)).foregroundStyle(Palette.fg)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("recommendReason")
            }
            Text(model.blurb).font(FFFont.text(14)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            detail("Backend", "\(ModelCatalog.backendLabel(for: model)) · \(DiskSpace.format(model.downloadBytes))", id: "backend")
            detail("Quantization", model.quantLabel, id: "quant")
            detail("Engine", model.engineLabel, id: "engine")
            detail("Languages", model.languages, id: "languages")
            detail("Made by", model.maker, id: "maker")
            detail("Licence", model.licence, id: "licence")
            if let tooBig { Text(tooBig).font(FFFont.text(13.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            if tooBig == nil, model.engine.isCpp,
               case .wontRunWell(let why) = ModelCatalog.runHealth(model, availableBytes: models.availableMemory,
                                                                  loadedBytes: models.loadedModelBytes,
                                                                  probeSpeed: models.measured(model.id)?.median) {
                Text(why).font(FFFont.text(13.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if status == .ready {
                Text("Every file matched its sha256 · pinned revision \(models.revision(model.id))")
                    .font(FFFont.mono(11.5)).foregroundStyle(Palette.ok).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func detail(_ label: String, _ value: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(FFFont.text(12.5, .medium)).foregroundStyle(Palette.faint).frame(width: 92, alignment: .leading)
            Text(value).font(FFFont.text(13.5, .semibold)).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(id).\(model.id)")
    }

    private var noRoom: Bool { if case .noRoom = models.diskCheck(model) { true } else { false } }
    private func isFailed(_ s: ModelManager.Status) -> Bool { if case .failed = s { true } else { false } }

    private func downloadButton(primary: Bool, title: String? = nil) -> some View {
        let check = models.diskCheck(model)
        return Button(title ?? "Download") {
            switch check {
            case .fine: Task { await models.download(model) }
            case .tight: askDownload(model)
            case .noRoom: break
            }
        }
        .buttonStyle(CompactPill(primary: primary))
        .disabled(noRoom)
        .opacity(noRoom ? 0.5 : 1)
        .accessibilityLabel(title ?? "Download \(DiskSpace.format(model.downloadBytes))")
        .accessibilityIdentifier("download.\(model.id)")
    }

    /// MBX tag: filled pill, no stroke.
    private func tag(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text).font(FFFont.text(12, .medium)).foregroundStyle(ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(fill, in: Capsule(style: .continuous))
    }
}

/// The small filled pill on a compact model row (MBX: filled, no stroke; 34 tall, 44 to touch).
struct CompactPill: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FFFont.text(14, .semibold))
            .foregroundStyle(primary ? Palette.accentInk : Palette.fg)
            .padding(.horizontal, 14).frame(height: 34)
            .background(primary ? Palette.brand : Palette.bg, in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .padding(.vertical, 5).contentShape(Rectangle())
    }
}

/// "iPhone", "iPad" or "Mac", for copy that names the device in hand.
enum DeviceWord {
    static var current: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return "Mac" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

/// The model picker in setup: the recommended model first with the reason, then every Core ML model in the
/// catalog, biggest download first. (Settings > Models is ModelsView above.) Models too big for this device are shown, marked and cannot be picked.
/// Everything comes from the catalog data (FreeFlowKit speech-models.json), so a new model needs no code here.
struct ModelPicker: View {
    enum Context { case setup, settings }
    @EnvironmentObject private var models: ModelManager
    let context: Context

    var body: some View {
        let order = ModelCatalog.pickerOrder(recommended: models.recommended)
        let word = DeviceWord.current
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended for this \(word)").ffEyebrow()
            ModelRow(model: order[0], recommended: true, context: context)
            if order.count > 1 {
                Text("All other models, biggest first").ffEyebrow().padding(.top, 10)
                Text("You can pick any of these instead. Those too big for this \(word) are shown, but need more memory than it has.")
                    .font(FFFont.text(15)).foregroundStyle(Palette.muted)
                if let xs = ModelCatalog.extraSmall(), xs.id != order[0].id {
                    Text("Short on space? \(xs.name) is the extra-small one, a \(xs.downloadBytes.megabytes) download.")
                        .font(FFFont.text(15)).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("extraSmallHint")
                }
                ForEach(order.dropFirst()) { model in ModelRow(model: model, recommended: false, context: context) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelPicker")
    }
}

/// Build 38: the first-run choice, always two cards: Parakeet Ultra first (recommended, preselected), then our
/// Whisper (or, under 5 GiB, the best smaller model that fits). The language point is made in one line above the cards.
/// Every line is true: Whisper large-v3-turbo covers 99 languages with its own language detection; its first use builds it
/// for this device's Neural Engine once (about 1-2 minutes); Parakeet Ultra covers 25 languages.
struct SetupModelChoice: View {
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        let word = DeviceWord.current
        let choices = ModelCatalog.setupChoices(memoryBytes: models.device.memoryBytes)
        let withWhisper = choices.contains { $0.engine.isWhisper }
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick your speech model").ffEyebrow()
            Text(withWhisper ? (choices.first?.engine.isWhisper == true
                                ? "Pick by the languages you speak. Whisper: about 99 languages, including Thai, Japanese, Chinese and Korean. Parakeet: English and 24 European languages, fastest."
                                : "Pick by the languages you speak. Parakeet: English and 24 European languages, fastest. Whisper: about 99 languages, including Thai, Japanese, Chinese and Korean.")
                             : "Pick by the languages you speak and the space you have.")
                .font(FFFont.text(15, .semibold)).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setupLanguages")
            ForEach(Array(choices.enumerated()), id: \.element.id) { i, model in
                SetupModelCard(model: model, recommended: i == 0, lines: Self.lines(model, withWhisper: withWhisper, word: word),
                               only: model.engine.isWhisper ? Self.onlyOnWhisper() : nil)
            }
            Text("You can switch any time in Settings > Models.").font(FFFont.text(14)).foregroundStyle(Palette.faint)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setupChoice")
    }

    static func lines(_ model: SpeechModel, withWhisper: Bool, word: String) -> [String] {
        if model.engine.isWhisper {
            return ["About 99 languages, and it detects the one you speak. Tends to leave out filler words like \u{201C}um\u{201D} and \u{201C}like\u{201D}.",
                    "First use: a one-time setup of about 1-2 minutes on this \(word)."]
        }
        if model.id == ModelCatalog.defaultPick && withWhisper {
            return ["English and 24 other European languages. The faster of the two, and it writes down more literally what you say."]
        }
        return [model.blurb]
    }

    /// "Only on Whisper: Thai" when this device's language is one Parakeet does not speak.
    static func onlyOnWhisper(language: String = ModelCatalog.currentLanguage) -> String? {
        guard !ModelCatalog.parakeetLanguages.contains(language), let name = Locale.current.localizedString(forLanguageCode: language) else { return nil }
        return "Only on Whisper: \(name)"
    }
}

struct SetupModelCard: View {
    @EnvironmentObject private var models: ModelManager
    let model: SpeechModel
    let recommended: Bool
    let lines: [String]
    var only: String? = nil

    var body: some View {
        let status = models.status[model.id] ?? .notDownloaded
        let chosen = models.activeID == model.id
        VStack(alignment: .leading, spacing: 10) {
            Button { pick(status) } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .medium)).foregroundStyle(chosen ? Palette.brand : Palette.faint).frame(width: 28)
                    MakerMark(model: model, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        if recommended {
                            Text("Recommended").font(FFFont.text(12.5, .medium)).foregroundStyle(Palette.accentText)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Palette.accentSoft, in: Capsule(style: .continuous))
                        }
                        Text(model.engine.isWhisper ? "Whisper large-v3-turbo" : model.name).font(FFFont.text(21, .bold)).foregroundStyle(Palette.fg)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(model.maker) · \(model.downloadBytes.megabytes) download").font(FFFont.text(14, .medium)).foregroundStyle(Palette.faint)
                            .accessibilityIdentifier("setupSize.\(model.id)")
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("select.\(model.id)")
            .accessibilityAddTraits(chosen ? .isSelected : [])
            if let only {
                Label(only, systemImage: "globe").font(FFFont.text(15, .semibold)).foregroundStyle(Palette.accentText)
                    .accessibilityIdentifier("onlyOnWhisper")
            }
            ForEach(lines, id: \.self) { Text($0).font(FFFont.text(15)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            action(status, chosen: chosen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .ffStroke(Radius.card, chosen ? Palette.brand : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.\(model.id)")
        .accessibilityValue(chosen ? "selected" : "not selected")
    }

    @ViewBuilder private func action(_ status: ModelManager.Status, chosen: Bool) -> some View {
        switch status {
        case .notDownloaded:
            Button("Download \(model.downloadBytes.megabytes)") { pick(status); models.setupLanguage(for: model.id); Task { await models.download(model) } }
                .buttonStyle(FFButtonStyle(chosen ? .ember : .secondary))
                .accessibilityIdentifier("download.\(model.id)")
        case .downloading(let p):
            ProgressView(value: p).tint(Palette.brand)
            Text(String(format: "Downloading %.0f%%", p * 100)).font(FFFont.mono(12)).accessibilityIdentifier("progress.\(model.id)")
        case .verifying:
            Text("Checking sha256…").font(FFFont.mono(12))
        case .ready:
            if !chosen {
                Button("Use") { models.choose(model.id) }.buttonStyle(FFButtonStyle(.secondary)).accessibilityIdentifier("use.\(model.id)")
            }
            Text("Downloaded and checked").font(FFFont.mono(12)).foregroundStyle(Palette.ok).accessibilityIdentifier("verified.\(model.id)")
        case .failed(let message):
            Text(message).font(FFFont.text(14, .semibold)).foregroundStyle(Palette.danger)
            Button("Try again") { Task { await models.download(model) } }.buttonStyle(FFButtonStyle(.secondary))
        }
    }

    /// Same rule as the picker: a downloaded model switches at once; one not downloaded becomes the pick while no model
    /// is ready yet (it never takes over from a working one before its download finishes).
    private func pick(_ status: ModelManager.Status) {
        if status == .ready { models.choose(model.id) } else if !models.activeReady { models.activeID = model.id }
        models.setupLanguage(for: model.id)
    }
}

/// One model in the picker: select it, download it, use it, or see why it does not fit.
struct ModelRow: View {
    @EnvironmentObject private var models: ModelManager
    let model: SpeechModel
    let recommended: Bool
    let context: ModelPicker.Context

    var body: some View {
        let status = models.status[model.id] ?? .notDownloaded
        let word = DeviceWord.current
        let tooBig = ModelCatalog.tooBigReason(model, memoryBytes: models.device.memoryBytes, device: word)
        let chosen = tooBig == nil && models.activeID == model.id
        VStack(alignment: .leading, spacing: 10) {
            Button { choose(status) } label: { header(status: status, chosen: chosen, tooBig: tooBig != nil) }
                .buttonStyle(.plain)
                .disabled(tooBig != nil)
                .accessibilityIdentifier("select.\(model.id)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityHint(tooBig != nil ? "Too big for this \(word)" : (status == .ready ? "Uses this model" : "Download it to use it"))
            if recommended, model.engine.isCpp {
                Text("Recommended \(model.quant ?? "file") for this \(word)'s \(DeviceProfile.marketingGB(memoryBytes: models.device.memoryBytes)) GB of memory.")
                    .font(FFFont.text(15, .semibold)).foregroundStyle(Palette.fg)
                    .accessibilityIdentifier("familyReason.\(model.id)")
            } else if recommended {
                Text(ModelCatalog.reason(for: model, memoryBytes: models.device.memoryBytes, device: word))
                    .font(FFFont.text(15, .semibold)).foregroundStyle(Palette.fg)
                    .accessibilityIdentifier("recommendReason")
            }
            Text(model.blurb).font(FFFont.text(15)).foregroundStyle(Palette.muted)
            if let tooBig {
                Label("Too big for this \(word)", systemImage: "memorychip")
                    .font(FFFont.text(15, .semibold)).foregroundStyle(Palette.warn)
                    .accessibilityIdentifier("tooBig.\(model.id)")
                Text(tooBig).font(FFFont.text(14)).foregroundStyle(Palette.muted)
            } else {
                measured
                health(word: word)
                action(status, chosen: chosen)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .ffStroke(Radius.card, chosen ? Palette.brand : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.\(model.id)")
        .accessibilityValue(tooBig != nil ? "too big" : (chosen ? "selected" : "not selected"))
    }

    @ViewBuilder private func pills(status: ModelManager.Status, chosen: Bool) -> some View {
        tag(model.quant ?? model.tier.title, fill: Palette.panel, ink: Palette.muted)
        if recommended { tag("Recommended", fill: Palette.accentSoft, ink: Palette.accentText) }
        if chosen, status == .ready { tag("In use", fill: Palette.panel, ink: Palette.ok) }
    }

    private func header(status: ModelManager.Status, chosen: Bool, tooBig: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: tooBig ? "nosign" : (chosen ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(chosen ? Palette.brand : Palette.faint)
                .frame(width: 28)
            MakerMark(model: model, size: recommended ? 34 : 30).opacity(tooBig ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 4) {
                // Pills never wrap inside: one line if they fit, else one under another (SE / mini widths).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { pills(status: status, chosen: chosen) }
                    VStack(alignment: .leading, spacing: 4) { pills(status: status, chosen: chosen) }
                }
                Text(model.name).font(FFFont.text(recommended ? 21 : 18, .bold))
                    .foregroundStyle(tooBig ? Palette.faint : Palette.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.engine.isCpp ? "\(model.downloadBytes.megabytes) download · \(model.runtime)"
                                        : "\(model.maker) · \(model.downloadBytes.megabytes) download · \(model.languages)")
                    .font(FFFont.text(14, .medium)).foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// Only real numbers: a quality figure measured on this exact file (from the catalog), and the speed this
    /// device measured itself on earlier dictations.
    @ViewBuilder private var measured: some View {
        if let quality = model.quality {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.engine.isCpp {
                    tag(quality.label, fill: Palette.panel, ink: quality.isVendor ? Palette.muted : Palette.ok)
                        .accessibilityIdentifier("qualitySource.\(model.id)")
                }
                Text(quality.line).font(FFFont.text(14)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("quality.\(model.id)")
        }
        if model.engine.isCpp, let peak = model.peakMemoryLine {
            Text(peak).font(FFFont.text(14)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("peak.\(model.id)")
        }
        if let line = models.measured(model.id)?.line(device: DeviceWord.current) {
            Text(line).font(FFFont.mono(12.5)).foregroundStyle(Palette.muted)
                .accessibilityIdentifier("measured.\(model.id)")
        }
    }

    /// C++ models: "won't run well" from memory iOS still lets the app use (os_proc_available_memory, on a device)
    /// against the measured peak, and from this device's own measured speed. Only measured inputs decide. The loaded
    /// model's own memory counts as free: using another model (or this one) unloads it first.
    @ViewBuilder private func health(word: String) -> some View {
        if model.engine.isCpp,
           case .wontRunWell(let why) = ModelCatalog.runHealth(model, availableBytes: models.availableMemory,
                                                              loadedBytes: models.loadedModelBytes,
                                                              probeSpeed: models.measured(model.id)?.median) {
            Label("Won't run well on this \(word)", systemImage: "exclamationmark.triangle")
                .font(FFFont.text(15, .semibold)).foregroundStyle(Palette.warn)
                .accessibilityIdentifier("wontRunWell.\(model.id)")
            Text(why).font(FFFont.text(14)).foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder
    private func action(_ status: ModelManager.Status, chosen: Bool) -> some View {
        switch status {
        case .notDownloaded:
            Button("Download \(model.downloadBytes.megabytes)") { Task { await models.download(model) } }
                .buttonStyle(FFButtonStyle(chosen ? .ember : .secondary))
                .accessibilityIdentifier("download.\(model.id)")
        case .downloading(let p):
            ProgressView(value: p).tint(Palette.brand)
            Text(String(format: "Downloading %.0f%%", p * 100)).font(FFFont.mono(12)).accessibilityIdentifier("progress.\(model.id)")
        case .verifying:
            Text("Checking sha256…").font(FFFont.mono(12))
        case .ready:
            HStack(spacing: 10) {
                if models.activeID != model.id {
                    Button("Use") { models.choose(model.id) }.buttonStyle(FFButtonStyle(.secondary))
                        .accessibilityIdentifier("use.\(model.id)")
                }
                if context == .settings {
                    Button("Delete") { Task { await models.delete(model) } }.buttonStyle(FFButtonStyle(.danger))
                }
                Spacer(minLength: 0)
            }
            Text("Every file matched its sha256 · pinned revision \(models.revision(model.id))")
                .font(FFFont.mono(12)).foregroundStyle(Palette.ok).accessibilityIdentifier("verified.\(model.id)")
        case .failed(let message):
            Text(message).font(FFFont.text(14, .semibold)).foregroundStyle(Palette.danger)
            Button("Try again") { Task { await models.download(model) } }.buttonStyle(FFButtonStyle(.secondary))
        }
    }

    /// A downloaded model switches at once; one not yet downloaded becomes the pick only while no model is ready
    /// (it never takes over from a working one before its download finishes).
    private func choose(_ status: ModelManager.Status) {
        if status == .ready { models.choose(model.id) } else if !models.activeReady { models.activeID = model.id }
    }

    /// MBX tag: filled pill, no stroke.
    private func tag(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text).font(FFFont.text(12.5, .medium)).foregroundStyle(ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(fill, in: Capsule(style: .continuous))
    }
}

/// A maker's logo in the Models filter (build 23): the app's logo asset for that maker in a small rounded square, else a
/// neutral circle with the maker's initial (never a made-up logo).
struct MakerChipLogo: View {
    let maker: String
    var size: CGFloat = 20
    var body: some View {
        if let asset = MakerLogo.asset(forMaker: maker) {
            Image(asset).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Text(String(maker.prefix(1))).font(FFFont.text(size * 0.55, .bold)).foregroundStyle(Palette.muted)
                .frame(width: size, height: size).background(Palette.panel, in: Circle()).accessibilityHidden(true)
        }
    }
}

/// The maker's logo from the in-app credits set, or the MASHBOX mark for our own models.
struct MakerMark: View {
    let model: SpeechModel
    var size: CGFloat = 30
    var body: some View {
        if let logo = model.makerLogo {
            MakerLogo(asset: logo, size: size)
        } else if model.maker.hasPrefix("MASHBOX") {
            BrandMark(withSound: false).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: "waveform").font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(Palette.faint).frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

