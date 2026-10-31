import CoreAudio
import Foundation

/// The system's audio input devices (CoreAudio): the mic name for Where it runs, and the mic test's switch.
/// Compiled into the Mac app and into the Catalyst app's AppKit plug-in (FF_MAC_BRIDGE).
enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInput() -> AudioDeviceID {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    static func setDefaultInput(_ id: AudioDeviceID) {
        var v = id
        var a = address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
    }

    static func inputs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids.filter { id in
            var s = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var n: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n)
            return n > 0
        }
    }

    /// Where --switch moves the default input: the Mac's built-in mic, or from it a Bluetooth or USB input. Never a
    /// Continuity device (an iPhone's mic).
    static func switchTarget(from original: AudioDeviceID) -> AudioDeviceID? {
        let others = inputs().filter { $0 != original }
        let builtIn = others.first { transport($0) == kAudioDeviceTransportTypeBuiltIn }
        if transport(original) != kAudioDeviceTransportTypeBuiltIn { return builtIn }
        let ok: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB]
        return others.first { ok.contains(transport($0)) }
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 {
        var a = address(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        return t
    }

    static func name(_ id: AudioDeviceID) -> String {
        var a = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return "device \(id)" }
        return n as String
    }
}
