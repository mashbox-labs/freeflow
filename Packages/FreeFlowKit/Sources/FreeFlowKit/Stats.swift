import Foundation
import NaturalLanguage

/// Dictation stats. Counts and durations only: no words, no audio. Computed and stored on this device
/// (App Group, excluded from backup), never sent anywhere. Nothing here compares you with other people.
public enum StatsMath {
    /// The basis for "books": a 100,000-word book.
    public static let bookWords = 100_000
    /// Average phone typing speed, 36.2 words per minute (a word = 5 characters), measured on 37,370 people:
    /// Palin, Feit, Kim, Kristensson, Oulasvirta. "How do People Type on Mobile Devices? Observations from a
    /// Study with 37,000 Volunteers." MobileHCI 2019, doi:10.1145/3338286.3340120.
    public static let phoneTypingWPM = 36.2
    public static let charactersPerTypedWord = 5.0
    /// Silences this long or longer do not count as speaking time.
    public static let longPause = 1.0
    static let frameSeconds = 0.02

    /// Words in a text, counted by the on-device tokenizer (works for languages without spaces too).
    public static func wordCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
            return true
        }
        return count
    }

    /// Seconds of speech in a recording: from the first to the last voiced 20 ms frame, leaving out every
    /// silence of `longPause` or longer. Short gaps between words count as speaking. Returns 0 for silence.
    public static func speechSeconds(_ samples: [Float], rate: Double) -> Double {
        let frame = max(1, Int(rate * frameSeconds))
        let frames = samples.count / frame
        guard frames > 0 else { return 0 }
        var rms = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { p in
            for i in 0..<frames {
                var sum: Float = 0
                for j in (i * frame)..<((i + 1) * frame) { sum += p[j] * p[j] }
                rms[i] = (sum / Float(frame)).squareRoot()
            }
        }
        // The quiet floor of this recording (10th percentile), capped so a loud talker never hides speech.
        let floor = rms.sorted()[frames / 10]
        let threshold = max(0.004, min(floor, 0.02) * 3)
        guard let first = rms.firstIndex(where: { $0 >= threshold }),
              let last = rms.lastIndex(where: { $0 >= threshold }) else { return 0 }
        let pauseFrames = Int((longPause / frameSeconds).rounded())
        var voiced = 0, gap = 0
        for i in first...last {
            if rms[i] >= threshold {
                if gap < pauseFrames { voiced += gap }
                gap = 0
                voiced += 1
            } else {
                gap += 1
            }
        }
        return Double(voiced * frame) / rate
    }

    /// The calendar day of a moment on the wall clock of the given time zone, as "yyyy-MM-dd".
    public static func dayKey(_ date: Date, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Days since 1970-01-01 for a "yyyy-MM-dd" key (proleptic Gregorian, no time zone or DST involved).
    static func dayNumber(_ key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        // Howard Hinnant's days_from_civil.
        let y = parts[1] <= 2 ? parts[0] - 1 : parts[0], m = parts[1], d = parts[2]
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Current and best runs of consecutive days. The current run is still alive when the last day is
    /// yesterday (today is not over yet). A day ahead of `today` (you dictated, then flew west) counts as today.
    public static func streaks<C: Collection>(days: C, today: String) -> (current: Int, best: Int) where C.Element == String {
        let numbers = Set(days.compactMap(dayNumber))
        guard let last = numbers.max(), let now = dayNumber(today) else { return (0, 0) }
        var best = 0
        for n in numbers where !numbers.contains(n - 1) {
            var length = 1
            while numbers.contains(n + length) { length += 1 }
            best = max(best, length)
        }
        guard last >= now - 1 else { return (0, best) }
        var current = 0
        while numbers.contains(last - current) { current += 1 }
        return (current, best)
    }
}

/// One finished dictation, reduced to numbers.
public struct DictationCount: Equatable, Sendable {
    public var words: Int            // words in the text you got
    public var spokenWords: Int      // words in the raw transcript (what you said, fillers included)
    public var characters: Int
    public var recordedSeconds: Double
    public var speechSeconds: Double?  // nil when the audio was not measured (counted from history)
    public var processSeconds: Double
    public var model: String

    public init(text: String, raw: String, recordedSeconds: Double, speechSeconds: Double?, processSeconds: Double, model: String) {
        words = StatsMath.wordCount(text)
        spokenWords = StatsMath.wordCount(raw)
        characters = text.count
        self.recordedSeconds = recordedSeconds
        self.speechSeconds = speechSeconds
        self.processSeconds = processSeconds
        self.model = model
    }

    /// A dictation that just finished, with its speech time measured from the audio. If the detector hears
    /// no speech in a recording that produced words (a very quiet mic), the whole recording counts, which can
    /// only make the speed lower, never higher.
    public static func live(text: String, raw: String, samples: [Float], rate: Double, processSeconds: Double, model: String) -> DictationCount {
        let recorded = Double(samples.count) / rate
        let speech = StatsMath.speechSeconds(samples, rate: rate)
        return DictationCount(text: text, raw: raw, recordedSeconds: recorded,
                              speechSeconds: speech >= 0.3 ? speech : recorded, processSeconds: processSeconds, model: model)
    }
}

public struct DayTotals: Codable, Equatable, Sendable {
    public var dictations = 0
    public var words = 0
    public var characters = 0
    public var recordedSeconds = 0.0
    public var processSeconds = 0.0
    public var timedWords = 0       // spoken words of dictations whose speech time was measured
    public var speechSeconds = 0.0
    public init() {}
}

public struct ModelTotals: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var dictations = 0
    public var audioSeconds = 0.0
    public var processSeconds = 0.0
    public var id: String { name }
    /// Seconds of audio per second of compute, after the model is loaded ("x real time").
    public var speed: Double? { processSeconds > 0 ? audioSeconds / processSeconds : nil }
    public init(name: String) { self.name = name }
}

