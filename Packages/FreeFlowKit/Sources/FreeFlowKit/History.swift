import Foundation

public struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var raw: String
    public var style: DictationStyle
    public var model: String
    public var audioSeconds: Double
    public var processSeconds: Double
    /// Who wrote the text (WritingReadout.short), e.g. "Written by Apple Intelligence · 0.9 s" or "As heard · time limit 4.7 s".
    /// nil for dictations saved before build 18.
    public var writer: String?

    public init(id: UUID = UUID(), date: Date = Date(), text: String, raw: String, style: DictationStyle,
                model: String, audioSeconds: Double, processSeconds: Double, writer: String? = nil) {
        self.id = id; self.date = date; self.text = text; self.raw = raw; self.style = style
        self.model = model; self.audioSeconds = audioSeconds; self.processSeconds = processSeconds; self.writer = writer
    }
}

/// Dictation history (text only). Lives only on this device and is excluded from iCloud backup. Audio that didn't
/// finish is kept separately, on this device only (Recordings.swift).
public final class HistoryStore: ObservableObject, @unchecked Sendable {
    public static let shared = HistoryStore()
    @Published public private(set) var items: [HistoryItem] = []
    private let url: URL
    public static let limit = 500

    public init(url: URL = FF.containerURL.appendingPathComponent("history.json")) {
        self.url = url
        items = (try? JSONDecoder().decode([HistoryItem].self, from: Data(contentsOf: url))) ?? []
    }

    public func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    public func remove(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) }; save() }
    public func clear() { items = []; save() }

    private func save() {
        try? JSONEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtection])
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
