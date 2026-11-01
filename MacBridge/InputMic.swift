import AudioToolbox
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "freeflow.mac", category: "mic")

/// Build 26: records from one picked input device through a HAL input unit (kAudioUnitSubType_HALOutput, input only).
/// The Catalyst app's audio session records only the system's default input (it lists no inputs to choose from, and its
/// engine's input unit refuses a device: -10879, measured 10-31), so a mic picked in Settings records here and its
/// samples go to the app's capture. Mono Float32 at the device's own rate, on the HAL's I/O thread. When the device's
/// rate changes under it (a Bluetooth headset moving to call mode), the unit starts again at the new rate.
final class InputMic: @unchecked Sendable {
    private let lock = NSLock()
    private var unit: AudioUnit?
    private var device: AudioDeviceID = 0
    private var rate: Double = 48_000
    private var onAudio: ((UnsafePointer<Float>, Int, Double) -> Void)?
    private var list = AudioBufferList()
    private var data = [Float](repeating: 0, count: 16_384)
    private let queue = DispatchQueue(label: "freeflow.mac.inputmic")
    private var listening = false

    /// "" when it started, else why not.
    func start(uid: String, _ onAudio: @escaping (UnsafePointer<Float>, Int, Double) -> Void) -> String {
        stop()
        guard let id = AudioDevices.device(uid: uid) else { return "That microphone is not connected" }
        device = id
        lock.withLock { self.onAudio = onAudio }
        do { try open() } catch { stop(); return "\(error)" }
        var a = rateAddress
        AudioObjectAddPropertyListener(id, &a, rateChanged, Unmanaged.passUnretained(self).toOpaque())
        listening = true
        log.log("input mic started: \(AudioDevices.name(id), privacy: .public) at \(Int(self.rate), privacy: .public) Hz")
        return ""
    }

    func stop() {
        if listening {
            var a = rateAddress
            AudioObjectRemovePropertyListener(device, &a, rateChanged, Unmanaged.passUnretained(self).toOpaque())
            listening = false
        }
        close()
        lock.withLock { onAudio = nil }
    }

    private var rateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    fileprivate func restartAfterRateChange() {
        queue.async { [weak self] in
            guard let self, self.listening else { return }
            self.close()
            do { try self.open(); log.log("input mic restarted at \(Int(self.rate), privacy: .public) Hz") }
            catch { log.error("input mic restart failed: \(String(describing: error), privacy: .public)") }
        }
    }

    private func open() throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw MicError("no HAL unit") }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "new")
        guard let u else { throw MicError("no unit") }
        lock.withLock { unit = u }
        var one: UInt32 = 1, zero: UInt32 = 0, dev = device
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)), "device")
        var hw = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "device format")
        guard hw.mSampleRate > 0 else { throw MicError("device has no rate") }
        rate = hw.mSampleRate
        var client = AudioStreamBasicDescription(mSampleRate: hw.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                                 mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "format")
        var cb = AURenderCallbackStruct(inputProc: { ref, flags, stamp, bus, frames, _ in
            Unmanaged<InputMic>.fromOpaque(ref).takeUnretainedValue().render(flags, stamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "callback")
        try check(AudioUnitInitialize(u), "initialize")
        try check(AudioOutputUnitStart(u), "start")
    }

    private func close() {
        guard let u = lock.withLock({ () -> AudioUnit? in defer { unit = nil }; return unit }) else { return }
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
    }

    /// HAL I/O thread: no allocation, no lock held while the app's capture runs.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ stamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        let (unit, onAudio) = lock.withLock { (self.unit, self.onAudio) }
        guard let u = unit, let onAudio, Int(frames) <= data.count else { return noErr }
        let rate = self.rate
        return data.withUnsafeMutableBufferPointer { buf -> OSStatus in
            list.mNumberBuffers = 1
            list.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(buf.baseAddress))
            let st = AudioUnitRender(u, flags, stamp, bus, frames, &list)
            guard st == noErr, let base = buf.baseAddress else { return st }
            onAudio(base, Int(frames), rate)
            return noErr
        }
    }

    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw MicError("\(what) failed (\(st))") }
    }
}

private struct MicError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

private func rateChanged(_ id: AudioObjectID, _ n: UInt32, _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                         _ ref: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ref else { return noErr }
    Unmanaged<InputMic>.fromOpaque(ref).takeUnretainedValue().restartAfterRateChange()
    return noErr
}