public struct StatsData: Codable, Equatable, Sendable {
    public var version = 1
    /// Dictations from this moment on are counted live; older ones can only come from history, once.
    public var countingSince: Date
    public var historyCounted = false
    public var fromHistory = 0
    public var days: [String: DayTotals] = [:]
    public var models: [String: ModelTotals] = [:]

    public init(countingSince: Date, historyCounted: Bool = false) {
        self.countingSince = countingSince
        self.historyCounted = historyCounted
    }

    mutating func add(_ c: DictationCount, at date: Date, timeZone: TimeZone) {
        let key = StatsMath.dayKey(date, timeZone)
        var day = days[key] ?? DayTotals()
        day.dictations += 1
        day.words += c.words
        day.characters += c.characters
        day.recordedSeconds += c.recordedSeconds
        day.processSeconds += c.processSeconds
        if let speech = c.speechSeconds, speech > 0 {
            day.timedWords += c.spokenWords
            day.speechSeconds += speech
        }
        days[key] = day
        var model = models[c.model] ?? ModelTotals(name: c.model)
        model.dictations += 1
        model.audioSeconds += c.recordedSeconds
        model.processSeconds += c.processSeconds
        models[c.model] = model
    }

    public func snapshot(now: Date = Date(), timeZone: TimeZone = .current) -> StatsSnapshot {
        var s = StatsSnapshot(countingSince: countingSince, fromHistory: fromHistory)
        var timedWords = 0
        for day in days.values {
            s.dictations += day.dictations
            s.words += day.words
            s.characters += day.characters
            s.recordedSeconds += day.recordedSeconds
            s.processSeconds += day.processSeconds
            s.speechSeconds += day.speechSeconds
            timedWords += day.timedWords
        }
        let today = StatsMath.dayKey(now, timeZone)
        let active = days.filter { $0.value.dictations > 0 }.map(\.key)
        (s.currentStreak, s.bestStreak) = StatsMath.streaks(days: active, today: today)
        s.activeDays = active.count
        s.wordsToday = days[today]?.words ?? 0
        s.dictatedToday = (days[today]?.dictations ?? 0) > 0 || active.contains { $0 > today }
        s.wpm = s.speechSeconds > 0 ? Double(timedWords) / (s.speechSeconds / 60) : nil
        s.typingSeconds = Double(s.characters) / StatsMath.charactersPerTypedWord / StatsMath.phoneTypingWPM * 60
        s.models = models.values.filter { $0.dictations > 0 }.sorted { $0.audioSeconds > $1.audioSeconds }
        return s
    }
}

