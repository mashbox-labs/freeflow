import Foundation

/// Who writes dictations (build 18, 2026-10-30: LFM3 is dropped; Apple Intelligence works well, and the app must also
/// work for people who do not have it on): Apple's on-device model, optional. Build 33: off unless the person turns it
/// on at setup or in Settings › Writing; a choice already stored is kept. Where Apple Intelligence cannot run, the text
/// goes in as heard and the app says why.
public enum WriterChoice: String, CaseIterable, Identifiable, Sendable {
    case apple, off
    public var id: String { rawValue }
    public static let key = "writerChoice"

    public var title: String {
        switch self {
        case .apple: return "Apple Intelligence"
        case .off: return "Off"
        }
    }

    /// The stored choice, or nil when the person has not picked one (an old "lfm3" reads as not picked).
    public static var stored: WriterChoice? {
        get { UserDefaults.standard.string(forKey: key).flatMap(WriterChoice.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: key) }
    }

    /// Build 37: tells the keyboard whether cleanup is on (SharedSession.writerOn), written only when it changed.
    public static func mirrorToKeyboard() {
        let on = resolved == .apple
        if SharedSession.writerOn != on { SharedSession.writerOn = on }
    }

    /// The stored choice, else off (build 33).
    public static var resolved: WriterChoice { resolved(raw: UserDefaults.standard.string(forKey: key)) }

    /// The same from a stored raw value ("" or nil = not picked), for views that keep it in @AppStorage.
    public static func resolved(raw: String?) -> WriterChoice { raw.flatMap(WriterChoice.init(rawValue:)) ?? .off }

    /// The Settings line: who writes and in what state. `reason`: why Apple's model cannot run here, in a few words.
    public static func status(choice: WriterChoice, appleAvailable: Bool, reason: String? = nil) -> (name: String, state: String) {
        switch choice {
        case .apple:
            return appleAvailable ? ("Apple Intelligence", "On, on this device")
                                  : ("Apple Intelligence", "Not available: \(reason ?? "Apple Intelligence can't run here"). Text goes in as heard.")
        case .off:
            return ("Off", "Text as heard")
        }
    }
}

/// What the last cleanup did, shown on screen right after it (for reading timings off a device). Display only: it lives
/// in memory, is never logged, stored or sent, and holds no words of the text.
public struct WritingReadout: Equatable, Sendable {
    public var model: String            // "Apple on-device model" or "None"
    public var runtime: String          // what actually ran, e.g. "Apple Foundation Models"
    public var background: Bool         // Free Flow was in the background when the cleanup started
    public var wordsIn: Int
    public var wordsOut: Int
    public var seconds: Double          // wall time of the whole cleanup, model load included
    public var loadSeconds: Double?
    public var outputTokens: Int?       // nil when the runtime does not report tokens (Apple's model)
    public var generateSeconds: Double?
    public var keptRaw: Int             // pieces that went in as heard (error, refusal or unusable answer)
    public var note: String?            // why no model, or only part, wrote the text
    public var used: Int                // pieces where the model's text went in

    public init(model: String, runtime: String, background: Bool, wordsIn: Int, wordsOut: Int, seconds: Double,
                loadSeconds: Double? = nil, outputTokens: Int? = nil, generateSeconds: Double? = nil, keptRaw: Int = 0,
                note: String? = nil, used: Int = 0) {
        self.model = model; self.runtime = runtime; self.background = background
        self.wordsIn = wordsIn; self.wordsOut = wordsOut; self.seconds = seconds; self.loadSeconds = loadSeconds
        self.outputTokens = outputTokens; self.generateSeconds = generateSeconds; self.keptRaw = keptRaw; self.note = note
        self.used = used
    }

    /// One small plain line for every dictation (2026-10-30): who wrote it and how long it took, or that it went in
    /// as heard and why. Stored with the dictation in History (text only, on this device).
    public var short: String {
        if used > 0 {
            let who = model.hasPrefix("Apple") ? "Apple Intelligence" : model
            return String(format: "Written by %@ · %.1f s", who, seconds) + (keptRaw > 0 ? " · part as heard" + (note.map { ": " + $0 } ?? "") : "")
        }
        return "As heard" + ((note ?? (model == "None" ? nil : "answer not used")).map { " · " + $0 } ?? "")
    }

    public static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    /// Generated tokens a second, when the runtime reports tokens.
    public var tokensPerSecond: Double? {
        guard let n = outputTokens, let s = generateSeconds, s > 0 else { return nil }
        return Double(n) / s
    }

    public var line: String {
        var time = String(format: "%.2f s", seconds)
        if let l = loadSeconds, l >= 0.005 { time += String(format: " (load %.2f s)", l) }
        var parts = [model, runtime, background ? "in the background" : "in the foreground", "\(wordsIn) → \(wordsOut) words", time]
        if let tps = tokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
        else if outputTokens == nil, model != "None" { parts.append("tok/s not reported") }
        if keptRaw > 0 { parts.append("\(keptRaw) part\(keptRaw == 1 ? "" : "s") kept as heard") }
        if let note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

/// How long the writing step may take before the text goes in as heard (build 15): 3 s plus 1 s per 20 words, at most
/// 15 s. A writer that is slow, still loading, or never reaches its end token can't hold a dictation longer than this.
public enum WritingBudget {
    public static func seconds(words: Int) -> Double { min(15, 3 + Double(max(0, words)) / 20) }
}
