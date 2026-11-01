import Foundation

/// Build 26 : which microphone Free Flow records from on iPhone and iPad.
///
/// Built-in is the default: Free Flow records from the device's own mic and AirPods or any Bluetooth headphones stay on
/// full-quality playback (A2DP). Any other input that iOS lists can be picked, a Bluetooth headset mic included. Picking
/// a Bluetooth mic adds Bluetooth hands-free (HFP) to the session, which turns the headset to call-quality audio while
/// the mic is open and can make the mic slower to start; the picker says so. No headset model is named in code: the
/// list is whatever AVAudioSession.availableInputs offers.
public enum MicChoice {
    /// UserDefaults keys: the picked input's port UID ("" = built-in), its name and whether it is Bluetooth hands-free.
    public static let key = "micInput", nameKey = "micInputName", bluetoothKey = "micInputBluetooth"
    public static let builtInTitle = "Built-in microphone"
    public static let note = "Built-in keeps headphones at full quality. A Bluetooth headset mic switches the headset to call-quality audio while the mic is open, and the mic may take longer to start."

    /// One input as the picker and the session see it (from AVAudioSessionPortDescription).
    public struct Input: Equatable, Sendable {
        public let uid: String, name: String, isBluetooth: Bool, isBuiltIn: Bool
        public init(uid: String, name: String, isBluetooth: Bool, isBuiltIn: Bool) {
            self.uid = uid; self.name = name; self.isBluetooth = isBluetooth; self.isBuiltIn = isBuiltIn
        }
    }

    /// A picker row: tag "" is built-in.
    public struct Row: Equatable, Sendable {
        public let tag: String, title: String
        public init(tag: String, title: String) { self.tag = tag; self.title = title }
    }

    /// Built-in first, then every other input iOS offers once, then the saved pick if it is not connected now.
    public static func rows(available: [Input], saved: String, savedName: String) -> [Row] {
        var rows = [Row(tag: "", title: builtInTitle)]
        for input in available where !input.isBuiltIn && !rows.contains(where: { $0.tag == input.uid }) {
            rows.append(Row(tag: input.uid, title: input.name))
        }
        if !saved.isEmpty, !rows.contains(where: { $0.tag == saved }) {
            rows.append(Row(tag: saved, title: (savedName.isEmpty ? "Saved microphone" : savedName) + " (not connected)"))
        }
        return rows
    }

    /// The input to prefer when the session starts: the saved one when it is connected, otherwise built-in.
    public static func preferred(saved: String, available: [Input]) -> Input? {
        if !saved.isEmpty, let input = available.first(where: { $0.uid == saved }) { return input }
        return available.first(where: \.isBuiltIn)
    }

    /// Bluetooth hands-free goes into the session only for a picked Bluetooth mic.
    public static func needsHandsFree(saved: String, savedIsBluetooth: Bool) -> Bool { !saved.isEmpty && savedIsBluetooth }
}
