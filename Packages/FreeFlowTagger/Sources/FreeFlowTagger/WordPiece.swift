import Foundation

/// BERT uncased WordPiece, as used by the ELECTRA checkpoint the tagger was fine-tuned from:
/// lower-case, strip accents, split on punctuation, then greedy longest-match subwords with "##".
struct WordPiece {
    let vocab: [String: Int32]
    let unk: Int32, cls: Int32, sep: Int32, pad: Int32

    init(vocabURL: URL) throws {
        let lines = try String(contentsOf: vocabURL, encoding: .utf8).components(separatedBy: "\n")
        var v: [String: Int32] = [:]
        for (i, l) in lines.enumerated() where !l.isEmpty && v[l] == nil { v[l] = Int32(i) }
        vocab = v; unk = v["[UNK]"] ?? 100; cls = v["[CLS]"] ?? 101; sep = v["[SEP]"] ?? 102; pad = v["[PAD]"] ?? 0
    }

    static func isPunct(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        return CharacterSet.punctuationCharacters.contains(s)
    }

    /// Basic tokenizer for one already-split word: lower-case, NFD without combining marks, punctuation split.
    static func basic(_ word: String) -> [String] {
        let folded = word.lowercased().decomposedStringWithCanonicalMapping
        var out: [String] = [], cur = ""
        for s in folded.unicodeScalars {
            if s.properties.generalCategory == .nonspacingMark { continue }
            if s.value == 0 || s.value == 0xFFFD || (s.properties.generalCategory == .control && !CharacterSet.whitespacesAndNewlines.contains(s)) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(s) { if !cur.isEmpty { out.append(cur); cur = "" }; continue }
            if isPunct(s) { if !cur.isEmpty { out.append(cur); cur = "" }; out.append(String(s)); continue }
            cur.unicodeScalars.append(s)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    func pieces(_ token: String) -> [Int32] {
        let chars = Array(token)
        if chars.count > 100 { return [unk] }
        var out: [Int32] = [], start = 0
        while start < chars.count {
            var end = chars.count, found: Int32? = nil
            while start < end {
                let sub = (start > 0 ? "##" : "") + String(chars[start..<end])
                if let id = vocab[sub] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            out.append(id); start = end
        }
        return out
    }

    /// Ids for [CLS] words [SEP] and, for each word, the index of its first subword (nil if the word had none).
    func encode(_ words: [String], maxLength: Int) -> (ids: [Int32], firstPiece: [Int?]) {
        var ids: [Int32] = [cls], first: [Int?] = []
        for w in words {
            let p = Self.basic(w).flatMap(pieces)
            if p.isEmpty || ids.count + p.count >= maxLength { first.append(nil); continue }
            first.append(ids.count); ids += p
        }
        ids.append(sep)
        return (ids, first)
    }
}
