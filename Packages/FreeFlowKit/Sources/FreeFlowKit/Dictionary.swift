import Foundation

/// A word the speech models should listen for. The models lean toward it while they decode; nothing
/// rewrites the text afterwards. `heardAs` (a "sounds like" list from builds 1-9) is still read from saved
/// files so nothing is lost, but nothing uses it.
public struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var word: String
    public var heardAs: [String]

    public init(id: UUID = UUID(), word: String, heardAs: [String] = []) {
        self.id = id
        self.word = word
        self.heardAs = heardAs
    }

    private enum CodingKeys: String, CodingKey { case id, word, heardAs }

    /// Files from builds 1-9 carry `heardAs`; newer entries may not. Both decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        heardAs = try c.decodeIfPresent([String].self, forKey: .heardAs) ?? []
    }
}

/// The personal dictionary, stored as JSON in the App Group on this device.
public final class DictionaryStore: ObservableObject, @unchecked Sendable {
    public static let shared = DictionaryStore()
    @Published public private(set) var entries: [DictionaryEntry] = []
    private let url: URL

    public init(url: URL = FF.containerURL.appendingPathComponent("dictionary.json")) {
        self.url = url
        reload()
    }

    public func reload() {
        entries = (try? JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))) ?? []
    }

    public func add(word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !entries.contains(where: { $0.word.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        entries.append(DictionaryEntry(word: w))
        save()
    }

    /// The words, in the order they were added, for the speech models.
    public var words: [String] { DictionaryStore.words(entries) }

    public static func words(_ entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
