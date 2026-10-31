import Foundation

/// Proof that the keyboard really has Allow Full Access on this device: a small file the keyboard writes into the
/// App Group folder. A keyboard without Full Access has no access to that folder, so the write only lands with it.
/// The app reads the file fresh each time (no preferences cache). This does not trust `hasFullAccess` alone: iOS
/// can report it as off while the keyboard is still starting, and setup must not wait on that.
public enum KeyboardProof {
    static let fileName = "keyboard-proof.plist"

    /// The App Group folder, or nil when this process cannot reach it. Never the app's own folder.
    public static var groupFolder: URL? {
        #if targetEnvironment(macCatalyst)
        return nil   // no keyboard extension on the Mac
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FF.appGroup)
        #endif
    }

    /// Called by the keyboard. `flag` is what iOS reported (`hasFullAccess`). Returns true when the proof file was
    /// written in the App Group folder, which needs Full Access.
    @discardableResult
    public static func record(flag: Bool, at date: Date = Date(), in folder: URL? = groupFolder) -> Bool {
        guard let folder else { return false }
        let body: [String: Any] = ["seen": date, "flag": flag]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: body, format: .binary, options: 0) else { return false }
        do {
            try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// When the keyboard last proved Full Access, and what iOS reported to it then. Nil when it never did.
    public static func read(in folder: URL? = groupFolder) -> (seen: Date, flag: Bool)? {
        guard let folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let body = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let seen = body["seen"] as? Date else { return nil }
        return (seen, body["flag"] as? Bool ?? false)
    }

    /// Forget the proof (tests start from a keyboard that never opened).
    public static func clear(in folder: URL? = groupFolder) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
    }
}
