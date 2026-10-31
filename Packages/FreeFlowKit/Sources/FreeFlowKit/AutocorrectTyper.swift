import Foundation
import os

private let acLog = Logger(subsystem: FF.subsystem, category: "autocorrect")

/// Words autocorrect must never change, whatever the word list says: contacts and text replacements (UILexicon),
/// the Free Flow Dictionary, and words put back with delete this session. Stored lowercase. Safe from any thread.
public final class AutocorrectAllowList: @unchecked Sendable {
    private let lock = NSLock()
    private var system: Set<String> = []
    private var dictionary: Set<String> = []
    private var putBack: Set<String> = []

    public init() {}

    /// UILexicon entries (`userInput`, `documentText`): contact names, text replacement shortcuts and phrases.
    public func setSystemLexicon(_ entries: [(userInput: String, documentText: String)]) {
        var s = Set<String>()
        for e in entries { s.formUnion(Self.words(e.userInput)); s.formUnion(Self.words(e.documentText)) }
        lock.lock(); system = s; lock.unlock()
    }

    /// The Free Flow Dictionary's words (DictionaryStore).
    public func setDictionary(_ words: [String]) {
        var s = Set<String>()
        for w in words { s.formUnion(Self.words(w)) }
        lock.lock(); dictionary = s; lock.unlock()
    }

    /// A word the person put back with delete right after it was corrected.
    public func putBack(_ word: String) {
        lock.lock(); putBack.insert(word.lowercased()); lock.unlock()
    }

    public func contains(_ lowercased: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return system.contains(lowercased) || dictionary.contains(lowercased) || putBack.contains(lowercased)
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return system.count + dictionary.count + putBack.count }

    /// The whole entry lowercased, plus each run of letters and digits in it ("MASHBOX Labs" -> "mashbox labs",
    /// "mashbox", "labs").
    static func words(_ text: String) -> Set<String> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return [] }
        var s: Set<String> = [t]
        for part in t.components(separatedBy: CharacterSet.alphanumerics.inverted) where !part.isEmpty { s.insert(part) }
        return s
    }
}

/// The keyboard side of autocorrect. The keyboard calls `didType` after each key that types a character, `space` in
/// place of typing a space, and `delete` before a single delete; each returns the text edit to make. Words are
/// looked up off the main thread while they are typed, so the space key normally only reads the ready answer.
///
/// Main thread: every method here. The word list loads and lookups run on a background queue.
public final class AutocorrectTyper: @unchecked Sendable {
    /// Delete this many characters before the cursor, then type `insert`.
    public struct Edit: Equatable, Sendable {
        public let deleteCount: Int
        public let insert: String
        public init(deleteCount: Int, insert: String) { self.deleteCount = deleteCount; self.insert = insert }
        public static let space = Edit(deleteCount: 0, insert: " ")
    }

    /// How a space decision was reached (the FFAC log line and the timing test).
    public enum Path: String, Sendable {
        case off        // autocorrect off, no word list, or the field turned autocorrection off
        case none       // no word before the cursor
        case guarded    // under 3 letters, not plain letters, camelCase, ALL CAPS, capital mid-sentence
        case known      // in the word list or the allow-list
        case cached     // looked up while it was typed
        case sync       // looked up on the space press (the background answer was not ready)
        case timedOut   // the space-press lookup ran out of time: word kept
    }

    public struct SpaceStat: Equatable, Sendable {
        public let path: Path
        public let ms: Double
        public let changed: Bool
        public let letters: Int
    }

    /// The word before the cursor: letters (plus anything else up to the previous whitespace), the trailing
    /// punctuation `.,!?;:` after it, and whether it starts a sentence (start of the visible text, or the word before it
    /// ends in exactly `.`, `!` or `?`, as the prototype's sentence rule).
    public struct WordAtCursor: Equatable, Sendable {
        public let word: String
        public let punct: String
        public let sentenceInitial: Bool
    }

    /// Settings > Keyboard > Autocorrect.
    public var enabled = true
    /// False when the text field asked for no autocorrection (or is a URL or email field).
    public var fieldAllows = true
    /// Longest the space press may spend looking a word up when the background answer is not ready; past it the word
    /// is kept. Under Apple's 5 ms main-thread guideline with room for the text edit itself.
    public var syncBudgetMs = 3.0
    public let allow = AutocorrectAllowList()
    public private(set) var lastSpace: SpaceStat?

