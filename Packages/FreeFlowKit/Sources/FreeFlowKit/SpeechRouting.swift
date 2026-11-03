import Foundation

/// 2026-11-02: the language decides the engine. English and the other languages Parakeet covers (its 25) dictate
/// on Parakeet; every other language (Thai, Korean, Japanese, Chinese, ...) dictates on Whisper, which is otherwise
/// never used. Automatic (one guess per dictation) exists only on Whisper, so it routes there. The person picks WHICH
/// Parakeet and WHICH Whisper in Models; the language setting picks between the two.
public enum SpeechRouting {
    /// The model a dictation runs on. `language` nil = Automatic. `whisper` nil = no Whisper model in the catalog (or
    /// none this device can run): everything stays on Parakeet, which pins an unknown language to English.
    public static func modelID(language: String?, parakeet: String, whisper: String?, parakeetLanguages: Set<String>) -> String {
        guard let whisper else { return parakeet }
        guard let language else { return whisper }
        return parakeetLanguages.contains(language) ? parakeet : whisper
    }

    /// The languages Settings offers: Parakeet's, plus Whisper's when a Whisper model exists.
    public static func languages(parakeet: Set<String>, whisper: Set<String>?) -> Set<String> {
        parakeet.union(whisper ?? [])
    }

    /// The engine a language runs on, for the Settings line under the picker.
    public static func engine(for language: String?, parakeetLanguages: Set<String>, hasWhisper: Bool) -> SpeechModel.Engine {
        guard hasWhisper else { return .parakeetV3 }
        guard let language else { return .whisperKit }
        return parakeetLanguages.contains(language) ? .parakeetV3 : .whisperKit
    }
}
