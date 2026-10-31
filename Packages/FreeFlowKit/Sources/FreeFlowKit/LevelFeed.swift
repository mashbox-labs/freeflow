import Foundation

/// The mic level meter's data path, built for iOS's background CPU limit. iOS killed build 8 twice on an iPad
/// (cpu_resource_fatal, 2026-10-29: 48 s of CPU in 48 s, every sample on the main thread in SwiftUI view
/// updates) while it recorded in the background: every audio buffer changed a @Published array twice and re-rendered
/// the app. Apple: "Preparing your UI to run in the background" (stop UI updates in the background) and the Energy
/// Efficiency Guide for iOS Apps (do the least work in the background; avoid timers and updates nobody sees).
///
/// Every level goes into a fixed ring (no publish). The app's own meter gets one snapshot at most `uiHz` times a second,
/// and only while the app is active. The keyboard's copy (App Group) is written at most `sharedHz` times a second, and
/// only while the keyboard says it is on screen.
public struct LevelFeed {
    public let count: Int
    public let uiInterval: TimeInterval
    public let sharedInterval: TimeInterval
    private var ring: [Float]
    private var head = 0
    private var lastUI = -Double.infinity
    private var lastShared = -Double.infinity

    public init(count: Int = 40, uiHz: Double = 10, sharedHz: Double = 10) {
        self.count = count
        uiInterval = 1 / uiHz
        sharedInterval = 1 / sharedHz
        ring = [Float](repeating: 0, count: count)
    }

    /// Oldest first.
    public var snapshot: [Float] { Array(ring[head...] + ring[..<head]) }

    public mutating func reset() {
        ring = [Float](repeating: 0, count: count)
        head = 0
        lastUI = -.infinity
        lastShared = -.infinity
    }

    public struct Out: Equatable {
        /// A snapshot for the app's meter, or nil (not due, or the app is not active).
        public var ui: [Float]?
        /// A snapshot for the keyboard, or nil (not due, or the keyboard is not on screen).
        public var shared: [Float]?
    }

    /// `keyboardShowing` is asked only when a keyboard write is due.
    public mutating func push(_ level: Float, now: TimeInterval, appActive: Bool, keyboardShowing: () -> Bool) -> Out {
        ring[head] = level
        head = (head + 1) % count
        var out = Out()
        if appActive, now - lastUI >= uiInterval * 0.999 {
            lastUI = now
            out.ui = snapshot
        }
        if now - lastShared >= sharedInterval * 0.999, keyboardShowing() {
            lastShared = now
            out.shared = snapshot
        }
        return out
    }
}

/// The keyboard writes `keyboard.upAt` every 0.5 s while it is on screen (KeyboardModel.poll) and clears it when hidden.
public enum KeyboardPresence {
    public static func isShowing(upAt: Date?, now: Date) -> Bool {
        guard let upAt else { return false }
        return now.timeIntervalSince(upAt) < 1.5
    }
}
