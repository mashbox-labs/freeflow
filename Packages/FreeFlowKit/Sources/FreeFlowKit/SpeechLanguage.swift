import Foundation

/// Build 23: Whisper detected the language of every 30-second window by itself, at every fallback
/// temperature too, and wrote one long English dictation as Korean, then Spanish, then English. The language is now
/// pinned for the whole dictation: by default the device's own language; "Automatic" is opt-in and guesses once per
/// dictation, never per window. The task is always transcribe, never translate. The dictionary never changes it.
public enum SpeechLanguage {
    /// UserDefaults key: "" = this device's language (the default), "auto" = Automatic, else a language code.
    public static let key = "speechLanguage"
    public static let automatic = "auto"

    /// Device language codes that differ from Whisper's own codes.
    static let aliases = ["nb": "no", "jv": "jw", "fil": "tl", "iw": "he", "zh-Hant": "zh", "zh-Hans": "zh"]

    /// "en-US" -> "en", "nb-NO" -> "no", "zh-Hans-CN" -> "zh".
    public static func code(of identifier: String) -> String {
        let base = String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        return aliases[base] ?? base.lowercased()
    }

    /// The device's language for speech: the first of its preferred languages the model knows; nil when none is
    /// known (then the model guesses, as Automatic).
    public static func deviceDefault(preferred: [String], supported: Set<String>) -> String? {
        preferred.lazy.map(code(of:)).first { supported.contains($0) }
    }

    /// The language every window of a dictation uses; nil = Automatic (guessed once per dictation).
    public static func resolve(stored: String?, preferred: [String], supported: Set<String>) -> String? {
        let s = stored ?? ""
        if s == automatic { return nil }
        if !s.isEmpty, supported.contains(s) { return s }
        return deviceDefault(preferred: preferred, supported: supported)
    }
}
