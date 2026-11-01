import Accelerate
import AVFoundation
import FreeFlowKit

/// Captures 16 kHz mono audio. The engine runs for the whole session (so the keyboard can start
/// instantly), but samples are kept only between begin() and end(): in memory for the model, and chunk by
/// chunk through `onChunk` to the clip on disk (ClipRecorder), so a call, an X or a crash can't lose them.
/// With FF_AUDIO_FILE set (simulator tests), a recorded file is fed through the same path in real time
/// instead of the microphone.
final class AudioCapture: @unchecked Sendable {
    static let rate: Double = 16_000
    private var engine = AVAudioEngine()
    /// Build 26: every engine start, stop and rebuild runs here, in order, never on the main thread for the Mac's fn
    /// (startAsync / stopAsync): a Bluetooth mic's start took ~445 ms on the main thread in build 25, which also runs
    /// the fn key tap and the pill. The sync start() / stop() wait on it (the iPhone app's path, unchanged).
    private let control = DispatchQueue(label: "freeflow.audio.control", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var collecting = false
    private var samples: [Float] = []
    private var fileSamples: [Float]?
    private var fileTimer: DispatchSourceTimer?
    private var filePosition = 0
    private(set) var running = false
    /// Build 26 (ColdStart): while Free Flow waits for the trip back, the mic's last seconds in memory only; guarded by
    /// `lock`. Nothing else is kept while armed, and the ring is emptied when the dictation starts or the arming ends.
    private var ring = PreRollRing(capacity: Int(rate * ColdStart.ringSeconds))
    private var ringOn = false
    /// Build 26 (Mac): seconds of audio kept from just before begin() while the mic is already on (Keep mic ready
    /// on), so a word said a moment before fn is pressed is not cut. 0 (the iPhone app) keeps nothing from before begin().
    var preroll: Double = 0
    /// The last `preroll` seconds while not collecting, in a ring (Mac); guarded by `lock`.
    private var macRing: [Float] = []
    private var macRingNext = 0
    private var macRingFull = false
    /// Build 26: when (ProcessInfo.systemUptime) the engine's latest start returned, its first buffer arrived and its
    /// first non-zero sample arrived; guarded by `lock`. A Bluetooth mic sends exact zeros for a while after it starts.
    private var startedAt: Double?
    private var firstBufferAt: Double?
    private var firstSoundAt: Double?
    /// Build 26 (Mac): a mic picked in Settings records through the Mac plug-in's own input unit (the Catalyst audio
    /// session records only the system default), set by Catalyst/MacHost: start(uid, onAudio) returns "" once it runs,
    /// else why not; onAudio brings mono Float32 samples, their count and rate on the audio thread.
    var externalStart: ((String, @escaping (UnsafePointer<Float>, Int, Double) -> Void) -> String)?
    var externalStop: (() -> Void)?
    /// The uid recording through the plug-in now; nil when the engine (the default input) records. Control queue.
    private(set) var externalUID: String?
    var isExternal: Bool { control.sync { externalUID != nil } }
    private var externalConverter: AVAudioConverter?
    private var externalIn: AVAudioPCMBuffer?
    private var externalRate: Double = 0
    var onLevel: ((Float) -> Void)?
    /// The listening bars' level: remapped RMS with attack / release (LevelShaper); guarded by `lock`.
    private var shaper = LevelShaper()
    /// Every captured chunk while collecting, on the audio thread (goes to the clip writer's own queue).
    var onChunk: ((UnsafeBufferPointer<Float>) -> Void)?
    /// The converter's output, reused for every buffer (grown only if a buffer is ever bigger). Audio thread only.
    private var converted: AVAudioPCMBuffer?
    /// The buffer the converter's input block hands over; set just before each convert call. Audio thread only.
    private var pending: AVAudioPCMBuffer?
    /// Made once: a closure literal or method reference at the call site would build a new context every buffer.
    private lazy var feedPending: AVAudioConverterInputBlock = { [unowned self] _, status in
        guard let buffer = self.pending else { status.pointee = .noDataNow; return nil }
        self.pending = nil
        status.pointee = .haveData
        return buffer
    }

    init(testFile: URL?) {
        if let testFile { fileSamples = try? Self.read(testFile) }
    }

    var usesTestFile: Bool { fileSamples != nil }

    /// Simulator UI tests only (FF_TEST_REAL_SESSION=1 with FF_AUDIO_FILE): the session and the mic engine run as on a
    /// device, so iOS keeps Free Flow running in the background the same way (UIBackgroundModes audio), but the samples
    /// still come from the test file. Without it nothing holds the app awake in the background and the simulator suspends
    /// it mid-dictation (build 26 RT1: "heartbeat gap 9.0s phase=listening", 3 s of an 11 s clip). No effect on a device:
    /// iOS apps get no environment from people.
    static let holdsRealSession = ProcessInfo.processInfo.environment["FF_TEST_REAL_SESSION"] == "1"
    /// The real mic engine runs: always on a device, and with the test file only under holdsRealSession.
    private var runsEngine: Bool { !usesTestFile || Self.holdsRealSession }

    /// True when a notification's object is this capture's engine (AVAudioEngineConfigurationChange is posted per engine).
    func owns(_ object: Any?) -> Bool { let e = lock.withLock { engine }; return (object as AnyObject?) === e }

    func start() throws { try control.sync { try startNow() } }

    /// Build 26: `prepare` (the audio session) and the engine start on the control queue; the caller's thread is free.
    func startAsync(prepare: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            control.async {
                do { try prepare(); try self.startNow(); done.resume() } catch { done.resume(throwing: error) }
            }
        }
    }

