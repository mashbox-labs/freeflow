import AVFAudio
import FreeFlowKit
import SwiftUI

struct PrivacyView: View {
    @AppStorage(ClipRetention.key) private var retentionDays = ClipRetention.standard.rawValue
    @ObservedObject private var clips = ClipStore.shared
    @State private var confirmDelete = false

    var body: some View {
        Page {
            Text("FREE FLOW SENDS NOTHING OF YOURS").font(FFFont.display(34))
            point("mic", "Your voice", "Audio is turned into text on this device by the model you downloaded. While you dictate, Free Flow also writes the audio to its own private folder on this device, so a call, an X tap or Free Flow closing can't lose it. Your audio stays on this device: Free Flow never sends it anywhere, and it is left out of iCloud and device backups.")
            point("waveform", "When audio is deleted", LastDictation.keepAudio ? "When a dictation finishes, its audio stays on this device for 10 minutes, or until your next dictation, whichever comes first, so you can Retry it in History (with another model or language). Then it is deleted. A recording" : "When a dictation finishes, its audio is deleted at once. A recording that didn't finish waits in History under Recent recordings, so you can transcribe it again, \(ClipRetention.stored(retentionDays).until). Change how long in Settings > Privacy.")
            recordingsCard
            point("text.alignleft", "Your text", "History and your dictionary are kept on this device, and Free Flow never sends them anywhere. History is left out of iCloud and device backups; your dictionary is not. Delete either any time.")
            point("person.crop.circle.badge.xmark", "No account, no tracking", "No sign-in, no analytics, no ads, no crash reporting. Free Flow never sends your audio, your text or anything it keeps on this device.")
            point("chart.bar", "Your stats", "Word counts, days and timings are worked out and kept on this device, never your words or audio. Nothing compares you with anyone else, because Free Flow collects no one's data. Reset them in Settings.")
            point("arrow.down.circle", "One kind of network request", "Tapping Download fetches a model's files from Hugging Face, at a version pinned in this build. Each file is checked against its pinned sha256 when it arrives, and the model is installed only if every file matches. That download carries what any download carries (your IP address) and nothing from Free Flow. If a Whisper model's tokenizer files here ever fail to load, WhisperKit fetches the tokenizer from Hugging Face itself, without that check.")
            #if targetEnvironment(macCatalyst)
            point("globe", "Accessibility", "Accessibility lets Free Flow see the fn key and paste your words where your cursor is. Free Flow reads no other keys and keeps no record of what you type. Without it, your words are copied, ready to paste.")
            #else
            point("keyboard", "Allow Full Access", "iOS does not let keyboards use the microphone, so the Free Flow app does the listening. Allow Full Access lets the keyboard ask the app to start and get the text back through a shared folder on this device. The keyboard has no network code and keeps no record of what you type. Without Full Access it still types; the mic key and key haptics need it.")
            #endif
            Link("Privacy policy", destination: URL(string: "https://mashbox.gg/freeflow/privacy")!)
                .font(FFFont.text(17, .bold)).tint(Palette.accentText)
                .accessibilityIdentifier("privacy.policyLink")
        }
        .navigationTitle("Privacy")
    }

    private var recordingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clips.clips.isEmpty ? "No recordings are saved on this device." : "\(clips.clips.count) saved recording\(clips.clips.count == 1 ? "" : "s") on this device.")
                .font(FFFont.text(16)).foregroundStyle(Palette.muted).accessibilityIdentifier("privacy.recordingsCount")
            Button("Delete all recordings", role: .destructive) { confirmDelete = true }
                .buttonStyle(FFButtonStyle(.danger)).disabled(clips.clips.isEmpty)
                .accessibilityIdentifier("privacy.deleteRecordings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
        .confirmationDialog("Delete all saved recordings from this device?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all recordings", role: .destructive) { ClipStore.shared.deleteAll(except: DictationEngine.shared.recorder.activeID) }
                .accessibilityIdentifier("privacy.deleteRecordings.confirm")
        }
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.brand).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(FFFont.text(19, .bold))
                Text(body).font(FFFont.text(16)).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }
}

