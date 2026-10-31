import XCTest
@testable import FreeFlowKit

final class StatsTests: XCTestCase {
    let bangkok = TimeZone(identifier: "Asia/Bangkok")!
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func date(_ s: String, _ tz: TimeZone) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
    }

    private func count(_ text: String, recorded: Double = 10, speech: Double? = 8, process: Double = 0.5, model: String = "Parakeet TDT 0.6B v3") -> DictationCount {
        DictationCount(text: text, raw: text, recordedSeconds: recorded, speechSeconds: speech, processSeconds: process, model: model)
    }

    // MARK: Streaks

    func testStreakAcrossMidnight() {
        let store = StatsStore(url: tempURL(), now: date("2026-10-01 00:00:00", bangkok))
        store.record(count("late night words"), at: date("2026-10-29 23:59:30", bangkok), timeZone: bangkok)
        store.record(count("early morning words"), at: date("2026-10-30 00:00:30", bangkok), timeZone: bangkok)
        let s = store.snapshot(now: date("2026-10-30 09:00:00", bangkok), timeZone: bangkok)
        XCTAssertEqual(Set(store.data.days.keys), ["2026-10-29", "2026-10-30"], "one minute apart, two days")
        XCTAssertEqual(s.currentStreak, 2)
        XCTAssertEqual(s.bestStreak, 2)
        XCTAssertTrue(s.dictatedToday)
    }

    func testStreakAliveUntilTheDayEnds() {
        let days = ["2026-10-26", "2026-10-27", "2026-10-28"]
        XCTAssertEqual(StatsMath.streaks(days: days, today: "2026-10-28").current, 3)
        XCTAssertEqual(StatsMath.streaks(days: days, today: "2026-10-29").current, 3, "yesterday still counts, today is not over")
        XCTAssertEqual(StatsMath.streaks(days: days, today: "2026-10-30").current, 0, "a missed day ends it")
        XCTAssertEqual(StatsMath.streaks(days: days, today: "2026-10-30").best, 3)
    }

    func testBestStreakIsLongestRun() {
        let days = ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-10", "2026-10-11"]
        let r = StatsMath.streaks(days: days, today: "2026-10-11")
        XCTAssertEqual(r.current, 2)
        XCTAssertEqual(r.best, 4)
    }

    func testStreakAcrossMonthLeapYearAndDST() {
        XCTAssertEqual(StatsMath.streaks(days: ["2028-02-28", "2028-02-29", "2028-03-01"], today: "2028-03-01").current, 3)
        XCTAssertEqual(StatsMath.streaks(days: ["2027-02-28", "2027-03-01"], today: "2027-03-01").current, 2)
        XCTAssertEqual(StatsMath.streaks(days: ["2026-12-31", "2027-01-01"], today: "2027-01-01").current, 2)
        // US clocks go back on 2026-11-01: a 25-hour day must not break or double count.
        let store = StatsStore(url: tempURL(), now: date("2026-10-01 00:00:00", losAngeles))
        for day in ["2026-10-31 23:30:00", "2026-11-01 23:30:00", "2026-11-02 00:30:00"] {
            store.record(count("hello there"), at: date(day, losAngeles), timeZone: losAngeles)
        }
        let s = store.snapshot(now: date("2026-11-02 12:00:00", losAngeles), timeZone: losAngeles)
        XCTAssertEqual(s.currentStreak, 3)
        XCTAssertEqual(s.activeDays, 3)
    }

    func testStreakWhenTravellingAcrossTimeZones() {
        let store = StatsStore(url: tempURL(), now: date("2026-10-01 00:00:00", bangkok))
        // Dictate in Bangkok on the morning of the 30th, then land in Los Angeles where it is still the 29th.
        store.record(count("from Bangkok"), at: date("2026-10-30 08:00:00", bangkok), timeZone: bangkok)
        var s = store.snapshot(now: date("2026-10-29 20:00:00", losAngeles), timeZone: losAngeles)
        XCTAssertEqual(s.currentStreak, 1, "a day ahead of the local date counts as today, not as a broken streak")
        XCTAssertTrue(s.dictatedToday)
        // Dictate again in Los Angeles on its 29th, then on its 30th and 31st.
        store.record(count("from LA"), at: date("2026-10-29 21:00:00", losAngeles), timeZone: losAngeles)
        store.record(count("still LA"), at: date("2026-10-30 10:00:00", losAngeles), timeZone: losAngeles)
        store.record(count("one more"), at: date("2026-10-31 10:00:00", losAngeles), timeZone: losAngeles)
        s = store.snapshot(now: date("2026-10-31 12:00:00", losAngeles), timeZone: losAngeles)
        XCTAssertEqual(s.currentStreak, 3, "29, 30, 31 by the wall clock where each one happened")
        XCTAssertEqual(s.activeDays, 3)
        XCTAssertEqual(s.dictations, 4)
        // The same moments evaluated in Bangkok: the day keys are fixed when you dictate.
        let bkk = store.snapshot(now: date("2026-11-01 01:00:00", bangkok), timeZone: bangkok)
        XCTAssertEqual(bkk.currentStreak, 3, "LA's 31st is yesterday in Bangkok on the 1st")
    }

    // MARK: Speech time and wpm

    private func tone(_ seconds: Double, rate: Double = 16_000) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(0.1 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
    }

    private func silence(_ seconds: Double, rate: Double = 16_000) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -0.0008...0.0008, using: &g) }
    }

    func testSpeechSecondsLeavesOutLongPausesOnly() {
        // 1 s lead-in, 2 s talk, 0.4 s breath, 2 s talk, 3 s thinking pause, 2 s talk, 1.5 s tail = 11.9 s recorded.
        let audio = silence(1) + tone(2) + silence(0.4) + tone(2) + silence(3) + tone(2) + silence(1.5)
        let speech = StatsMath.speechSeconds(audio, rate: 16_000)
        XCTAssertEqual(speech, 6.4, accuracy: 0.06, "2 + 0.4 + 2 + 2: the breath counts, lead-in, tail and the 3 s pause do not")
    }

    func testSpeechSecondsEdgeCases() {
        XCTAssertEqual(StatsMath.speechSeconds(silence(5), rate: 16_000), 0, "silence is no speech")
        XCTAssertEqual(StatsMath.speechSeconds([], rate: 16_000), 0)
        XCTAssertEqual(StatsMath.speechSeconds(tone(4), rate: 16_000), 4, accuracy: 0.03, "talking the whole time")
        // A pause just under a second is part of speaking.
        XCTAssertEqual(StatsMath.speechSeconds(tone(1) + silence(0.9) + tone(1), rate: 16_000), 2.9, accuracy: 0.06)
    }

    func testWpmWithPauses() {
        let audio = silence(1) + tone(2) + silence(0.4) + tone(2) + silence(3) + tone(2) + silence(1.5)
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        let c = DictationCount.live(text: text, raw: text, samples: audio, rate: 16_000, processSeconds: 0.3, model: "m")
        XCTAssertEqual(c.recordedSeconds, 11.9, accuracy: 0.001)
        let store = StatsStore(url: tempURL())
        store.record(c)
        let s = store.snapshot()
        XCTAssertEqual(s.wpm!, 16 / (6.4 / 60), accuracy: 2, "about 150 wpm of speech, not the 81 wpm the whole recording gives")
        XCTAssertLessThan(16 / (11.9 / 60), s.wpm!)
    }

    func testQuietMicFallsBackToRecordingTime() {
        let quiet = (0..<(16_000 * 3)).map { Float(0.002 * sin(Double($0) / 10)) }
        let c = DictationCount.live(text: "hello there", raw: "hello there", samples: quiet, rate: 16_000, processSeconds: 0.1, model: "m")
        XCTAssertEqual(c.speechSeconds!, 3, accuracy: 0.001, "no speech heard: the whole recording counts, which can only lower the speed")
    }

    func testWpmAggregatesAndSkipsUntimed() {
        let store = StatsStore(url: tempURL())
        let thirty = Array(repeating: "word", count: 30).joined(separator: " ")
        let ten = Array(repeating: "word", count: 10).joined(separator: " ")
        store.record(count(thirty, recorded: 15, speech: 12))
        store.record(count(ten, recorded: 6, speech: 4))
        XCTAssertEqual(store.snapshot().wpm!, 40 / (16.0 / 60), accuracy: 0.001)
        store.record(count(ten, recorded: 100, speech: nil))  // counted from history: no audio to time
        let s = store.snapshot()
        XCTAssertEqual(s.wpm!, 150, accuracy: 0.001, "untimed dictations do not move the speed")
        XCTAssertEqual(s.words, 50, "but they count as words")
    }

    func testSpokenWordsDriveSpeedAndTextWordsDriveTotal() {
        let store = StatsStore(url: tempURL())
        store.record(DictationCount(text: "So I think we ship.", raw: "um so so I think we uh ship", recordedSeconds: 4, speechSeconds: 4, processSeconds: 0.2, model: "m"))
        let s = store.snapshot()
        XCTAssertEqual(s.words, 5)
        XCTAssertEqual(s.wpm!, 8 / (4.0 / 60), accuracy: 0.001)
    }

    // MARK: Words, books, time saved, model speed

    func testWordCount() {
        XCTAssertEqual(StatsMath.wordCount("And so, my fellow Americans: ask not what your country can do for you."), 14)
        XCTAssertEqual(StatsMath.wordCount(""), 0)
        XCTAssertEqual(StatsMath.wordCount("  ...  "), 0)
        XCTAssertEqual(StatsMath.wordCount("We shipped 3 builds today"), 5)
        XCTAssertGreaterThan(StatsMath.wordCount("今日はとても良い天気です"), 2, "no spaces, still several words")
    }

    func testTimeSavedEstimate() {
        let store = StatsStore(url: tempURL())
        // 362 characters = 72.4 typed words = 2 minutes at 36.2 wpm. Dictating took 20 s + 1 s.
        let text = String(repeating: "abcd ", count: 72) + "ab"
        XCTAssertEqual(text.count, 362)
        store.record(count(text, recorded: 20, speech: 18, process: 1))
        let s = store.snapshot()
        XCTAssertEqual(s.typingSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(s.savedSeconds, 99, accuracy: 0.001)
    }

    func testModelSpeed() {
        let store = StatsStore(url: tempURL())
        store.record(count("one two", recorded: 40, process: 1, model: "Parakeet TDT 0.6B v3"))
        store.record(count("three four", recorded: 20, process: 1, model: "Parakeet TDT 0.6B v3"))
        store.record(count("five", recorded: 10, process: 2, model: "Whisper small"))
        let s = store.snapshot()
        XCTAssertEqual(s.mainModel?.name, "Parakeet TDT 0.6B v3")
        XCTAssertEqual(s.mainModel!.speed!, 30, accuracy: 0.001)
        XCTAssertEqual(s.models.last!.speed!, 5, accuracy: 0.001)
        XCTAssertEqual(s.recordedSeconds, 70, accuracy: 0.001)
    }

    func testEmptyWordsAreNotCounted() {
        let store = StatsStore(url: tempURL())
        store.record(count("   "))
        XCTAssertTrue(store.snapshot().isEmpty)
        XCTAssertTrue(store.data.days.isEmpty)
    }

    // MARK: Backfill, persistence, reset

    private func history(_ start: Date) -> [HistoryItem] {
        [
            HistoryItem(date: start.addingTimeInterval(-86_400 * 2), text: "Two days ago we talked.", raw: "two days ago we talked", style: .formal, model: "Whisper small", audioSeconds: 3, processSeconds: 1),
            HistoryItem(date: start.addingTimeInterval(-86_400), text: "Yesterday too.", raw: "yesterday too", style: .formal, model: "Whisper small", audioSeconds: 2, processSeconds: 0.5),
            HistoryItem(date: start.addingTimeInterval(-60), text: "And a minute ago.", raw: "and a minute ago", style: .formal, model: "Parakeet TDT 0.6B v3", audioSeconds: 2, processSeconds: 0.1),
            HistoryItem(date: start.addingTimeInterval(-30), text: "", raw: "", style: .formal, model: "Parakeet TDT 0.6B v3", audioSeconds: 1, processSeconds: 0.1),
        ]
    }

    func testBackfillIsIdempotent() {
        let url = tempURL()
        let start = date("2026-10-29 12:00:00", bangkok)
        let store = StatsStore(url: url, now: start)
        var items = history(start)
        // A dictation after stats began was counted live and is also in history: it must not count twice.
        let live = HistoryItem(date: start.addingTimeInterval(5), text: "Counted live.", raw: "counted live", style: .formal, model: "Parakeet TDT 0.6B v3", audioSeconds: 2, processSeconds: 0.1)
        store.record(count(live.text, recorded: 2, speech: 1.5, process: 0.1), at: live.date, timeZone: bangkok)
        items.insert(live, at: 0)

        XCTAssertEqual(store.backfill(from: items, timeZone: bangkok), 3, "three old items with words")
        let first = store.data
        XCTAssertEqual(store.backfill(from: items, timeZone: bangkok), 0)
        XCTAssertEqual(store.data, first, "second run changes nothing")

        let reopened = StatsStore(url: url, now: start.addingTimeInterval(3600))
        XCTAssertEqual(reopened.backfill(from: items, timeZone: bangkok), 0, "a new launch does not count history again")
        XCTAssertEqual(reopened.data, first, "saved and loaded unchanged")

        let s = reopened.snapshot(now: start, timeZone: bangkok)
        XCTAssertEqual(s.dictations, 4)
        XCTAssertEqual(s.words, 5 + 2 + 4 + 2)
        XCTAssertEqual(s.fromHistory, 3)
        XCTAssertEqual(s.currentStreak, 3)
        XCTAssertEqual(s.wpm!, 2 / (1.5 / 60), accuracy: 0.001, "only the live dictation has a speech time")
        XCTAssertEqual(s.models.count, 2)
    }

    /// The app records a dictation, then adds it to history. A store first opened at that record (no Home shown
    /// yet, e.g. a dictation started from the Action Button) must count it once, not again from history.
    func testFirstUseCountsTheNewDictationOnce() {
        let start = Date()
        let old = HistoryItem(date: start.addingTimeInterval(-600), text: "Older words here.", raw: "older words here", style: .formal, model: "m", audioSeconds: 2, processSeconds: 0.1)
        let store = StatsStore(url: tempURL(), now: start)
        store.backfill(from: [old])                     // what StatsStore.shared does on first use
        store.record(count("Brand new dictation."), at: start.addingTimeInterval(1))
        let new = HistoryItem(date: start.addingTimeInterval(1), text: "Brand new dictation.", raw: "brand new dictation", style: .formal, model: "m", audioSeconds: 2, processSeconds: 0.1)
        XCTAssertEqual(store.backfill(from: [new, old]), 0)
        XCTAssertEqual(store.snapshot().words, 3 + 3)
        XCTAssertEqual(store.snapshot().dictations, 2)
    }

    func testResetGoesToZeroAndDoesNotRecountHistory() {
        let url = tempURL()
        let start = date("2026-10-29 12:00:00", bangkok)
        let store = StatsStore(url: url, now: start)
        store.backfill(from: history(start), timeZone: bangkok)
        XCTAssertFalse(store.snapshot().isEmpty)
        store.reset(now: start.addingTimeInterval(60))
        XCTAssertTrue(store.snapshot().isEmpty)
        XCTAssertEqual(store.backfill(from: history(start), timeZone: bangkok), 0)
        let reopened = StatsStore(url: url)
        XCTAssertTrue(reopened.snapshot().isEmpty)
        XCTAssertEqual(reopened.backfill(from: history(start), timeZone: bangkok), 0)
    }

    func testStoredFileHasNoText() throws {
        let url = tempURL()
        let store = StatsStore(url: url)
        store.record(count("my secret plans for the launch"))
        store.backfill(from: history(Date()))
        let file = try String(contentsOf: url, encoding: .utf8)
        for word in ["secret", "plans", "launch", "Yesterday", "minute"] {
            XCTAssertFalse(file.contains(word), "the stats file must hold counts only, found '\(word)'")
        }
    }

    // MARK: Card words for every state

    func testDayOneAndEmptyCopy() {
        let empty = StatsData(countingSince: Date()).snapshot()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.wpm)
        XCTAssertEqual(StatsText.booksLine(0), "Your first dictation starts the count.")
        XCTAssertEqual(StatsText.streakLine(empty), "Dictate on two days in a row to start a streak.")
        XCTAssertEqual(StatsText.speedLine(empty), "Your speaking speed shows after your first dictation.")
        XCTAssertEqual(StatsText.savedValue(empty).value, "0")
        XCTAssertEqual(StatsText.modelLine(empty), "Your speech model runs here, on the Neural Engine.")

        let store = StatsStore(url: tempURL())
        store.record(count("hello world"))
        let day1 = store.snapshot()
        XCTAssertEqual(day1.currentStreak, 1)
        XCTAssertEqual(StatsText.streakLine(day1), "Day one. Dictate tomorrow to make it two.")
        XCTAssertEqual(StatsText.booksLine(2), "Under 1% of a 100,000-word book so far.")
    }

    func testBooksAndDurations() {
        XCTAssertEqual(StatsText.booksLine(3_400), "That's 3% of a 100,000-word book.")
        XCTAssertEqual(StatsText.booksLine(100_000), "That's 1 complete book, at 100,000 words a book.")
        XCTAssertEqual(StatsText.booksLine(2_915_406), "That's 29 complete books, at 100,000 words a book.")
        XCTAssertTrue(StatsText.duration(38) == ("38", "sec"))
        XCTAssertTrue(StatsText.duration(14 * 60 + 50) == ("14", "min"))
        XCTAssertTrue(StatsText.duration(8_640) == ("2.4", "hours"))
        XCTAssertTrue(StatsText.duration(-5) == ("0", "sec"))
        XCTAssertTrue(StatsText.duration(59.7) == ("1", "min"), "never 60 sec")
        XCTAssertEqual(StatsText.speed(48.4), "48x")
        XCTAssertEqual(StatsText.speed(3.04), "3.0x")
    }

    func testStreakCopyStates() {
        var s = StatsData(countingSince: Date()).snapshot()
        s.currentStreak = 4; s.bestStreak = 9; s.dictatedToday = false
        XCTAssertEqual(StatsText.streakLine(s), "In a row. Dictate today to keep it going. Best: 9 days.")
        s.dictatedToday = true
        XCTAssertEqual(StatsText.streakLine(s), "In a row, today included. Best: 9 days.")
        s.currentStreak = 0
        XCTAssertEqual(StatsText.streakLine(s), "Best so far: 9 days. Dictate today to start a new run.")
    }
}

import AVFoundation

/// Real speech, when the git-ignored test clip is present (TestAudio/jfk.wav, public-domain speech, 16 kHz mono).
final class StatsRealSpeechTests: XCTestCase {
    func testJFKClip() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = ProcessInfo.processInfo.environment["FF_AUDIO_FILE"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("TestAudio/jfk.wav")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no test clip at \(url.path)") }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let recorded = Double(samples.count) / format.sampleRate
        let speech = StatsMath.speechSeconds(samples, rate: format.sampleRate)
        let words = StatsMath.wordCount("And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.")
        print(String(format: "FFSTATS jfk recorded=%.2f s speech=%.2f s words=%d wpm(speech)=%.0f wpm(recorded)=%.0f", recorded, speech, words, Double(words) / speech * 60, Double(words) / recorded * 60))
        XCTAssertEqual(words, 22)
        XCTAssertGreaterThan(speech, 5, "most of the clip is speech")
        XCTAssertLessThan(speech, recorded, "the long pauses are left out")
    }
}