    private let lock = NSLock()
    private var engineStore: AutocorrectEngine?
    private var generation: UInt64 = 0
    private var ready: (word: String, initial: Bool, outcome: AutocorrectOutcome)?
    private var undo: (typed: String, replaced: String, punct: String, key: String)?
    private let queue = DispatchQueue(label: FF.subsystem + ".autocorrect", qos: .userInitiated)

    public init(engine: AutocorrectEngine? = nil) { engineStore = engine }

    public var engine: AutocorrectEngine? {
        get { lock.lock(); defer { lock.unlock() }; return engineStore }
        set { lock.lock(); engineStore = newValue; ready = nil; lock.unlock() }
    }

    /// Loads the word list shipped in this build on a background queue (no list: autocorrect stays off and says so).
    public func loadBundledWordList() {
        queue.async { [weak self] in
            guard let url = AutocorrectLexicon.bundledURL else {
                acLog.info("FFAC no word list in this build: autocorrect is off")
                return
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                let lex = try AutocorrectLexicon(contentsOf: url)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                acLog.info("FFAC word list words=\(lex.wordCount, privacy: .public) nodes=\(lex.nodeCount, privacy: .public) memMB=\(Double(lex.memoryBytes) / 1e6, format: .fixed(precision: 2), privacy: .public) loadMs=\(ms, format: .fixed(precision: 1), privacy: .public)")
                // Build 17: the typing rule (key distance, doubled / dropped / swapped letters; AutocorrectTyping.swift).
                self?.engine = AutocorrectEngine(lexicon: lex, typing: .build12)
            } catch {
                acLog.error("FFAC word list failed to load: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: keys

    /// After a key typed a character (contextBefore includes it): look the word up off the main thread.
    public func didType(contextBefore: String) {
        undo = nil
        guard enabled, fieldAllows, let engine, let w = Self.wordAtCursor(contextBefore),
              engine.needsLookup(w.word, sentenceInitial: w.sentenceInitial, isAllowed: allow.contains) else { return }
        lock.lock()
        if let r = ready, r.word == w.word, r.initial == w.sentenceInitial { lock.unlock(); return }
        generation &+= 1
        let g = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stale = g != self.generation; self.lock.unlock()
            if stale { return }   // a newer key already asked for a newer word
            let t0 = DispatchTime.now().uptimeNanoseconds
            let outcome = engine.correct(w.word, sentenceInitial: w.sentenceInitial, isAllowed: self.allow.contains)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            self.lock.lock()
            if g == self.generation { self.ready = (w.word, w.sentenceInitial, outcome) }
            self.lock.unlock()
            acLog.debug("FFAC lookup thread=background ms=\(ms, format: .fixed(precision: 3), privacy: .public) letters=\(w.word.count, privacy: .public)")
        }
    }

    /// In place of typing a space: the edit that types the space, correcting the word before it when the rule says so.
    public func space(contextBefore: String) -> Edit { wordBreak(" ", contextBefore: contextBefore) }

    /// Keys that end a word: space, return and . , ! ? ; : (build 17: not only space).
    public static func endsWord(_ key: String) -> Bool { key == " " || key == "\n" || (key.count == 1 && punctuation.contains(key.first!)) }

    /// In place of typing `key` (space, return or punctuation): the edit that types it, correcting the word before it
    /// when the rule says so. The punctuation already typed after the word stays after the corrected word.
    public func wordBreak(_ key: String, contextBefore: String) -> Edit {
        let t0 = DispatchTime.now().uptimeNanoseconds
        undo = nil
        var path = Path.off
        let plain = Edit(deleteCount: 0, insert: key)
        var edit = plain
        var letters = 0
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            lastSpace = SpaceStat(path: path, ms: ms, changed: edit != plain, letters: letters)
        }
        guard enabled, fieldAllows, let engine else { return edit }
        guard let w = Self.wordAtCursor(contextBefore), !w.word.isEmpty else { path = .none; return edit }
        letters = w.word.count
        if engine.typing != nil {
            // The typing rule has its own guard (2-letter words are looked at) and may correct a rare listed word.
            if !engine.needsLookup(w.word, sentenceInitial: w.sentenceInitial, isAllowed: allow.contains) {
                path = AutocorrectEngine.isGuardedTyping(w.word, sentenceInitial: w.sentenceInitial) ? .guarded : .known
                return edit
            }
        } else {
            if AutocorrectEngine.isGuarded(w.word, sentenceInitial: w.sentenceInitial) { path = .guarded; return edit }
            let lower = w.word.lowercased()
            if engine.lexicon.contains(lower) || allow.contains(lower) { path = .known; return edit }
        }
        lock.lock()
        let cached = ready.flatMap { $0.word == w.word && $0.initial == w.sentenceInitial ? $0.outcome : nil }
        lock.unlock()
        let outcome: AutocorrectOutcome
        if let cached {
            path = .cached
            outcome = cached
        } else {
            let deadline = t0 + UInt64(max(0, syncBudgetMs) * 1e6)
            outcome = engine.correct(w.word, sentenceInitial: w.sentenceInitial, isAllowed: allow.contains, deadline: deadline)
            path = outcome == .timedOut ? .timedOut : .sync
        }
        guard case .replace(let r) = outcome else { return edit }
        undo = (w.word, r, w.punct, key)
        edit = Edit(deleteCount: w.word.count + w.punct.count, insert: r + w.punct + key)
        return edit
    }

    /// Before a single delete: right after a correction, put the typed word back (and keep it this session) instead
    /// of deleting. nil = delete as usual.
    public func delete(contextBefore: String) -> Edit? {
        guard let u = undo else { return nil }
        undo = nil
        let tail = u.replaced + u.punct + u.key
        guard contextBefore.hasSuffix(tail) else { return nil }
        allow.putBack(u.typed)
        return Edit(deleteCount: tail.count, insert: u.typed + u.punct)
    }

    /// Any other key, a held delete, dictated text, or the keyboard going away: no undo after this.
    public func reset() { undo = nil }

    /// True right after a correction, while one delete would put the typed word back.
    public var canUndo: Bool { undo != nil }

    /// Waits for queued lookups (tests).
    func drainLookups() { queue.sync {} }

    /// The FFAC line for one space press: the decision's own time and the whole key press (with the text edit).
    public func logSpace(totalMs: Double) {
        guard let s = lastSpace else { return }
        acLog.debug("FFAC space path=\(s.path.rawValue, privacy: .public) ms=\(s.ms, format: .fixed(precision: 3), privacy: .public) totalMs=\(totalMs, format: .fixed(precision: 3), privacy: .public) letters=\(s.letters, privacy: .public) changed=\(s.changed, privacy: .public)")
    }

    // MARK: text

    private static let punctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    /// The word right before the cursor (nil when the text before the cursor is empty or ends in whitespace).
    public static func wordAtCursor(_ context: String) -> WordAtCursor? {
        guard let last = context.last, !last.isWhitespace else { return nil }
        let start = context.lastIndex(where: { $0.isWhitespace }).map { context.index(after: $0) } ?? context.startIndex
        let token = context[start...]
        var coreEnd = token.endIndex
        while coreEnd > token.startIndex, punctuation.contains(token[token.index(before: coreEnd)]) {
            coreEnd = token.index(before: coreEnd)
        }
        return WordAtCursor(word: String(token[..<coreEnd]), punct: String(token[coreEnd...]),
                            sentenceInitial: startsSentence(context[..<start]))
    }

    /// The prototype's rule: the first word, or a word after one ending in exactly ".", "!" or "?".
    static func startsSentence(_ before: Substring) -> Bool {
        var end = before.endIndex
        while end > before.startIndex, before[before.index(before: end)].isWhitespace {
            end = before.index(before: end)
            if before[end].isNewline { return true }
        }
        if end == before.startIndex { return true }
        let prev = before[..<end]
        let start = prev.lastIndex(where: { $0.isWhitespace }).map { prev.index(after: $0) } ?? prev.startIndex
        let token = prev[start...]
        var p = token.endIndex
        while p > token.startIndex, punctuation.contains(token[token.index(before: p)]) { p = token.index(before: p) }
        let pun = token[p...]
        return pun == "." || pun == "!" || pun == "?"
    }
}
