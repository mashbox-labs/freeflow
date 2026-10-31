// Test builds only (security): never in a Release or notarized app.
#if targetEnvironment(macCatalyst) && (DEBUG || FF_TESTS)
import AVFAudio
import FreeFlowKit
import Foundation
import UIKit

/// Tests of the Mac app as it ships, run from the signed app with `open` so its own microphone and Accessibility
/// grants apply (FF_MAC_TEST=1). Each prints "FFMAC ..." lines and exits with 0 when it passed.
/// --download                 the recommended speech model into this home
/// --mictest <s> [--switch]   the real microphone through the iPhone engine's capture for s seconds; with --switch the
///                            default input moves to another device 2 s in and back 2 s later (build 19's rule)
/// --fntest <s> [--notes]     fn held for s seconds in TextEdit and Safari (and Notes with --notes) on a file feed
///                            (FF_AUDIO_FILE): the text must land in the field in front
/// --stay <s>                 stays up s seconds, then quits (screenshots are taken from outside)
@MainActor
enum MacTests {
    static func say(_ line: String) {
        print("FFMAC " + line)
        fflush(stdout)
    }

    static func runIfAsked(_ host: MacHost) {
        guard ProcessInfo.processInfo.environment["FF_MAC_TEST"] == "1" else { return }
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // the window and the plug-in settle first
            var rc: Int32 = 3
            if args.contains("--download") { rc = await download() }
            else if let s = value(after: "--mictest") { rc = await micTest(host, seconds: s, switching: args.contains("--switch")) }
            else if let s = value(after: "--fntest") { rc = await fnTest(host, seconds: s, notes: args.contains("--notes")) }
            else if let i = args.firstIndex(of: "--switchtest"), i + 1 < args.count { rc = await DictationEngine.shared.runSwitchTest(args[i + 1]) }
            else if let s = value(after: "--stay") { rc = await stay(seconds: s) }
            else { say("no test named") }
            say("RC=\(rc)")
            exit(rc)
        }
    }

    /// Stays up, and with FF_MAC_SNAP=<png> draws the window's own content into that file after 4 s (what the app
    /// draws, whatever the display is doing).
    static func stay(seconds: Double) async -> Int32 {
        var rc: Int32 = 0
        if let path = ProcessInfo.processInfo.environment["FF_MAC_SNAP"] {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            if let w = windows.first(where: \.isKeyWindow) ?? windows.first {
                let image = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
                try? image.pngData()?.write(to: URL(fileURLWithPath: path))
                say("snap \(path) \(Int(w.bounds.width))x\(Int(w.bounds.height))")
            } else { say("snap: no window"); rc = 1 }
        }
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds - 4) * 1_000_000_000))
        return rc
    }

    static func download() async -> Int32 {
        let models = ModelManager.shared
        let model = models.recommended
        say("downloading \(model.name) (\(models.downloadBytes(model.id) >> 20) MB)")
        await models.download(model)
        say("active \(models.activeID) ready=\(models.activeReady)")
        return models.activeReady ? 0 : 1
    }

    static func micTest(_ host: MacHost, seconds: Double, switching: Bool) async -> Int32 {
        let engine = DictationEngine.shared
        guard AVAudioApplication.shared.recordPermission == .granted else { say("mic: not allowed for this app"); return 2 }
        guard ModelManager.shared.activeReady else { say("speech model not ready in this home"); return 2 }
        say("default input: " + host.micName)
        defer { say("default input at exit: " + host.restoreInput()) }
        var changes = 0, routes = 0
        let c1 = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in changes += 1 }
        let c2 = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in routes += 1 }
        defer { NotificationCenter.default.removeObserver(c1); NotificationCenter.default.removeObserver(c2) }
        await engine.startDictation(target: .fn)
        guard engine.phase == .listening else { say("capture did not start: \(engine.errorText ?? "")"); return 1 }
        say("input route: " + AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", "))
        var growth: [Int] = [], zeroHalves: [Bool] = [], levels: [String] = [], last = 0
        for i in 0..<Int(seconds * 2) {
            if switching, i == 4 {
                let other = host.switchInput()
                say(other.isEmpty ? "t=2.0 s no other input device to switch to" : "t=2.0 s default input -> " + other)
            }
            if switching, i == 8 { say("t=4.0 s default input -> " + host.restoreInput()) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let n = engine.capture.collectedCount
            let l = engine.capture.level(from: last)
            levels.append(String(format: "%.4f/%d", l.rms, l.zeros))
            zeroHalves.append(n - last == 0 || l.zeros == n - last)   // nothing came, or only exact zeros
            growth.append(n - last); last = n
            if switching, i == 5 || i == 9 {
                say("t=\(Double(i + 1) / 2) s input route: " + AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", "))
            }
        }
        let recorded = Double(last) / AudioCapture.rate
        let text = await engine.finishDictation()
        say("samples per 0.5 s: " + growth.map(String.init).joined(separator: " "))
        say("rms/exact-zero samples per 0.5 s: " + levels.joined(separator: " "))
        say(String(format: "recorded %.2f s of %.2f s, capture restarts %d, engine configuration changes %d, route changes %d",
                   recorded, seconds, engine.micRestarts, changes, routes))
        say("heard (\(text.split(whereSeparator: \.isWhitespace).count) words): " + (text.isEmpty ? (engine.errorText ?? "") : text))
        // A half-second of nothing but exact zeros is no audio too (build 19's rule: levels as measured).
        let gaps = zeroHalves.dropFirst().filter { $0 }.count
        say("half-seconds with no audio (none, or only exact zeros) after the first: \(gaps)")
        return gaps == 0 && recorded > seconds - 1.0 ? 0 : 1
    }

    /// fn held for `seconds` in each app, as a person would: the field must hold the dictated text afterwards.
    static func fnTest(_ host: MacHost, seconds: Double, notes: Bool) async -> Int32 {
        host.refresh()
        guard host.accessibility else { say("Accessibility is off for this app: fn and paste can't work"); return 2 }
        guard ModelManager.shared.activeReady else { say("speech model not ready in this home"); return 2 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fntest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let txt = dir.appendingPathComponent("fntest.txt"); try? Data().write(to: txt)
        let html = dir.appendingPathComponent("fntest.html")
        try? Data("<!doctype html><title>fn test</title><textarea autofocus style=\"width:90%;height:60%\"></textarea>".utf8).write(to: html)
        var targets: [(String, String, String)] = [("TextEdit", "com.apple.TextEdit", txt.path), ("Safari", "com.apple.Safari", html.path)]
        if notes { targets.append(("Notes", "com.apple.Notes", "")) }
        var failed = 0
        for (name, app, path) in targets {
            host.testOpen(path, app)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let before = host.focusedText()
            host.postFn(true)
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.5) * 1_000_000_000))
            host.postFn(false)
            var after = before
            for _ in 0..<60 {   // up to 30 s for the transcription, the writer and the paste
                try? await Task.sleep(nanoseconds: 500_000_000)
                after = host.focusedText()
                if after != before { break }
            }
            let added = after.count > before.count ? String(after.dropFirst(before.count)) : ""
            let ok = !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && added.contains(host.lastInserted.prefix(20))
            if !ok { failed += 1 }
            say("\(name): \(ok ? "landed" : "NOT landed") (\(added.count) characters): " + added)
        }
        return failed == 0 ? 0 : 1
    }
}
#endif