    /// Build 26 (Mac): records from the plug-in's input `uid` instead of the engine, on the control queue.
    func startAsync(external uid: String) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            control.async {
                do { try self.startExternalNow(uid); done.resume() } catch { done.resume(throwing: error) }
            }
        }
    }

    private func startExternalNow(_ uid: String) throws {
        guard !running else { return }
        guard let start = externalStart else { throw FFError("This microphone can't be used here.") }
        lock.withLock { startedAt = nil; firstBufferAt = nil; firstSoundAt = nil; clearRing() }
        let why = start(uid) { [weak self] samples, count, rate in self?.ingestExternal(samples, count, rate) }
        guard why.isEmpty else { throw FFError(why) }
        lock.withLock { startedAt = ProcessInfo.processInfo.systemUptime }
        externalUID = uid
        running = true
    }

    /// Audio thread (the plug-in's): to 16 kHz mono, then the same path as the engine's buffers.
    private func ingestExternal(_ samples: UnsafePointer<Float>, _ count: Int, _ rate: Double) {
        if rate == Self.rate { ingest(UnsafeBufferPointer(start: samples, count: count)); return }
        if externalConverter == nil || externalRate != rate {
            // Made once per rate (a device's rate changes only when it changes mode).
            guard let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
            externalConverter = AVAudioConverter(from: from, to: target)
            externalIn = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: 16_384)
            externalRate = rate
        }
        guard let input = externalIn, let converter = externalConverter, count <= Int(input.frameCapacity),
              let channel = input.floatChannelData?[0] else { return }
        channel.update(from: samples, count: count)
        input.frameLength = AVAudioFrameCount(count)
        convert(input, with: converter)
    }

    /// Build 26: stop, then `after` (the audio session off), on the control queue; a start asked for later waits for it.
    func stopAsync(after: (() -> Void)? = nil) {
        control.async { self.stopNow(); after?() }
    }

    /// (start, first buffer, first non-zero sample) of the latest start, as ProcessInfo.systemUptime.
    var startTimes: (started: Double?, buffer: Double?, sound: Double?) {
        lock.withLock { (startedAt, firstBufferAt, firstSoundAt) }
    }

    private func startNow() throws {
        guard !running else { return }
        if !runsEngine { running = true; return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw FFError("No microphone is available.")
        }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        let fromFile = usesTestFile
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            if fromFile { return }   // holdsRealSession: the mic only holds the session; the file is what is heard
            self.convert(buffer, with: converter)
        }
        lock.withLock { startedAt = nil; firstBufferAt = nil; firstSoundAt = nil; clearRing() }
        engine.prepare()
        try engine.start()
        lock.withLock { startedAt = ProcessInfo.processInfo.systemUptime }
        running = true
    }

    func stop() { control.sync { stopNow() } }

    private func stopNow() {
        stopFileFeed()
        if externalUID != nil {
            externalStop?()
            externalUID = nil
        } else if runsEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false
        lock.withLock { clearRing() }
    }

    /// After iOS resets its media services every audio object is dead; start again from a new engine.
    func rebuild() {
        control.sync {
            stopFileFeed()
            let fresh = AVAudioEngine()
            lock.withLock { engine = fresh }
            converter = nil
            running = false
        }
    }

    /// Restart after an interruption or a route change.
    func restart() throws {
        stop()
        try start()
    }

    /// Build 26: keep (or stop keeping) the armed mic's last ColdStart.ringSeconds for a pre-roll. With the test file,
    /// silence goes through the same path while armed (the scripted speaker talks once the keyboard listens).
    func armPreRoll(_ on: Bool) {
        lock.lock()
        let was = ringOn
        ringOn = on
        ring.reset()
        let busy = collecting
        lock.unlock()
        guard usesTestFile, !busy, on != was else { return }
        if on { startFileFeed(silent: true) } else { stopFileFeed() }
    }

    /// Samples in the pre-roll ring now.
    var preRollBuffered: Int { lock.lock(); defer { lock.unlock() }; return ring.count }

    /// Starts keeping samples. `preRoll`: that many of the ring's newest samples go first (ColdStart), to memory and to
    /// the clip, before anything the audio thread delivers next (both happen under the lock the audio thread takes).
    func begin(preRoll: Int = 0) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.rate) * 30)   // 30 s before the first regrowth copy on the audio thread
        let pre = preRoll > 0 ? ring.last(preRoll) : []
        ringOn = false
        ring.reset()
        if !pre.isEmpty {
            samples.append(contentsOf: pre)
            pre.withUnsafeBufferPointer { onChunk?($0) }
        }
        // Build 26 (Mac): what the mic heard just before (only when it was already on), oldest first. Built apart from
        // `samples` so the audio thread's next append never has to copy a shared buffer.
        var before: [Float] = []
        if macRingFull { before.append(contentsOf: macRing[macRingNext...]) }
        before.append(contentsOf: macRing[..<macRingNext])
        samples.append(contentsOf: before)
        clearRing()
        collecting = true
        lock.unlock()
        if !before.isEmpty { before.withUnsafeBufferPointer { onChunk?($0) } }
        if usesTestFile { startFileFeed() }
    }

    /// Under `lock`.
    private func clearRing() {
        let n = Int(Self.rate * max(0, preroll))
        if macRing.count != n { macRing = [Float](repeating: 0, count: n) }
        macRingNext = 0
        macRingFull = false
    }

    /// Samples kept since begin(), read while recording (the Mac mic test).
    var collectedCount: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    /// RMS of the samples kept from `start` on, and how many of them are exactly zero (the Mac mic test).
    func level(from start: Int) -> (rms: Float, zeros: Int) {
        lock.lock(); defer { lock.unlock() }
        guard start < samples.count else { return (0, 0) }
        var sum: Float = 0, zeros = 0
        for v in samples[start...] { sum += v * v; if v == 0 { zeros += 1 } }
        return ((sum / Float(samples.count - start)).squareRoot(), zeros)
    }

    func end() -> [Float] {
        lock.lock()
        collecting = false
        let out = samples
        samples = []
        lock.unlock()
        stopFileFeed()
        return out
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        if converted == nil || converted!.frameCapacity < capacity {
            converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(capacity, 8192))
        }
        guard let out = converted else { return }
        out.frameLength = 0
        pending = buffer
        var error: NSError?
        converter.convert(to: out, error: &error, withInputFrom: feedPending)
        pending = nil
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        ingest(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// On the audio thread, per buffer: keep the samples (in memory for the model, chunk to the clip), one vDSP RMS
    /// for the level. Allocations here: the samples array's own growth and the clip chunk's one Data (ClipWriter.append).
    private func ingest(_ chunk: UnsafeBufferPointer<Float>) {
        guard let base = chunk.baseAddress, !chunk.isEmpty else { return }
        lock.lock()
        if firstBufferAt == nil { firstBufferAt = ProcessInfo.processInfo.systemUptime }
        if firstSoundAt == nil, chunk.contains(where: { $0 != 0 }) { firstSoundAt = ProcessInfo.processInfo.systemUptime }
        let active = collecting
        if active {
            samples.append(contentsOf: chunk)
        } else {
            if ringOn { ring.write(chunk) }                  // iOS cold start (ColdStart)
            if !macRing.isEmpty { keepInRing(chunk) }        // Mac Keep mic ready (preroll)
        }
        lock.unlock()
        guard active else { return }
        onChunk?(chunk)
        var rms: Float = 0
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(chunk.count))
        lock.lock()
        let level = shaper.next(rms: rms)
        lock.unlock()
        onLevel?(level)
    }

    /// Under `lock`, audio thread: the newest samples over the oldest, no allocation.
    private func keepInRing(_ chunk: UnsafeBufferPointer<Float>) {
        let n = macRing.count
        var src = chunk.count > n ? chunk.count - n : 0
        while src < chunk.count {
            let k = min(n - macRingNext, chunk.count - src)
            macRing.withUnsafeMutableBufferPointer { r in
                (r.baseAddress! + macRingNext).update(from: chunk.baseAddress! + src, count: k)
            }
            src += k
            macRingNext += k
            if macRingNext == n { macRingNext = 0; macRingFull = true }
        }
    }

    // MARK: Test file source (simulator only use)

    private func startFileFeed(silent: Bool = false) {
        stopFileFeed()
        filePosition = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        // 50 ms of the file per tick = real time. UI tests only: FF_AUDIO_FEED_SPEED feeds N ticks' worth per tick, so a
        // 38-minute recording goes through the same capture path in a few minutes (long-recording test testL1).
        let speed = max(1, Int(ProcessInfo.processInfo.environment["FF_AUDIO_FEED_SPEED"] ?? "") ?? 1)
        let step = Int(Self.rate / 20) * speed
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        // One chunk buffer for the feed's life (silence after the file ends), like the mic path: no allocation per tick.
        let chunk = UnsafeMutableBufferPointer<Float>.allocate(capacity: step)
        chunk.initialize(repeating: 0)
        timer.setEventHandler { [weak self] in
            guard let self, let file = self.fileSamples else { return }
            let n = silent ? 0 : max(0, min(step, file.count - self.filePosition))
            file.withUnsafeBufferPointer { src in
                if n > 0 { chunk.baseAddress!.update(from: src.baseAddress! + self.filePosition, count: n) }
            }
            if n < step { (chunk.baseAddress! + n).update(repeating: 0, count: step - n) }
            self.filePosition += n
            self.ingest(UnsafeBufferPointer(chunk))
        }
        timer.setCancelHandler { chunk.deallocate() }
        fileTimer = timer
        timer.resume()
    }

    private func stopFileFeed() {
        fileTimer?.cancel()
        fileTimer = nil
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        if format.sampleRate == rate, format.channelCount == 1, let ch = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * rate / format.sampleRate + 64)) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}

struct FFError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
