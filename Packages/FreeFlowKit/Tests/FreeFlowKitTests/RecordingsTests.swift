import XCTest
@testable import FreeFlowKit

/// Never lose audio: the clip on disk survives an X tap, a call, a crash or a kill, and goes away on time.
final class RecordingsTests: XCTestCase {
    private var folder: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ff-clips-" + UUID().uuidString, isDirectory: true)
    }

    private func store() -> ClipStore { ClipStore(folder: folder, now: { [unowned self] in self.clock }) }
    private func tone(_ n: Int, start: Int = 0) -> [Float] { (0..<n).map { Float(sin(Double($0 + start) * 0.05) * 0.5) } }
    private func fileSize(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 }

    // MARK: The file format

    func testHeaderIsFinalisedOnEveryFlush() throws {
        let s = store()
        let w = try s.begin()
        for i in 1...5 {
            w.append(tone(1_600, start: i * 1_600))
            w.flush()
            let sizes = try XCTUnwrap(WAV.headerSizes(w.url))
            XCTAssertEqual(sizes.data, i * 3_200, "data size after chunk \(i)")
            XCTAssertEqual(sizes.riff, 36 + i * 3_200)
            XCTAssertEqual(fileSize(w.url), WAV.headerBytes + i * 3_200)
        }
    }

    /// While recording, chunks go to disk without touching the header (one write per chunk). A kill at that point
    /// loses nothing: every sample is on disk and the next launch rebuilds the header from the file's length.
    func testChunksReachDiskBeforeTheHeaderAndRecoveryRebuildsIt() throws {
        let s = store()
        let w = try s.begin()
        for i in 0..<10 { w.append(tone(1_600, start: i * 1_600)) }
        w.waitForWrites()
        XCTAssertEqual(fileSize(w.url), WAV.headerBytes + 10 * 3_200, "every chunk is on disk")
        XCTAssertEqual(try XCTUnwrap(WAV.headerSizes(w.url)).data, 0, "the header is not rewritten per chunk")
        XCTAssertEqual(try WAV.read(w.url).count, 16_000)
        let recovered = store().recover()
        XCTAssertEqual(recovered.map(\.id), [w.id])
        XCTAssertEqual(try XCTUnwrap(WAV.headerSizes(w.url)).data, 32_000, "header rebuilt from the bytes on disk")
    }

    func testSamplesRoundTrip() throws {
        let s = store()
        let w = try s.begin()
        let input = tone(8_000)
        w.append(input)
        w.close()
        let back = try WAV.read(w.url)
        XCTAssertEqual(back.count, input.count)
        for i in stride(from: 0, to: input.count, by: 97) { XCTAssertEqual(back[i], input[i], accuracy: 1.0 / 32_000) }
    }

    func testFileCutMidWriteIsRecovered() throws {
        // The app dies part way through a write: the last chunk is half on disk and the header lags or leads.
        let s = store()
        let w = try s.begin()
        w.append(tone(16_000))
        w.append(tone(16_000, start: 16_000))
        w.flush()
        let full = fileSize(w.url)
        let cut = full - 3_001 // odd byte count: ends inside a sample
        let h = try FileHandle(forUpdating: w.url)
        try h.truncate(atOffset: UInt64(cut))
        try h.close()
        XCTAssertGreaterThan(try XCTUnwrap(WAV.headerSizes(w.url)).data, cut - WAV.headerBytes, "header still claims the bytes that were lost")
        let samples = try WAV.read(w.url)
        XCTAssertEqual(samples.count, (cut - WAV.headerBytes) / 2, "every whole sample on disk is read")
        let reopened = store()
        let recovered = reopened.recover()
        XCTAssertEqual(recovered.map(\.id), [w.id])
        XCTAssertEqual(try XCTUnwrap(WAV.headerSizes(w.url)).data, (cut - WAV.headerBytes) / 2 * 2, "header rewritten from the bytes on disk")
        XCTAssertEqual(fileSize(w.url) % 2, 0, "trailing half sample dropped")
        XCTAssertEqual(try XCTUnwrap(reopened.clip(w.id)).seconds, Double((cut - WAV.headerBytes) / 2) / 16_000, accuracy: 0.0001)
    }

    func testHeaderBehindTheDataIsRecovered() throws {
        // Data written, header not yet updated (killed between the two writes).
        let s = store()
        let w = try s.begin()
        w.append(tone(4_000))
        w.flush()
        let extra = WAV.pcm16(tone(1_000, start: 4_000))
        let h = try FileHandle(forWritingTo: w.url)
        try h.seekToEnd()
        try h.write(contentsOf: extra)
        try h.close()
        XCTAssertEqual(try XCTUnwrap(WAV.headerSizes(w.url)).data, 8_000)
        XCTAssertEqual(try WAV.read(w.url).count, 5_000, "the reader trusts the file, not the header")
        store().recover()
        XCTAssertEqual(try XCTUnwrap(WAV.headerSizes(w.url)).data, 10_000)
    }

    // MARK: Interruptions (the notifications iOS posts)

    private func post(_ center: NotificationCenter, began: Bool, resume: Bool = false) {
        center.post(name: AudioSessionNote.interruption, object: nil,
                    userInfo: [AudioSessionNote.typeKey: began ? AudioSessionNote.began : AudioSessionNote.ended,
                               AudioSessionNote.optionKey: resume ? AudioSessionNote.shouldResume : UInt(0)])
    }

    func testCallInterruptionClosesTheClipAndKeepsTheAudio() throws {
        let center = NotificationCenter()
        let s = store()
        let r = ClipRecorder(store: s, center: center)
        var events: [ClipRecorder.Event] = []
        r.onEvent = { events.append($0) }
        let id = try XCTUnwrap(r.start())
        r.append(tone(32_000))
        post(center, began: true)
        XCTAssertNil(r.activeID, "the segment is closed the moment the call starts")
        let clip = try XCTUnwrap(s.clip(id))
        XCTAssertEqual(clip.status, .interrupted)
        XCTAssertEqual(clip.reason, ClipReason.interruption)
        XCTAssertEqual(clip.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(try s.samples(id).count, 32_000, "audio up to the call is kept")
        r.append(tone(16_000)) // the tap can still deliver a buffer after the call starts
        XCTAssertEqual(try s.samples(id).count, 32_000, "nothing is written into a closed clip")
        post(center, began: false, resume: true)
        XCTAssertEqual(events, [.saved(id, .interrupted), .interruptionEnded(saved: id, shouldResume: true)])
        XCTAssertTrue(clip.canRetry)
        XCTAssertEqual(clip.promptTitle, "Recording stopped by a call or another app. Transcribe it?")
    }

    func testInterruptionWhileNotRecordingKeepsNothing() {
        let center = NotificationCenter()
        let s = store()
        let r = ClipRecorder(store: s, center: center)
        var events: [ClipRecorder.Event] = []
        r.onEvent = { events.append($0) }
        post(center, began: true)
        post(center, began: false)
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertEqual(events, [.interruptionEnded(saved: nil, shouldResume: false)])
    }

    func testMediaServicesResetClosesTheClip() throws {
        let center = NotificationCenter()
        let s = store()
        let r = ClipRecorder(store: s, center: center)
        let id = try XCTUnwrap(r.start())
        r.append(tone(16_000))
        center.post(name: AudioSessionNote.mediaReset, object: nil)
        XCTAssertEqual(s.clip(id)?.status, .interrupted)
        XCTAssertEqual(s.clip(id)?.reason, ClipReason.audioReset)
        XCTAssertEqual(try s.samples(id).count, 16_000)
    }

    func testRouteChangeKeepsRecordingIntoTheSameClip() throws {
        let center = NotificationCenter()
        let s = store()
        let r = ClipRecorder(store: s, center: center)
        let id = try XCTUnwrap(r.start())
        r.append(tone(8_000))
        center.post(name: AudioSessionNote.routeChange, object: nil)
        XCTAssertEqual(r.activeID, id, "AirPods in or out: same clip")
        XCTAssertEqual(try WAV.read(s.audioURL(id)).count, 8_000, "flushed to disk on the route change")
        r.append(tone(8_000, start: 8_000))
        let clip = try XCTUnwrap(r.stop(.transcribing))
        XCTAssertEqual(clip.seconds, 1, accuracy: 0.001)
    }

    // MARK: X, finish, too short

    func testXKeepsTheClip() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        r.append(tone(24_000))
        let clip = try XCTUnwrap(r.stop(.cancelled, reason: ClipReason.cancelled))
        XCTAssertEqual(clip.id, id)
        XCTAssertEqual(s.all().map(\.id), [id], "X cancels the paste, not the audio")
        XCTAssertEqual(clip.label, "You tapped X")
        XCTAssertTrue(clip.canRetry)
        XCTAssertEqual(try s.samples(id).count, 24_000)
        XCTAssertNil(r.stop(.cancelled), "a second stop is a no-op")
    }

    func testTooShortClipIsDropped() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        r.append(tone(1_000)) // 62 ms
        XCTAssertNil(r.stop(.cancelled, reason: ClipReason.cancelled))
        XCTAssertNil(s.clip(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.audioURL(id).path))
    }

    func testDeleteRemovesAudioAndRecord() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        r.append(tone(16_000))
        r.stop(.transcribing)
        s.delete(id)
        XCTAssertNil(s.clip(id))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(left.isEmpty, "\(left)")
    }

    // MARK: Crash or kill, then the next launch

    func testKilledMidRecordingIsRecoveredOnNextLaunch() throws {
        let first = store()
        let r = ClipRecorder(store: first, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        r.append(tone(16_000))
        r.append(tone(16_000, start: 16_000))
        r.flush()
        // No stop(): the process is gone. A new launch opens the same folder.
        let next = store()
        XCTAssertEqual(next.clip(id)?.status, .recording)
        let recovered = next.recover()
        XCTAssertEqual(recovered.map(\.id), [id])
        let clip = try XCTUnwrap(next.clip(id))
        XCTAssertEqual(clip.status, .unfinished)
        XCTAssertEqual(clip.label, "Free Flow closed before it finished")
        XCTAssertEqual(clip.seconds, 2, accuracy: 0.001)
        XCTAssertTrue(clip.canRetry)
        XCTAssertEqual(clip.promptTitle, "Free Flow closed before your recording finished. Transcribe it?")
        XCTAssertEqual(try next.samples(id).count, 32_000)
    }

    func testKilledWhileTranscribingIsRecovered() throws {
        let first = store()
        let r = ClipRecorder(store: first, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        r.append(tone(16_000))
        r.stop(.transcribing)
        let next = store()
        next.recover()
        XCTAssertEqual(next.clip(id)?.status, .unfinished)
    }

    func testRecoverSkipsTheClipBeingRecorded() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        r.append(tone(16_000))
        XCTAssertTrue(s.recover(active: id).isEmpty)
        XCTAssertEqual(s.clip(id)?.status, .recording)
    }

    func testAudioWithoutItsRecordIsAdopted() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        r.append(tone(16_000))
        r.flush()
        try FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString + ".json"))
        let next = store()
        XCTAssertEqual(next.recover().map(\.id), [id])
        XCTAssertEqual(next.clip(id)?.status, .unfinished)
    }

    func testEmptyFileFromAKillIsDropped() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start())
        let next = store()
        XCTAssertTrue(next.recover().isEmpty)
        XCTAssertNil(next.clip(id))
    }

    // MARK: Retention

    func testRetentionDeletesOnTime() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let old = try XCTUnwrap(r.start()); r.append(tone(16_000)); r.stop(.cancelled)
        clock += 86_400 * 3
        let newer = try XCTUnwrap(r.start()); r.append(tone(16_000)); r.stop(.interrupted)
        clock += 86_400 * 4 - 60 // old clip: 6 d 23 h 59 min
        XCTAssertEqual(s.purge(.sevenDays), 0)
        clock += 60 // old clip: exactly 7 days
        XCTAssertEqual(s.purge(.sevenDays), 1)
        XCTAssertNil(s.clip(old))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.audioURL(old).path))
        XCTAssertNotNil(s.clip(newer))
        XCTAssertEqual(s.purge(.never), 0, "Never keeps everything")
        XCTAssertEqual(s.purge(.thirtyDays), 0)
        XCTAssertEqual(s.purge(.oneDay), 1)
        XCTAssertTrue(s.all().isEmpty)
    }

    func testRetentionNeverDeletesTheClipBeingRecorded() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start()); r.append(tone(16_000))
        clock += 86_400 * 40
        XCTAssertEqual(s.purge(.oneDay, active: id), 0)
        XCTAssertNotNil(s.clip(id))
    }

    func testRetentionSetting() {
        XCTAssertEqual(ClipRetention.allCases.map(\.title), ["Never", "1 day", "7 days", "30 days"])
        XCTAssertEqual(ClipRetention.stored(nil), .sevenDays, "default is 7 days")
        XCTAssertEqual(ClipRetention.stored(30), .thirtyDays)
        XCTAssertEqual(ClipRetention.stored(0), .never)
        XCTAssertEqual(ClipRetention.stored(5), .sevenDays, "an unknown value falls back to the default")
    }

    func testDeleteAllRecordings() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        for _ in 0..<3 { _ = r.start(); r.append(tone(16_000)); r.stop(.cancelled) }
        let live = try XCTUnwrap(r.start()); r.append(tone(16_000))
        XCTAssertEqual(s.all().count, 4)
        s.deleteAll(except: live)
        XCTAssertEqual(s.all().map(\.id), [live])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, [live.uuidString + ".json", live.uuidString + ".wav"])
    }

    // MARK: Where the files live

    func testFilesAreLeftOutOfBackups() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start()); r.append(tone(16_000)); r.stop(.cancelled)
        for url in [folder!, s.audioURL(id), folder.appendingPathComponent(id.uuidString + ".json")] {
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, url.lastPathComponent)
        }
    }

    func testFileProtectionAllowsLockedBackgroundRecording() throws {
        XCTAssertEqual(ClipStore.protection, .completeUntilFirstUserAuthentication)
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let id = try XCTUnwrap(r.start()); r.append(tone(16_000)); r.stop(.cancelled)
        XCTAssertEqual(ClipStore.fileAttributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #if os(iOS) && !targetEnvironment(simulator)
        for url in [s.audioURL(id), folder.appendingPathComponent(id.uuidString + ".json")] {
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
            XCTAssertEqual(value, .completeUntilFirstUserAuthentication, url.lastPathComponent)
        }
        #elseif os(iOS)
        // Measured 2026-10-29 (iOS 26.5 simulator): protectionKey read back nil for both clip files (.wav and .json).
        throw XCTSkip("The simulator has no Data Protection; the class on the real file can only be read back on a device.")
        #endif
    }

    func testDefaultFolderIsTheAppsOwnContainerNotTheSharedGroup() {
        XCTAssertTrue(ClipStore.defaultFolder.path.contains("Application Support"), ClipStore.defaultFolder.path)
        XCTAssertFalse(ClipStore.defaultFolder.path.contains("Group Containers"), "the keyboard must never see audio")
    }

    func testListIsNewestFirstAndHidesTheLiveClip() throws {
        let s = store()
        let r = ClipRecorder(store: s, center: NotificationCenter())
        let a = try XCTUnwrap(r.start()); r.append(tone(16_000)); r.stop(.cancelled)
        clock += 10
        let b = try XCTUnwrap(r.start()); r.append(tone(16_000)); r.stop(.interrupted)
        clock += 10
        _ = r.start(); r.append(tone(16_000))
        XCTAssertEqual(s.recent().map(\.id), [b, a])
    }
}
