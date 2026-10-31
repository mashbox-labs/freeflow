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
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var collecting = false
    private var samples: [Float] = []
    private var fileSamples: [Float]?
    private var fileTimer: DispatchSourceTimer?
    private var filePosition = 0
    private(set) var running = false
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

    /// True when a notification's object is this capture's engine (AVAudioEngineConfigurationChange is posted per engine).
    func owns(_ object: Any?) -> Bool { (object as AnyObject?) === engine }

    func start() throws {
        guard !running else { return }
        if usesTestFile { running = true; return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw FFError("No microphone is available.")
        }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        stopFileFeed()
        if !usesTestFile {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false
    }

    /// After iOS resets its media services every audio object is dead; start again from a new engine.
    func rebuild() {
        stopFileFeed()
        engine = AVAudioEngine()
        converter = nil
        running = false
    }

    /// Restart after an interruption or a route change.
    func restart() throws {
        stop()
        try start()
    }

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.rate) * 30)   // 30 s before the first regrowth copy on the audio thread
        collecting = true
        lock.unlock()
        if usesTestFile { startFileFeed() }
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

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
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
        let active = collecting
        if active { samples.append(contentsOf: chunk) }
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

    // MARK: Test file source (simulator only use)

    private func startFileFeed() {
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
            let n = max(0, min(step, file.count - self.filePosition))
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
