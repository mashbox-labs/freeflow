// Test builds only (security): never in a Release or notarized app.
#if DEBUG || FF_TESTS
import AppKit
import FreeFlowKit
import SwiftUI

/// Checks that run the real app code without a microphone, Accessibility or any window on screen (for the build Mac,
/// where nobody grants permissions). Only with FF_MAC_TEST=1 in the environment:
///   --selftest <audio file>   every model file against its pinned sha256, then the dictation pipeline on the file:
///                             Parakeet (Core ML) -> dictionary -> writing model for each style. Prints FFMAC lines.
///   --shots <folder>          renders the setup window and each pill look, light and dark, to PNG files.
///   --download <id,id>        downloads models through the app's own path (pinned Hugging Face commit, every file
///                             against its pinned sha256, put in place only when all match): the fresh-install check.
///   --mictest <s> [--switch]  the real microphone path (MicTest.swift).
enum SelfTest {
    enum Mode { case pipeline(String), shots(String), download([String]), mic(Double, Bool) }

    static func mode() -> Mode? {
        guard ProcessInfo.processInfo.environment["FF_MAC_TEST"] == "1" else { return nil }
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--selftest"), i + 1 < a.count { return .pipeline(a[i + 1]) }
        if let i = a.firstIndex(of: "--shots"), i + 1 < a.count { return .shots(a[i + 1]) }
        if let i = a.firstIndex(of: "--download"), i + 1 < a.count { return .download(a[i + 1].split(separator: ",").map(String.init)) }
        if let i = a.firstIndex(of: "--mictest"), i + 1 < a.count, let s = Double(a[i + 1]) { return .mic(s, a.contains("--switch")) }
        return nil
    }

    @MainActor
    static func run(_ mode: Mode) async -> Int32 {
        switch mode {
        case .pipeline(let file): return await pipeline(file)
        case .shots(let dir): return shots(dir)
        case .download(let ids): return await download(ids)
        case .mic(let seconds, let switching): return await MicTest.run(seconds: seconds, switching: switching)
        }
    }

    static func say(_ s: String) { print("FFMAC " + s); fflush(stdout) }

    @MainActor
    static func pipeline(_ file: String) async -> Int32 {
        let models = MacModels.shared
        var ok = true
        say("writer: " + (WriterChoice.resolved == .off ? "off" : MacWriter.check.available ? "Apple Intelligence available" : "Apple Intelligence not available: " + (MacWriter.check.reason ?? "")))
        for id in [MacModels.speechID] {
            let start = Date()
            if let problem = MacModels.check(id, manifest: models.manifest) {
                say("model \(id) NOT READY: \(problem)")
                if id == MacModels.speechID { ok = false }
            } else {
                models.markChecked(id)
                say(String(format: "model %@ sha256 OK (%d files, %.1f s)", id, models.manifest[id]?.files.count ?? 0, Date().timeIntervalSince(start)))
            }
        }
        guard ok else { return 1 }
        let samples: [Float]
        do { samples = try AudioCapture.read(URL(fileURLWithPath: file)) } catch {
            say("audio read failed: \(error.localizedDescription)"); return 1
        }
        say(String(format: "audio %.1f s at 16 kHz", Double(samples.count) / AudioCapture.rate))
        do {
            let load = try await MacTranscriber.shared.load()
            let t0 = Date()
            let raw = try await MacTranscriber.shared.transcribe(samples, words: ["MASHBOX"])
            say(String(format: "parakeet load %.2f s, transcribe %.2f s", load, Date().timeIntervalSince(t0)))
            say("heard: " + raw)
            let heard = DictationText.finish(raw)
            for style in DictationStyle.allCases {
                let w = await MacWriter.write(heard, style: style)
                say("\(style.rawValue): " + w.text)
                say("\(style.rawValue) readout: " + w.readout.line)
                say("\(style.rawValue) short: " + w.readout.short)
            }
            // The switch off: no model is called, the words go in as heard, and the line says so.
            let before = WriterChoice.stored
            WriterChoice.stored = .off
            let off = await MacWriter.write(heard, style: .formal)
            WriterChoice.stored = before
            say("off: " + off.text)
            say("off short: " + off.readout.short)
        } catch {
            say("pipeline failed: \(error.localizedDescription)"); return 1
        }
        say("paste key for v: \(TextInserter.keyCode(for: "v").map(String.init) ?? "none")")
        var g = FnGesture()
        let hold = [g.fnPressed(at: 0), g.fnReleased(at: 1)]
        say("fn hold -> \(hold)")
        say("selftest done")
        return 0
    }

