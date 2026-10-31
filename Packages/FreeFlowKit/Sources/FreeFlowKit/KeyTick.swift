import Foundation

/// How each key press on the Free Flow keyboard feels: one short haptic click, shaped per key.
///
/// A click is a Core Haptics transient with an intensity (how strong) and a sharpness (crisp tick vs. dull
/// thud). Letters are crisp and short, space is softer, return and the mic are firmer and duller, delete is a
/// short tick that stays distinct when repeated.
///
/// Pressure: iPhones since iPhone 11 have no pressure sensor (3D Touch is gone), so how hard a key is pressed
/// cannot be measured. What iOS does report is the size of the finger's contact patch (UITouch.majorRadius),
/// which grows when a fingertip is pressed flatter. A flatter thumb angle grows it too, so it is a hint, not a
/// pressure reading. Scaling by it only engages once this device has reported clearly different sizes.
public enum KeyTick {
    public enum Kind: String, Sendable, CaseIterable { case letter, space, enter, delete, modifier, mic }

    public enum Level: Int, CaseIterable, Identifiable, Sendable {
        case off = 0, light, medium, strong
        public var id: Int { rawValue }
        public var title: String { ["Off", "Light", "Medium", "Strong"][rawValue] }
        /// Multiplies every click's intensity.
        public var scale: Double { [0, 0.6, 1.0, 1.35][rawValue] }
    }

    public struct Event: Equatable, Sendable {
        public var time: Double, intensity: Double, sharpness: Double
    }

    /// The click for each key at Medium, before speed and contact-size scaling.
    public static func design(_ kind: Kind) -> [Event] {
        switch kind {
        case .letter: [Event(time: 0, intensity: 0.55, sharpness: 0.85)]
        case .space: [Event(time: 0, intensity: 0.45, sharpness: 0.45)]
        case .enter: [Event(time: 0, intensity: 0.80, sharpness: 0.30)]
        case .delete: [Event(time: 0, intensity: 0.50, sharpness: 0.70)]
        case .modifier: [Event(time: 0, intensity: 0.45, sharpness: 0.60)]
        // Firm low thud, then a faint crisp tail 35 ms later: unlike any typing key.
        case .mic: [Event(time: 0, intensity: 0.85, sharpness: 0.30), Event(time: 0.035, intensity: 0.35, sharpness: 0.80)]
        }
    }

    /// Fast typing: clicks closer than 120 ms apart get lighter (down to 55%) so a burst does not blur into a buzz.
    public static func paceFactor(gap: Double) -> Double {
        guard gap < 0.12 else { return 1 }
        return min(1, max(0.55, 0.55 + 0.45 * (gap - 0.04) / 0.08))
    }

    /// The events to play: design x level x pace x contact size, intensities kept in 0.05...1.
    public static func events(_ kind: Kind, level: Level, gap: Double, sizeFactor: Double = 1) -> [Event] {
        guard level != .off else { return [] }
        let k = level.scale * paceFactor(gap: gap) * sizeFactor
        return design(kind).map { Event(time: $0.time, intensity: min(1, max(0.05, $0.intensity * k)), sharpness: $0.sharpness) }
    }
}

/// The finger contact sizes (UITouch.majorRadius, in points) of the last presses on this device.
public struct ContactSizes: Sendable {
    public private(set) var recent: [Double]
    public private(set) var tolerance = 0.0
    public private(set) var touches = 0
    /// Touches that reported a non-zero UITouch.force (a pressure reading). Zero on iPhones without 3D Touch.
    public private(set) var forceSeen = 0
    public let capacity: Int

    public init(recent: [Double] = [], capacity: Int = 64) {
        self.capacity = capacity
        self.recent = Array(recent.filter { $0 > 0 }.suffix(capacity))
    }

    public mutating func add(radius: Double, tolerance: Double, force: Double) {
        touches += 1
        if force > 0 { forceSeen += 1 }
        guard radius > 0 else { return }
        recent.append(radius)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        self.tolerance = tolerance
    }

    /// Distinct sizes seen (iOS reports contact size in coarse steps).
    public var distinct: Int { Set(recent.map { ($0 * 100).rounded() }).count }
    /// 10th and 90th percentile of the recent sizes, so one odd touch does not set the range.
    public var low: Double { percentile(0.1) }
    public var high: Double { percentile(0.9) }
    /// True when this person's presses differ in size by more than iOS's stated tolerance.
    public var varies: Bool { recent.count >= 8 && distinct >= 2 && high - low > max(tolerance, 0.5) }

    /// 0.75x at this person's smallest usual contact, 1.25x at the largest, 1x when sizes do not vary.
    public func factor(for radius: Double) -> Double {
        guard varies, radius > 0 else { return 1 }
        return 0.75 + 0.5 * min(1, max(0, (radius - low) / (high - low)))
    }

    private func percentile(_ p: Double) -> Double {
        guard !recent.isEmpty else { return 0 }
        let s = recent.sorted()
        return s[Int((Double(s.count - 1) * p).rounded())]
    }
}
