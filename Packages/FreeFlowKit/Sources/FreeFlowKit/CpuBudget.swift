import Foundation

/// Keeps a process under iOS's background CPU limit. iOS kills a background app that uses more than 80% of one CPU core
/// over 60 s ("cpu_resource_fatal" on an iPad, build 8, 2026-10-29: "48 seconds cpu time over 48 seconds (99% cpu average),
/// exceeding limit of 80% cpu over 60 seconds"). Apple: "Identifying the cause of common crashes" (EXC_RESOURCE, CPU
/// limits) and WWDC20 "Why is my app getting killed?" (background CPU usage). Core ML runs on the Neural Engine; the
/// C++ (ggml) fallback runs on the CPU in the background (iOS refuses GPU work from a background app), so its work is
/// paced with this budget.
///
/// Samples are (wall seconds, process CPU seconds), CPU = getrusage user + system of every thread. `limit` is the
/// share of one core allowed over the trailing `window`, set well under 80%.
public struct CpuBudget {
    public let limit: Double
    public let window: TimeInterval
    private var samples: [(t: Double, cpu: Double)] = []

    public init(limit: Double = 0.5, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    public var allowed: Double { limit * window }

    public mutating func record(t: Double, cpu: Double) {
        if let last = samples.last, t <= last.t { return }
        samples.append((t, cpu))
        // keep one sample older than the window, for the window's start
        while samples.count > 2, samples[1].t <= t - window { samples.removeFirst() }
    }

    /// CPU seconds used in (t - window, t]. Before the first sample nothing is known: that time is counted at the
    /// limit, so a fresh budget starts cautious instead of trusting an empty history.
    public func used(t: Double, cpu: Double) -> Double {
        guard let first = samples.first else { return allowed }
        let start = t - window
        if first.t > start { return (cpu - first.cpu) + (first.t - start) * limit }
        return cpu - cpuAt(start)
    }

    /// Seconds to wait (doing nothing) before work that will cost `cost` CPU seconds, so the trailing window stays
    /// within the limit. 0 = go now.
    public func wait(t: Double, cpu: Double, cost: Double) -> TimeInterval {
        let need = used(t: t, cpu: cpu) + cost - allowed
        guard need > 0 else { return 0 }
        // Waiting w seconds drops the CPU used in (t - window, t - window + w] out of the window.
        var w: TimeInterval = 1
        while w < window {
            let dropped = cpuAt(t - window + w) - cpuAt(t - window)
            let unknown = max(0, min(w, (samples.first?.t ?? t) - (t - window))) * limit
            if dropped + unknown >= need { return w }
            w += 1
        }
        return window
    }

    private func cpuAt(_ time: Double) -> Double {
        guard let first = samples.first else { return 0 }
        if time <= first.t { return first.cpu }
        for i in 1..<max(samples.count, 1) where i < samples.count {
            let a = samples[i - 1], b = samples[i]
            if time <= b.t { return a.cpu + (b.cpu - a.cpu) * (time - a.t) / max(b.t - a.t, 1e-9) }
        }
        return samples.last!.cpu
    }
}