struct AboutView: View {
    static let line = "MASHBOX Labs makes open models run faster and cheaper on TPUs and accelerated hardware, as well as exploring the future of the intersection of AI and gaming."
    var body: some View {
        Page {
            BrandMark(withSound: false).frame(width: 84, height: 84).frame(maxWidth: .infinity)
            Text("MASHBOX LABS").font(FFFont.display(40)).frame(maxWidth: .infinity)
            Text(Self.line).font(FFFont.text(19, .semibold)).accessibilityIdentifier("theLine")
            Text("Free Flow is our first app for iPhone, iPad and Mac. It is free, with no ads, no subscriptions and no accounts, and what you say stays on your device.")
                .font(FFFont.text(17)).foregroundStyle(Palette.muted)
            Link("mashbox.gg", destination: URL(string: "https://mashbox.gg")!).font(FFFont.text(17, .bold)).tint(Palette.accentText)
            Link("Privacy policy", destination: URL(string: "https://mashbox.gg/freeflow/privacy")!).font(FFFont.text(17, .bold)).tint(Palette.accentText)
                .accessibilityIdentifier("about.policyLink")
            Link("hello@mashbox.gg", destination: URL(string: "mailto:hello@mashbox.gg")!).font(FFFont.text(17, .bold)).tint(Palette.accentText)
                .accessibilityIdentifier("about.contact")
            Text("Credits").ffEyebrow().padding(.top, 8)
            ForEach(Credits.all, id: \.0) { c in
                HStack(alignment: .top, spacing: 12) {
                    if let logo = Credits.logo(c.0) { MakerLogo(asset: logo, size: 28) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.0).font(FFFont.text(17, .bold))
                        Text(c.1).font(FFFont.text(15)).foregroundStyle(Palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ffCard()
            NavigationLink { WordListNoticesView() } label: {
                Text("Third-party notices").frame(maxWidth: .infinity)
            }
            .buttonStyle(FFButtonStyle(.secondary))
            .accessibilityIdentifier("about.wordListNotices")
            LogoNotice()
        }
        .navigationTitle("About")
    }
}

enum Credits {
    static func logo(_ name: String) -> String? {
        if name.hasPrefix("Parakeet") { return "logo-nvidia" }
        if name == "Model downloads" { return "logo-huggingface" }
        if name == "WhisperKit" || name == "FluidAudio" || name == "llama.cpp and whisper.cpp" { return "logo-github" }
        return nil
    }
    static let all: [(String, String)] = [
        ("Parakeet Ultra and Parakeet Redux", "Moondream, from NVIDIA's Parakeet TDT 0.6B v3. Licensed CC-BY-4.0. Core ML conversions by FluidInference."),
        ("Phonon-2", "Fermion Research, from NVIDIA's Parakeet TDT 0.6B v3. Licensed CC-BY-4.0. Core ML conversion by FluidInference."),
        ("Underdog Bark 3.0 Clean and Bark 3.0 Pro", "Conway Research, from NVIDIA's Parakeet TDT 0.6B v3 and Moondream's Parakeet Ultra. Licensed CC-BY-4.0. Core ML for Bark 3.0 Clean by FluidInference, for Bark 3.0 Pro by Conway Research. Their NOTICE files in full under Third-party notices."),
        ("Parakeet TDT 0.6B v3", "NVIDIA. Licensed CC-BY-4.0. The C++ backup: GGUF files by ggml-org (model card: MIT)."),
        ("llama.cpp and whisper.cpp", "The ggml authors (ggml-org). Licensed MIT. The C++ speech engine."),
        ("FluidAudio", "FluidInference. Licensed Apache-2.0."),
        ("WhisperKit", "Argmax. Licensed MIT."),
        ("Model downloads", "Hugging Face hosts the model files. Each file the Download button fetches is checked against a sha256 pinned in this build."),
        ("Outfit, Geist Mono, Big Shoulders Display, Barlow Semi Condensed", "Fonts licensed under the SIL Open Font License 1.1."),
        ("three.js", "The three.js authors. Licensed MIT. Rendered the eagle in the first-run animation; notice in full under Third-party notices."),
        ("LobeHub Icons", "Model-maker logo images, version 1.97.1. Licensed MIT. Copyright (c) 2023 LobeHub."),
        ("SymSpell frequency_dictionary_en_82_765", "Autocorrect word list. Wolf Garbe. MIT License, Copyright (c) 2018 Wolf Garbe. As packaged in symspellpy 6.10.1 by mmb L: MIT License. Both notices in full under Third-party notices."),
        ("Google Books Ngram data", "Google. This compilation is licensed under a Creative Commons Attribution 3.0 Unported License. SymSpell's word frequencies come from it."),
        ("Spell Checking Oriented Word Lists (SCOWL)", "Copyright 2000-2018 by Kevin Atkinson. SymSpell uses it to keep genuine English words. Full notice under Third-party notices."),
        ("FrequencyWords", "Hermit Dave. Autocorrect word list: en_50k.txt from the 2018 lists, made from OpenSubtitles2018. MIT License for code. CC-by-sa-4.0 for content."),
        ("Free Flow", "MASHBOX Labs. Open source under the Apache License 2.0."),
    ]
}
