import Foundation

/// Build 28: a small log of the writing step for test builds, shared by the app and the keyboard (App Group file
/// writing-diagnostics.jsonl, this device only). Each line is counts, times and states: which process wrote the text,
/// requests, pieces written or kept as heard, rateLimited and Apple's reset time, milliseconds, word counts, memory.
/// Never words of a dictation, never audio. Settings > Test build > Export diagnostics shares it.
public enum WriteDiagnostics {
    public static var url: URL { FF.containerURL.appendingPathComponent("writing-diagnostics.jsonl") }
    /// Kept to about this size: past it, the older half goes.
    public static let maxBytes = 512 * 1024

    /// Appends one line. `who` is the writer route ("app-fg", "app-bg", "kbd", "probe", ...), `event` what happened.
    public static func note(_ who: String, _ event: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["at"] = ISO8601DateFormatter().string(from: Date())
        row["who"] = who
        row["event"] = event
        guard JSONSerialization.isValidJSONObject(row),
              var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let path = url.path
        // One write() per line with O_APPEND, so the app and the keyboard can both add lines.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let size = lseek(fd, 0, SEEK_END)
        close(fd)
        if size > maxBytes { trim() }
    }

    /// The log as text, newest last, under a header (app version and build, device, OS).
    public static func export(header: String) -> String {
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return header + "\n" + body
    }

    public static func clear() { try? FileManager.default.removeItem(at: url) }

    private static func trim() {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        let keep = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? keep.write(to: url, atomically: true, encoding: .utf8)
    }
}
