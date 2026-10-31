import FreeFlowKit
import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject private var store: DictionaryStore
    @State private var word = ""
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                Text("Add names and words you say. The Core ML models lean toward them while they listen, on this device. Just the word, spelled your way.")
                    .font(FFFont.text(15)).foregroundStyle(Palette.muted)
                Text("The C++ models don't use the dictionary yet.")
                    .font(FFFont.text(14)).foregroundStyle(Palette.faint)
                TextField("Word, e.g. MASHBOX", text: $word).font(FFFont.text(17)).focused($focused).accessibilityIdentifier("dictWord")
                Button("Add word") {
                    store.add(word: word)
                    word = ""; focused = false
                }
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("dictAdd")
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            Section("Your words") {
                if store.entries.isEmpty { Text("No words yet.").foregroundStyle(Palette.faint) }
                ForEach(store.entries) { e in
                    Text(e.word).font(FFFont.text(18, .bold))
                }
                .onDelete { idx in store.remove(Set(idx.map { store.entries[$0].id })) }
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .navigationTitle("Dictionary")
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: HistoryStore
    @ObservedObject private var clips = ClipStore.shared
    @AppStorage(ClipRetention.key) private var retentionDays = ClipRetention.standard.rawValue
    @State private var confirmClear = false
    @State private var open: Set<UUID> = []

    var body: some View {
        List {
            Section {
                Text("Text is stored only on this device and left out of iCloud backups.")
                    .font(FFFont.text(15)).foregroundStyle(Palette.muted)
            }
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            if !clips.clips.isEmpty {
                Section {
                    ForEach(clips.clips) { ClipRow(clip: $0) }
                } header: {
                    Text("Recent recordings").ffEyebrow().accessibilityIdentifier("recentHeader")
                } footer: {
                    Text("Recordings that didn't finish: a call, an X tap or Free Flow closing. They stay on this device and out of backups, \(ClipRetention.stored(retentionDays).until).")
                        .font(FFFont.text(14))
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
            }
            if store.items.isEmpty {
                Text("Nothing yet.").foregroundStyle(Palette.faint).listRowSeparator(.hidden)
            }
            ForEach(store.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).font(FFFont.text(17)).lineLimit(open.contains(item.id) ? nil : 4)
                    // Build 18: who wrote it; tap the row for what the speech model heard.
                    if let writer = item.writer {
                        Text(writer).font(FFFont.text(13, .semibold)).foregroundStyle(Palette.muted)
                            .accessibilityIdentifier("history.writer")
                    }
                    if open.contains(item.id) {
                        Text("Heard: " + item.raw).font(FFFont.text(15)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("history.heard")
                    }
                    Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f s", item.audioSeconds)) · \(item.model) · \(item.style.pill)")
                        .font(FFFont.text(13)).foregroundStyle(Palette.faint)
                }
                .contentShape(Rectangle())
                .onTapGesture { if open.contains(item.id) { open.remove(item.id) } else { open.insert(item.id) } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(open.contains(item.id) ? "Hides what was heard" : "Shows what was heard")
                .contextMenu { Button("Copy") { UIPasteboard.general.string = item.text } }
            }
            .onDelete { idx in store.remove(Set(idx.map { store.items[$0].id })) }
            .listRowSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .navigationTitle("History")
        .toolbar {
            if !store.items.isEmpty { Button("Clear all", role: .destructive) { confirmClear = true } }
        }
        .confirmationDialog("Delete all history from this device?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { store.clear() }
        }
    }
}

/// One saved recording: what happened, Retry (any downloaded model) and Delete.
struct ClipRow: View {
    let clip: Clip
    @EnvironmentObject private var engine: DictationEngine
    @EnvironmentObject private var models: ModelManager

    private var busy: Bool { engine.retryingID != nil || engine.phase == .listening || engine.phase == .transcribing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(clip.label).font(FFFont.text(16, .bold)).accessibilityIdentifier("clip.status")
                Spacer()
                Text(clip.duration).font(FFFont.mono(13)).foregroundStyle(Palette.muted)
            }
            Text(clip.createdAt.formatted(date: .abbreviated, time: .shortened) + (clip.model.map { " · " + $0 } ?? ""))
                .font(FFFont.text(13)).foregroundStyle(Palette.faint)
            if let why = clip.whyStopped, why != clip.label {
                Text("Why it stopped: " + why).font(FFFont.text(13)).foregroundStyle(Palette.muted).accessibilityIdentifier("clip.why")
            }
            if let text = clip.text, !text.isEmpty {
                Text(text).font(FFFont.text(17)).textSelection(.enabled).accessibilityIdentifier("clip.text")
            }
            if let written = clip.written, !written.isEmpty {
                Text("Apple Intelligence's version (not used):").font(FFFont.text(13)).foregroundStyle(Palette.muted)
                Text(written).font(FFFont.text(15)).foregroundStyle(Palette.muted).textSelection(.enabled).accessibilityIdentifier("clip.written")
            }
            HStack(spacing: 10) {
                if engine.retryingID == clip.id {
                    ProgressView().tint(Palette.brand)
                    Text("Transcribing").font(FFFont.text(15, .semibold)).foregroundStyle(Palette.muted)
                } else {
                    retry
                    if let text = clip.text, !text.isEmpty {
                        Button("Copy") { UIPasteboard.general.string = text }
                            .buttonStyle(FFButtonStyle(.secondary)).accessibilityIdentifier("clip.copy")
                    }
                }
                Spacer()
                Button("Delete", role: .destructive) { ClipStore.shared.delete(clip.id) }
                    .buttonStyle(FFButtonStyle(.danger)).disabled(engine.retryingID == clip.id)
                    .accessibilityIdentifier("clip.delete")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.row")
    }

    /// Build 23: Retry uses the model picked in Models (in use, or loading now), never a choice of models.
    @ViewBuilder private var retry: some View {
        Button("Retry") { Task { await engine.retry(clip.id) } }
            .buttonStyle(FFButtonStyle(.secondary))
            .disabled(busy || !models.activeReady || !clip.canRetry).accessibilityIdentifier("clip.retry")
    }
}