    @MainActor
    static func download(_ ids: [String]) async -> Int32 {
        let models = MacModels.shared
        var ok = true
        for id in ids {
            let start = Date()
            say("download \(id): \(MacModels.size(models.bytes(id))) from \(models.manifest[id].map { $0.repo + "@" + String($0.revision.prefix(8)) } ?? "not in the manifest")")
            let done = await models.download(id)
            if done, MacModels.check(id, manifest: models.manifest) == nil {
                say(String(format: "download %@ OK in %.1f s; every file matches its pinned sha256", id, Date().timeIntervalSince(start)))
            } else {
                ok = false
                if case .failed(let why) = models.status[id] { say("download \(id) FAILED: \(why)") } else { say("download \(id) FAILED") }
            }
        }
        return ok ? 0 : 1
    }

    @MainActor
    static func shots(_ dir: String) -> Int32 {
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dictation = MacDictation.shared
        var written = 0
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let setup = SetupModel()
            let view = SetupView(setup: setup, models: MacModels.shared, dictation: dictation, dictionary: dictation.dictionary)
                .environment(\.colorScheme, scheme)
            // The setup window is a ScrollView, which ImageRenderer leaves blank: draw it in a real (offscreen) window.
            if saveWindow(view, size: NSSize(width: 540, height: 1180), appearance: appearance,
                          to: folder.appendingPathComponent("setup-\(name).png")) { written += 1 }
            let looks: [(PillLook, String, [Float])] = [
                (.listening, "listening", [0.9, 0.75, 0.55, 0.62, 0.4, 0.3, 0.2, 0.1]),
                (.listening, "quiet", [0.05, 0.04, 0.03, 0.02, 0.02, 0.01, 0, 0]),
                (.handsFree, "handsfree", [0.7, 0.8, 0.5, 0.35, 0.45, 0.25, 0.15, 0.1]),
                (.working, "working", []),
                (.message("Copied. Press ⌘V to paste"), "message", []),
            ]
            for (look, label, levels) in looks {
                let m = PillModel()
                m.look = look
                m.visible = true
                if !levels.isEmpty { m.levels = levels }
                let backdrop = scheme == .dark ? Color(hex: 0x2B2622) : Color(hex: 0xDCD5C7)
                let pill = PillView(model: m).background(backdrop).environment(\.colorScheme, scheme)
                if save(pill, appearance: appearance, to: folder.appendingPathComponent("pill-\(label)-\(name).png")) { written += 1 }
            }
        }
        say("shots \(written) written to \(dir)")
        return written == 12 ? 0 : 1
    }

    @MainActor
    static func save<V: View>(_ view: V, appearance: NSAppearance?, to url: URL) -> Bool {
        var result = false
        let draw = {
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let cg = r.cgImage else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            result = SelfTest.write(rep, to: url)
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
        return result
    }

    /// Draws `view` the way the app shows it, in an NSHostingView in a borderless window that is never put on screen.
    @MainActor
    static func saveWindow<V: View>(_ view: V, size: NSSize, appearance: NSAppearance?, to url: URL) -> Bool {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // one pass for SwiftUI's state and layout
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return write(rep, to: url)
    }

    /// Writes the PNG only when the picture has something in it: a shot whose sampled pixels all match its top-left
    /// pixel rendered nothing, and counts as a failed shot (written as name.blank.png to look at).
    static func write(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let first = rep.colorAt(x: 0, y: 0)
        var drawn = false
        outer: for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 5) where rep.colorAt(x: x, y: y) != first { drawn = true; break outer }
        }
        if !drawn {
            say("shot \(url.lastPathComponent) is blank (one colour)")
            try? png.write(to: url.deletingPathExtension().appendingPathExtension("blank.png"))
            return false
        }
        return (try? png.write(to: url)) != nil
    }
}
#endif
