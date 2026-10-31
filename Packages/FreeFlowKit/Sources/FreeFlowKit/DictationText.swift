import Foundation

/// The dictation path after speech recognition (build 12, 2026-10-30: every manual cleanup rule was taken out; the
/// models do the work). The words are the recognizer's, with the user's dictionary applied inside decoding
/// (Transcriber.transcribe(audio, words:)). No rule rewrites them: no filler, repeat, stutter or repair removal, no
/// style casing or full stops, no spoken-command regexes, no tidy pass. The on-device writing model, once picked, is
/// the only step that may change the text; where it can't run, the text is the recognizer's as heard.
/// FreeFlowKit NoRuleRewriteTests holds this. The old rules live only in Packages/FreeFlowRules (bench only, not
/// linked by the app, keyboard or widgets).
public enum DictationText {
    /// The recognizer's text, trimmed at both ends. Nothing changes it by rule or by timing (2026-10-30: the app
    /// stays hands off and lets the models do the work).
    public static func finish(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
}
