import Foundation

/// Whether the keyboard owes the cursor a finished dictation.
///
/// The app writes the text and its id, then may end its session within the same second: when the session window
/// (ArmWindow) runs out during a dictation, it is held until the text is ready and disarms on the next 1 s heartbeat,
/// so the phase goes done -> off. Build 9 typed only while it saw phase done with the mic still on, so a keyboard that
/// polled after the switch never typed the text (gate 13, 2026-10-30: iPad Pro, Core ML, a 25-minute dictation in
/// Contacts; the text was in History, the field was unchanged and the keyboard showed Ready).
public enum KeyboardInsertRule {
    /// - phase: the app's last written phase
    /// - resultID: the newest result id in the App Group; lastResult: the id this keyboard already handled, or the one
    ///   that was current when it asked for the dictation; insertedID: the id any keyboard last typed
    /// - visible: the keyboard is on screen (iOS types only into a visible keyboard)
    /// - waiting: this keyboard shows Listening or Writing; awaitLive: KeyboardAwait says the dictation is still owed
    public static func owed(phase: SessionPhase, resultID: String, lastResult: String, insertedID: String,
                            visible: Bool, waiting: Bool, awaitLive: Bool) -> Bool {
        guard visible, !resultID.isEmpty, resultID != lastResult, resultID != insertedID else { return false }
        guard phase == .done || phase == .off else { return false }
        return waiting || awaitLive
    }
}
