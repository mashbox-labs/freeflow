import Foundation

/// The keyboard's key click check, counted on this device only: counts, no text, nothing leaves the device.
/// iOS gives no answer when a click is asked for, so "asked" is the most a keyboard can know. The other counts say
/// why a press had no click, and whether Free Flow's mic was ready at the time (iOS mutes haptics while audio input
/// records, unless the recording app allows them; Free Flow does from build 6).
public struct KeyClickCounts: Codable, Equatable, Sendable {
    public var presses = 0
    public var asked = 0
    public var askedWhileMic = 0
    public var noAccess = 0
    public var off = 0
    public var since: Date?
    public var last: Date?
    public init() {}

    public mutating func note(fullAccess: Bool, clicksOff: Bool, micReady: Bool, at date: Date = Date()) {
        presses += 1
        if !fullAccess { noAccess += 1 } else if clicksOff { off += 1 } else { asked += 1; if micReady { askedWhileMic += 1 } }
        if since == nil { since = date }
        last = date
    }

    public mutating func add(_ o: KeyClickCounts) {
        presses += o.presses; asked += o.asked; askedWhileMic += o.askedWhileMic; noAccess += o.noAccess; off += o.off
        if let s = o.since { since = min(since ?? s, s) }
        if let l = o.last { last = max(last ?? l, l) }
    }

    public var isEmpty: Bool { presses == 0 }

    /// One plain line for Settings.
    public var summary: String {
        guard presses > 0 else { return "No key presses counted yet. Type a few words with the Free Flow keyboard, then come back." }
        var s = "\(presses) key presses, \(asked) clicks asked of iOS"
        if asked > 0 { s += " (\(askedWhileMic) while the mic was ready)" }
        if noAccess > 0 { s += ", \(noAccess) with no Full Access seen" }
        if off > 0 { s += ", \(off) with clicks off" }
        return s + "."
    }

    static let storeKey = "keyboard.clickCounts"
    /// All keyboard sessions together, in the App Group (a keyboard can only write there with Full Access).
    public static var stored: KeyClickCounts {
        get { FF.defaults.data(forKey: storeKey).flatMap { try? JSONDecoder().decode(KeyClickCounts.self, from: $0) } ?? KeyClickCounts() }
        set { FF.defaults.set(try? JSONEncoder().encode(newValue), forKey: storeKey) }
    }

    /// Written by the app when it sets up the mic: does its session let haptics play while recording.
    public static var hapticsAllowedWhileMic: Bool? {
        get { FF.defaults.object(forKey: "audio.hapticsWhileRecording") as? Bool }
        set { FF.defaults.set(newValue, forKey: "audio.hapticsWhileRecording") }
    }
}
