import Foundation
#if os(iOS)
import AVFAudio
#endif

/// The calls Free Flow makes to set up its microphone session, behind a protocol so a unit test can hold them.
public protocol AudioSessionConfiguring: AnyObject {
    func ffSetPlayAndRecord(mixWithOthers: Bool, duckOthers: Bool, bluetoothMic: Bool) throws
    func ffSetAllowHapticsWhileRecording(_ on: Bool) throws
    func ffSetPrefersNoInterruptionsFromSystemAlerts(_ on: Bool) throws
    func ffSetActive(_ on: Bool) throws
}

public enum AudioSessionSetup {
    /// Play and record, mixed or ducked as set, haptics allowed, then active.
    /// iOS mutes haptics and system sounds while audio input records unless the recording session allows them, and
    /// Free Flow keeps its mic session recording for the whole "Keep the mic ready" window (15 min by default). In
    /// build 5 that muted the keyboard's key click soon after the first dictation (2026-10-29). The allow call comes
    /// after the category: AVFoundation refuses it before a recording category.
    /// bluetoothMic (build 26, MicChoice): a Bluetooth headset mic was picked, so hands-free (HFP) is allowed too.
    public static func configure(_ s: AudioSessionConfiguring, mixWithOthers: Bool, duckOthers: Bool, bluetoothMic: Bool = false) throws {
        try s.ffSetPlayAndRecord(mixWithOthers: mixWithOthers, duckOthers: duckOthers, bluetoothMic: bluetoothMic)
        try s.ffSetAllowHapticsWhileRecording(true)
        try? s.ffSetPrefersNoInterruptionsFromSystemAlerts(true)
        try s.ffSetActive(true)
    }
}

#if os(iOS)
extension AVAudioSession: AudioSessionConfiguring {
    public func ffSetPlayAndRecord(mixWithOthers: Bool, duckOthers: Bool, bluetoothMic: Bool) throws {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker]
        if bluetoothMic { options.insert(.allowBluetoothHFP) }
        if mixWithOthers { options.insert(duckOthers ? .duckOthers : .mixWithOthers) }
        try setCategory(.playAndRecord, mode: .default, options: options)
    }
    public func ffSetAllowHapticsWhileRecording(_ on: Bool) throws { try setAllowHapticsAndSystemSoundsDuringRecording(on) }
    public func ffSetPrefersNoInterruptionsFromSystemAlerts(_ on: Bool) throws { try setPrefersNoInterruptionsFromSystemAlerts(on) }
    public func ffSetActive(_ on: Bool) throws { try setActive(on) }
}
#endif
