import XCTest
@testable import FreeFlowKit

final class AudioSessionSetupTests: XCTestCase {
    private final class Fake: AudioSessionConfiguring {
        var calls: [String] = []
        func ffSetPlayAndRecord(mixWithOthers: Bool, duckOthers: Bool, bluetoothMic: Bool) throws {
            calls.append("category"); if bluetoothMic { calls.append("hfp") }
        }
        func ffSetAllowHapticsWhileRecording(_ on: Bool) throws { calls.append("haptics=\(on)") }
        func ffSetPrefersNoInterruptionsFromSystemAlerts(_ on: Bool) throws { calls.append("alerts=\(on)") }
        func ffSetActive(_ on: Bool) throws { calls.append("active=\(on)") }
    }

    /// Build 5: the key click went quiet soon after the first dictation (2026-10-29). The app keeps its mic session
    /// recording for the whole "Keep the mic ready" window, and iOS mutes haptics while audio input records unless
    /// the session allows them. Allowed after the category (AVFoundation refuses it before a recording category),
    /// before the session goes active.
    func testKeyClicksStayOnWhileTheMicIsReady() throws {
        let f = Fake()
        try AudioSessionSetup.configure(f, mixWithOthers: true, duckOthers: false)
        let h = f.calls.firstIndex(of: "haptics=true")
        XCTAssertNotNil(h, "haptics allowed while recording: \(f.calls)")
        let c = f.calls.firstIndex(of: "category") ?? -1, a = f.calls.firstIndex(of: "active=true") ?? -1
        XCTAssertTrue(c < (h ?? -2) && (h ?? Int.max) < a, "order: \(f.calls)")
    }
}

final class MicChoiceTests: XCTestCase {
    let builtIn = MicChoice.Input(uid: "builtin", name: "iPad Microphone", isBluetooth: false, isBuiltIn: true)
    let headset = MicChoice.Input(uid: "bt-1", name: "Headset", isBluetooth: true, isBuiltIn: false)
    let usb = MicChoice.Input(uid: "usb-1", name: "USB Mic", isBluetooth: false, isBuiltIn: false)

    /// Built-in is the default and the session stays A2DP (no hands-free) unless a Bluetooth mic is picked.
    func testBuiltInIsTheDefaultAndKeepsFullQualityPlayback() throws {
        XCTAssertEqual(MicChoice.preferred(saved: "", available: [headset, builtIn, usb]), builtIn)
        XCTAssertFalse(MicChoice.needsHandsFree(saved: "", savedIsBluetooth: false))
        let f = Fake()
        try AudioSessionSetup.configure(f, mixWithOthers: true, duckOthers: false)
        XCTAssertFalse(f.calls.contains("hfp"), "\(f.calls)")
    }

    func testABluetoothMicAddsHandsFree() throws {
        XCTAssertTrue(MicChoice.needsHandsFree(saved: "bt-1", savedIsBluetooth: true))
        XCTAssertFalse(MicChoice.needsHandsFree(saved: "usb-1", savedIsBluetooth: false))
        let f = Fake()
        try AudioSessionSetup.configure(f, mixWithOthers: true, duckOthers: false, bluetoothMic: true)
        XCTAssertTrue(f.calls.contains("hfp"), "\(f.calls)")
    }

    func testAPickNotConnectedFallsBackToBuiltIn() {
        XCTAssertEqual(MicChoice.preferred(saved: "bt-1", available: [builtIn]), builtIn)
        XCTAssertEqual(MicChoice.preferred(saved: "bt-1", available: [builtIn, headset]), headset)
    }

    func testRowsListBuiltInFirstThenEveryInputOnceThenTheSavedPick() {
        let rows = MicChoice.rows(available: [headset, builtIn, usb, headset], saved: "gone", savedName: "Old Headset")
        XCTAssertEqual(rows.map(\.tag), ["", "bt-1", "usb-1", "gone"])
        XCTAssertEqual(rows.first?.title, MicChoice.builtInTitle)
        XCTAssertEqual(rows.last?.title, "Old Headset (not connected)")
    }

    func testNoteSaysCallQualityAndSlowerPlainly() {
        XCTAssertTrue(MicChoice.note.contains("call-quality"))
        XCTAssertTrue(MicChoice.note.contains("longer to start"))
        XCTAssertNil(MicChoice.note.range(of: "AirPods"), "never names one headset")
        for glyph in ["\u{2014}", "\u{2013}"] { XCTAssertFalse(MicChoice.note.contains(glyph)) }
    }

    private final class Fake: AudioSessionConfiguring {
        var calls: [String] = []
        func ffSetPlayAndRecord(mixWithOthers: Bool, duckOthers: Bool, bluetoothMic: Bool) throws {
            calls.append("category"); if bluetoothMic { calls.append("hfp") }
        }
        func ffSetAllowHapticsWhileRecording(_ on: Bool) throws {}
        func ffSetPrefersNoInterruptionsFromSystemAlerts(_ on: Bool) throws {}
        func ffSetActive(_ on: Bool) throws {}
    }
}

final class KeyClickCountsTests: XCTestCase {
    func testCountsSayWhyThereWasNoClick() {
        var c = KeyClickCounts()
        c.note(fullAccess: false, clicksOff: false, micReady: false)
        c.note(fullAccess: true, clicksOff: true, micReady: false)
        c.note(fullAccess: true, clicksOff: false, micReady: true)
        c.note(fullAccess: true, clicksOff: false, micReady: false)
        XCTAssertEqual([c.presses, c.noAccess, c.off, c.asked, c.askedWhileMic], [4, 1, 1, 2, 1])
        XCTAssertEqual(c.summary, "4 key presses, 2 clicks asked of iOS (1 while the mic was ready), 1 with no Full Access seen, 1 with clicks off.")
        var all = KeyClickCounts(); all.add(c); all.add(c)
        XCTAssertEqual(all.presses, 8)
        XCTAssertEqual(all.since, c.since)
    }
}
