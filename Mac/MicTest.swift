// Test builds only (security): never in a Release or notarized app.
#if DEBUG || FF_TESTS
import CoreAudio
import Foundation
import FreeFlowKit

/// FF_MAC_TEST=1 --mictest <seconds> [--switch]: the real microphone path, as fn uses it (MacDictation.start, the
/// capture on the default input, its device-change restart), without fn, a paste or a window. With --switch, the
/// system's default input moves to another input device (the built-in mic, or from it a Bluetooth or USB one; never an
/// iPhone's) 2 s in and back 2 s later (what a headset joining or leaving
/// does), and is put back as it was on every exit. Prints how many samples arrived in each half second, how many times
/// the capture restarted, and what Parakeet heard. Run it from the signed app with `open` so macOS applies the app's
/// own microphone permission. Build 19 (a pair of AirPods stopped every recording after 0.1 s).
enum MicTest {
    @MainActor
    static func run(seconds: Double, switching: Bool) async -> Int32 {
        let say = SelfTest.say
        let d = MacDictation.shared
        guard MacDictation.micAllowed else { say("mic: not allowed for this process"); return 2 }
        guard MacModels.shared.speechReady else { say("speech model not ready in this home"); return 2 }
        let original = AudioDevices.defaultInput()
        say("default input: " + AudioDevices.name(original))
        defer {
            if AudioDevices.defaultInput() != original { AudioDevices.setDefaultInput(original) }
            say("default input at exit: " + AudioDevices.name(AudioDevices.defaultInput()))
        }
        d.start(handsFree: true)
        guard d.phase == .handsFree else { say("capture did not start (phase \(d.phase))"); return 1 }
        var growth: [Int] = [], last = 0
        let steps = Int(seconds * 2)
        for i in 0..<steps {
            if switching, i == 4 {
                if let other = AudioDevices.switchTarget(from: original) {
                    AudioDevices.setDefaultInput(other)
                    say("t=2.0 s default input -> " + AudioDevices.name(other))
                } else { say("t=2.0 s no other input device to switch to") }
            }
            if switching, i == 8 {
                AudioDevices.setDefaultInput(original)
                say("t=4.0 s default input -> " + AudioDevices.name(original))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let n = d.capture.collectedCount
            growth.append(n - last); last = n
        }
        let audio = d.capture.end()
        d.cancel(reason: "mictest")
        let rms = sqrt(audio.reduce(0) { $0 + $1 * $1 } / Float(max(audio.count, 1)))
        say("samples per 0.5 s: " + growth.map(String.init).joined(separator: " "))
        say(String(format: "recorded %.2f s of %.2f s, rms %.4f, capture restarts %d", Double(audio.count) / AudioCapture.rate, seconds, rms, d.micRestarts))
        do {
            let heard = DictationText.finish(try await MacTranscriber.shared.transcribe(audio, words: []))
            say("heard (\(WritingReadout.words(heard)) words): " + heard)
        } catch { say("transcribe failed: \(error.localizedDescription)") }
        let gaps = growth.dropFirst().filter { $0 == 0 }.count
        say("half-seconds with no audio after the first: \(gaps)")
        return gaps == 0 && Double(audio.count) / AudioCapture.rate > seconds - 1.0 ? 0 : 1
    }
}
#endif