/// Everything the cards show, worked out from `StatsData` at one moment.
public struct StatsSnapshot: Equatable, Sendable {
    public var dictations = 0
    public var words = 0
    public var characters = 0
    public var recordedSeconds = 0.0
    public var processSeconds = 0.0
    public var speechSeconds = 0.0
    public var currentStreak = 0
    public var bestStreak = 0
    public var activeDays = 0
    public var wordsToday = 0
    public var dictatedToday = false
    /// Words per minute of speech; nil until a dictation's speech time has been measured.
    public var wpm: Double?
    /// ESTIMATE: how long the same characters take to type at the published phone average.
    public var typingSeconds = 0.0
    public var models: [ModelTotals] = []
    public var countingSince: Date
    public var fromHistory = 0

    public init(countingSince: Date, fromHistory: Int = 0) {
        self.countingSince = countingSince
        self.fromHistory = fromHistory
    }

    public var isEmpty: Bool { dictations == 0 }
    public var books: Double { Double(words) / Double(StatsMath.bookWords) }
    /// Time spent dictating: recording plus waiting for the text.
    public var dictatingSeconds: Double { recordedSeconds + processSeconds }
    /// ESTIMATE: typing time minus dictating time. Can be negative.
    public var savedSeconds: Double { typingSeconds - dictatingSeconds }
    /// The model with the most audio, and the speed over all models (total audio / total compute).
    public var mainModel: ModelTotals? { models.first }
    public var speed: Double? { processSeconds > 0 ? recordedSeconds / processSeconds : nil }
}

/// Loads, updates and saves the stats file in the App Group.
public final class StatsStore: ObservableObject, @unchecked Sendable {
    /// The app's store. On first use it counts the dictations already in history, once.
    public static let shared: StatsStore = {
        let store = StatsStore()
        store.backfill(from: HistoryStore.shared.items)
        return store
    }()

    @Published public private(set) var data: StatsData
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = FF.containerURL.appendingPathComponent("stats.json"), now: Date = Date()) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode(StatsData.self, from: Data(contentsOf: url)) {
            data = saved
        } else {
            data = StatsData(countingSince: now)
        }
    }

    public func snapshot(now: Date = Date(), timeZone: TimeZone = .current) -> StatsSnapshot {
        data.snapshot(now: now, timeZone: timeZone)
    }

    /// Adds one finished dictation. Dictations with no words are not counted.
    public func record(_ count: DictationCount, at date: Date = Date(), timeZone: TimeZone = .current) {
        guard count.words > 0 else { return }
        update { $0.add(count, at: date, timeZone: timeZone) }
    }

    /// Counts history items from before stats existed, once. Running it again does nothing, and items from
    /// after `countingSince` are skipped because they were already counted live. Returns how many it added.
    @discardableResult
    public func backfill(from items: [HistoryItem], timeZone: TimeZone = .current) -> Int {
        guard !data.historyCounted else { return 0 }
        var added = 0
        update { d in
            for item in items where item.date < d.countingSince {
                let c = DictationCount(text: item.text, raw: item.raw, recordedSeconds: item.audioSeconds,
                                       speechSeconds: nil, processSeconds: item.processSeconds, model: item.model)
                guard c.words > 0 else { continue }
                d.add(c, at: item.date, timeZone: timeZone)
                added += 1
            }
            d.fromHistory = added
            d.historyCounted = true
        }
        return added
    }

    /// Back to zero. History is not counted again.
    public func reset(now: Date = Date()) {
        update { $0 = StatsData(countingSince: now, historyCounted: true) }
    }

    private func update(_ change: (inout StatsData) -> Void) {
        lock.lock()
        var d = data
        change(&d)
        lock.unlock()
        if Thread.isMainThread { data = d } else { DispatchQueue.main.sync { self.data = d } }
        save(d)
    }

    private func save(_ d: StatsData) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Counts only, so it stays readable after first unlock: a dictation can finish while the phone is locked.
        try? encoder.encode(d).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
